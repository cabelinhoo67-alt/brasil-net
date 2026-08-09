import { prisma } from '../../lib/prisma.js';
import { env } from '../../config/env.js';
import { hashPassword, randomPassword, randomUsername } from '../../utils/security.js';
import { enqueue } from '../agent/provision.queue.js';

/** Gera um username livre (colisao e improvavel, mas tratamos mesmo assim). */
async function uniqueUsername() {
  for (let i = 0; i < 10; i += 1) {
    const candidate = randomUsername('cli');
    const exists = await prisma.user.findUnique({ where: { username: candidate } });
    if (!exists) return candidate;
  }
  return `cli${Date.now().toString(36)}`;
}

/** Dono padrao das vendas automaticas: o revendedor configurado ou o ADMIN. */
async function resolveOwner(preferredOwnerId) {
  if (preferredOwnerId) {
    const owner = await prisma.user.findUnique({ where: { id: preferredOwnerId } });
    if (owner) return owner;
  }
  const setting = await prisma.setting.findUnique({ where: { key: 'AUTO_SALE_OWNER_ID' } });
  if (setting) {
    const owner = await prisma.user.findUnique({ where: { id: setting.value } });
    if (owner) return owner;
  }
  return prisma.user.findFirst({ where: { role: 'ADMIN' }, orderBy: { createdAt: 'asc' } });
}

/**
 * Cria o acesso do cliente final apos a confirmacao do Pix.
 * Idempotente: se a ordem ja gerou usuario, devolve o que existe.
 */
export async function provisionFromOrder(orderId) {
  const order = await prisma.order.findUnique({
    where: { id: orderId },
    include: { plan: true, createdUser: true },
  });
  if (!order) throw new Error(`Order ${orderId} inexistente`);

  if (order.createdUserId && order.createdUser) {
    return {
      order,
      credentials: {
        username: order.createdUser.username,
        password: order.plainPassword,
        expiresAt: order.createdUser.expiresAt,
        days: order.plan.days,
      },
      alreadyProvisioned: true,
    };
  }

  const owner = await resolveOwner(order.ownerId);
  const username = await uniqueUsername();
  const password = randomPassword(8);
  const expiresAt = new Date(Date.now() + order.plan.days * 86_400_000);

  const passwordHash = await hashPassword(password);

  const result = await prisma.$transaction(async (tx) => {
    const user = await tx.user.create({
      data: {
        username,
        passwordHash,
        role: 'CLIENT',
        parentId: owner?.id ?? null,
        planId: order.planId,
        whatsapp: order.whatsapp,
        fullName: `Venda automatica ${order.whatsapp}`,
        note: `Pedido ${order.id} — Pix ${order.providerRefId ?? '-'}`,
        expiresAt,
        connectionLimit: order.plan.connectionLimit,
      },
    });

    const updatedOrder = await tx.order.update({
      where: { id: order.id },
      data: {
        status: 'PAID',
        paidAt: order.paidAt ?? new Date(),
        createdUserId: user.id,
        plainPassword: password,
      },
      include: { plan: true },
    });

    // A venda so esta completa quando o login existe tambem na VPS.
    await enqueue({ action: 'CREATE', user, tx });

    return { user, updatedOrder };
  });

  return {
    order: result.updatedOrder,
    credentials: {
      username,
      password,
      expiresAt,
      days: order.plan.days,
    },
    alreadyProvisioned: false,
  };
}

/**
 * Avisa o bot do WhatsApp para entregar as credenciais no chat.
 * Falha aqui nao pode derrubar o webhook do Mercado Pago: o gateway
 * reenviaria a notificacao e o pedido ja esta pago e provisionado.
 */
export async function notifyBot(payload) {
  if (!env.BOT_CALLBACK_URL) return { delivered: false, reason: 'BOT_CALLBACK_URL vazio' };

  try {
    const response = await fetch(env.BOT_CALLBACK_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-internal-key': env.INTERNAL_API_KEY,
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10_000),
    });
    return { delivered: response.ok, status: response.status };
  } catch (err) {
    console.error('[notifyBot] falha ao avisar o bot:', err.message);
    return { delivered: false, reason: err.message };
  }
}
