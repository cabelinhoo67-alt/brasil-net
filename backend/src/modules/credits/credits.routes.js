import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler, pageResult, paginate } from '../../utils/http.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { assertOwnership, descendantIds } from '../../utils/hierarchy.js';
import { badRequest, conflict, notFound } from '../../utils/errors.js';

const router = Router();
router.use(authenticate('panel'), requireRole('ADMIN', 'MASTER', 'RESELLER'));

const transferSchema = z.object({
  toUserId: z.string().uuid(),
  amount: z.number().int().min(1).max(100000),
  description: z.string().max(200).optional(),
});

/**
 * POST /api/credits/transfer
 * Move creditos do usuario logado para um downline direto ou indireto.
 * ADMIN nao gasta saldo: ele emite credito novo no sistema (kind = ADD).
 */
router.post(
  '/transfer',
  asyncHandler(async (req, res) => {
    const { toUserId, amount, description } = transferSchema.parse(req.body);

    if (toUserId === req.user.id) throw badRequest('Nao e possivel transferir para si mesmo');
    await assertOwnership(req.user, toUserId);

    const target = await prisma.user.findUnique({ where: { id: toUserId } });
    if (!target) throw notFound('Destinatario nao encontrado');
    if (target.role === 'CLIENT') throw badRequest('Clientes finais nao possuem saldo de creditos');

    const result = await prisma.$transaction(async (tx) => {
      if (req.user.role !== 'ADMIN') {
        const me = await tx.user.findUnique({ where: { id: req.user.id }, select: { credits: true } });
        if (me.credits < amount) {
          throw conflict(`Saldo insuficiente. Disponivel: ${me.credits}`, 'INSUFFICIENT_CREDITS');
        }
        await tx.user.update({ where: { id: req.user.id }, data: { credits: { decrement: amount } } });
      }

      const updated = await tx.user.update({
        where: { id: toUserId },
        data: { credits: { increment: amount } },
        select: { id: true, username: true, credits: true },
      });

      await tx.creditTransaction.create({
        data: {
          kind: req.user.role === 'ADMIN' ? 'ADD' : 'TRANSFER',
          amount,
          fromUserId: req.user.id,
          toUserId,
          description: description ?? 'Transferencia de creditos',
        },
      });

      return updated;
    });

    res.json({ ok: true, target: result });
  }),
);

const removeSchema = z.object({
  fromUserId: z.string().uuid(),
  amount: z.number().int().min(1).max(100000),
  description: z.string().max(200).optional(),
});

/** POST /api/credits/withdraw — puxa credito de volta de um downline. */
router.post(
  '/withdraw',
  asyncHandler(async (req, res) => {
    const { fromUserId, amount, description } = removeSchema.parse(req.body);
    await assertOwnership(req.user, fromUserId);

    const result = await prisma.$transaction(async (tx) => {
      const target = await tx.user.findUnique({ where: { id: fromUserId }, select: { credits: true, username: true } });
      if (!target) throw notFound('Usuario nao encontrado');
      if (target.credits < amount) {
        throw conflict(`O usuario possui apenas ${target.credits} creditos`, 'INSUFFICIENT_CREDITS');
      }

      await tx.user.update({ where: { id: fromUserId }, data: { credits: { decrement: amount } } });
      if (req.user.role !== 'ADMIN') {
        await tx.user.update({ where: { id: req.user.id }, data: { credits: { increment: amount } } });
      }

      await tx.creditTransaction.create({
        data: {
          kind: 'REFUND',
          amount,
          fromUserId,
          toUserId: req.user.id,
          description: description ?? 'Recolhimento de creditos',
        },
      });

      return { username: target.username, credits: target.credits - amount };
    });

    res.json({ ok: true, target: result });
  }),
);

/** GET /api/credits/history — extrato do usuario logado (e da rede dele). */
router.get(
  '/history',
  asyncHandler(async (req, res) => {
    const pg = paginate(req.query);
    const ids = req.user.role === 'ADMIN' ? null : await descendantIds(req.user.id);

    const where = ids
      ? { OR: [{ fromUserId: { in: ids } }, { toUserId: { in: ids } }] }
      : {};

    const [items, total] = await Promise.all([
      prisma.creditTransaction.findMany({
        where,
        include: {
          fromUser: { select: { id: true, username: true, role: true } },
          toUser: { select: { id: true, username: true, role: true } },
        },
        orderBy: { createdAt: 'desc' },
        skip: pg.skip,
        take: pg.take,
      }),
      prisma.creditTransaction.count({ where }),
    ]);

    res.json(pageResult(items, total, pg));
  }),
);

/** GET /api/credits/balance */
router.get(
  '/balance',
  asyncHandler(async (req, res) => {
    const fresh = await prisma.user.findUnique({ where: { id: req.user.id }, select: { credits: true } });
    res.json({
      credits: req.user.role === 'ADMIN' ? null : fresh.credits,
      unlimited: req.user.role === 'ADMIN',
    });
  }),
);

export default router;
