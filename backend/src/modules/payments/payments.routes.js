import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler, pageResult, paginate } from '../../utils/http.js';
import { authenticate, requireInternalKey, requireRole } from '../../middlewares/auth.js';
import { badRequest, notFound } from '../../utils/errors.js';
import * as mp from './mercadopago.service.js';
import { notifyBot, provisionFromOrder } from './provisioning.service.js';

const router = Router();

// ------------------------- ROTAS INTERNAS (BOT) ---------------------------

const internal = Router();
internal.use(requireInternalKey);

/** GET /api/payments/internal/plans — catalogo exibido no menu do WhatsApp. */
internal.get(
  '/plans',
  asyncHandler(async (_req, res) => {
    const items = await prisma.plan.findMany({
      where: { isActive: true, isPublic: true, priceCents: { gt: 0 } },
      orderBy: [{ sortOrder: 'asc' }, { days: 'asc' }],
      select: { id: true, name: true, days: true, priceCents: true, connectionLimit: true, description: true },
    });
    res.json({ items });
  }),
);

const pixSchema = z.object({
  whatsapp: z.string().min(8).max(40),
  planId: z.string().uuid(),
  ownerId: z.string().uuid().optional(),
  payerEmail: z.string().email().optional(),
});

/** POST /api/payments/internal/pix — gera a cobranca e devolve o copia e cola. */
internal.post(
  '/pix',
  asyncHandler(async (req, res) => {
    const body = pixSchema.parse(req.body);

    const plan = await prisma.plan.findUnique({ where: { id: body.planId } });
    if (!plan || !plan.isActive) throw notFound('Plano indisponivel', 'PLAN_NOT_FOUND');
    if (plan.priceCents <= 0) throw badRequest('Este plano nao tem preco de venda configurado', 'PLAN_NOT_SELLABLE');

    const order = await prisma.order.create({
      data: {
        whatsapp: body.whatsapp,
        planId: plan.id,
        amountCents: plan.priceCents,
        ownerId: body.ownerId ?? null,
        status: 'PENDING',
      },
    });

    const charge = await mp.createPixCharge({
      amountCents: plan.priceCents,
      description: `${plan.name} - ${plan.days} dias`,
      payerEmail: body.payerEmail,
      externalReference: order.id,
    });

    const updated = await prisma.order.update({
      where: { id: order.id },
      data: {
        providerRefId: charge.providerRefId,
        pixCopyPaste: charge.copyPaste,
        pixQrBase64: charge.qrBase64,
        pixExpiresAt: charge.expiresAt,
      },
    });

    res.status(201).json({
      orderId: updated.id,
      plan: { id: plan.id, name: plan.name, days: plan.days },
      amountCents: plan.priceCents,
      pix: {
        copyPaste: updated.pixCopyPaste,
        qrBase64: updated.pixQrBase64,
        expiresAt: updated.pixExpiresAt,
      },
    });
  }),
);

/** GET /api/payments/internal/orders/:id — o bot usa para poll de fallback. */
internal.get(
  '/orders/:id',
  asyncHandler(async (req, res) => {
    const order = await prisma.order.findUnique({
      where: { id: req.params.id },
      include: { plan: true, createdUser: { select: { username: true, expiresAt: true } } },
    });
    if (!order) throw notFound('Pedido nao encontrado');

    // Fallback: se o webhook nao chegou, consultamos o gateway sob demanda.
    if (order.status === 'PENDING' && order.providerRefId) {
      const remote = await mp.getPayment(order.providerRefId).catch(() => null);
      if (remote?.status === 'approved') {
        const { credentials } = await provisionFromOrder(order.id);
        return res.json({ status: 'PAID', credentials, plan: { name: order.plan.name, days: order.plan.days } });
      }
    }

    res.json({
      status: order.status,
      credentials:
        order.status === 'PAID' && order.createdUser
          ? {
              username: order.createdUser.username,
              password: order.plainPassword,
              expiresAt: order.createdUser.expiresAt,
              days: order.plan.days,
            }
          : null,
      plan: { name: order.plan.name, days: order.plan.days },
    });
  }),
);

router.use('/internal', internal);

// ------------------------------- WEBHOOK ----------------------------------

/**
 * POST /api/payments/webhook/mercadopago
 * O Mercado Pago manda { type: 'payment', data: { id } } (ou via querystring).
 * Sempre respondemos 200 rapido: erro de entrega faz o gateway repetir por horas.
 */
router.post(
  '/webhook/mercadopago',
  asyncHandler(async (req, res) => {
    const type = req.body?.type ?? req.body?.topic ?? req.query.type ?? req.query.topic;
    const paymentId = req.body?.data?.id ?? req.query['data.id'] ?? req.query.id;

    if (type !== 'payment' || !paymentId) {
      return res.status(200).json({ ignored: true });
    }

    // Responde ja; o processamento segue em background.
    res.status(200).json({ received: true });

    try {
      const remote = await mp.getPayment(paymentId);
      if (remote.status !== 'approved') return;

      const order = await prisma.order.findFirst({
        where: {
          OR: [
            { providerRefId: String(remote.id) },
            ...(remote.externalReference ? [{ id: remote.externalReference }] : []),
          ],
        },
      });
      if (!order) {
        console.warn('[webhook] pagamento aprovado sem pedido correspondente:', remote.id);
        return;
      }
      if (order.status === 'PAID') return; // idempotencia

      const { credentials, order: paidOrder } = await provisionFromOrder(order.id);

      await notifyBot({
        orderId: paidOrder.id,
        whatsapp: paidOrder.whatsapp,
        plan: { name: paidOrder.plan.name, days: paidOrder.plan.days },
        credentials,
      });

      console.log(`[webhook] pedido ${order.id} pago -> usuario ${credentials.username} criado`);
    } catch (err) {
      console.error('[webhook] erro ao processar pagamento:', err);
    }
  }),
);

// --------------------------- PAINEL (LEITURA) -----------------------------

router.get(
  '/orders',
  authenticate('panel'),
  requireRole('ADMIN', 'MASTER'),
  asyncHandler(async (req, res) => {
    const pg = paginate(req.query);
    const where = req.query.status ? { status: String(req.query.status) } : {};

    const [items, total] = await Promise.all([
      prisma.order.findMany({
        where,
        include: {
          plan: { select: { name: true, days: true } },
          createdUser: { select: { id: true, username: true } },
        },
        orderBy: { createdAt: 'desc' },
        skip: pg.skip,
        take: pg.take,
      }),
      prisma.order.count({ where }),
    ]);

    // Nunca devolvemos a senha em claro em listagens do painel.
    res.json(pageResult(items.map(({ plainPassword, pixQrBase64, ...rest }) => rest), total, pg));
  }),
);

export default router;
