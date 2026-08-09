import { prisma } from '../../lib/prisma.js';
import { hashPassword } from '../../utils/security.js';
import { badRequest, conflict, forbidden, notFound } from '../../utils/errors.js';
import { assertCanCreate } from '../../utils/hierarchy.js';
import { enqueue, enqueueLatest } from '../agent/provision.queue.js';

const CLIENT_SELECT = {
  id: true,
  username: true,
  fullName: true,
  whatsapp: true,
  note: true,
  role: true,
  credits: true,
  expiresAt: true,
  connectionLimit: true,
  isActive: true,
  isBlocked: true,
  lastLogin: true,
  createdAt: true,
  parentId: true,
  plan: { select: { id: true, name: true, days: true } },
  parent: { select: { id: true, username: true, role: true } },
};

export const userSelect = CLIENT_SELECT;

export function daysLeft(expiresAt) {
  if (!expiresAt) return null;
  const ms = new Date(expiresAt).getTime() - Date.now();
  return Math.ceil(ms / 86_400_000);
}

export function decorate(user) {
  if (!user) return user;
  return {
    ...user,
    daysLeft: daysLeft(user.expiresAt),
    expired: user.expiresAt ? new Date(user.expiresAt) < new Date() : false,
  };
}

/** Debita creditos do ator dentro de uma transacao. ADMIN nunca e debitado. */
async function debitCredits(tx, actor, amount, description, targetId) {
  if (actor.role === 'ADMIN' || amount <= 0) return;

  const fresh = await tx.user.findUnique({ where: { id: actor.id }, select: { credits: true } });
  if (fresh.credits < amount) {
    throw conflict(
      `Creditos insuficientes. Necessario: ${amount}, disponivel: ${fresh.credits}`,
      'INSUFFICIENT_CREDITS',
    );
  }

  await tx.user.update({ where: { id: actor.id }, data: { credits: { decrement: amount } } });
  await tx.creditTransaction.create({
    data: { kind: 'CONSUME', amount, fromUserId: actor.id, toUserId: targetId, description },
  });
}

/**
 * Cria um usuario respeitando a cascata.
 * - CLIENT: exige plano (ou dias avulsos), debita creditos e define validade.
 * - MASTER/RESELLER: opcionalmente ja nasce com um saldo transferido do criador.
 */
export async function createUser(actor, input) {
  assertCanCreate(actor.role, input.role);

  const username = input.username.toLowerCase().trim();
  const exists = await prisma.user.findUnique({ where: { username } });
  if (exists) throw conflict('Este nome de usuario ja esta em uso', 'USERNAME_TAKEN');

  const passwordHash = await hashPassword(input.password);

  return prisma.$transaction(async (tx) => {
    const data = {
      username,
      passwordHash,
      role: input.role,
      fullName: input.fullName ?? null,
      whatsapp: input.whatsapp ?? null,
      note: input.note ?? null,
      parentId: actor.id,
    };

    if (input.role === 'CLIENT') {
      let days = input.days ?? null;
      let connectionLimit = input.connectionLimit ?? 1;
      let creditCost = input.days ? input.days : 0;

      if (input.planId) {
        const plan = await tx.plan.findUnique({ where: { id: input.planId } });
        if (!plan || !plan.isActive) throw notFound('Plano inexistente ou inativo', 'PLAN_NOT_FOUND');
        days = plan.days;
        connectionLimit = plan.connectionLimit;
        creditCost = plan.creditCost;
        data.planId = plan.id;
      }

      if (!days || days <= 0) throw badRequest('Informe um plano ou a quantidade de dias', 'MISSING_PLAN');

      data.expiresAt = new Date(Date.now() + days * 86_400_000);
      data.connectionLimit = connectionLimit;

      await debitCredits(tx, actor, creditCost, `Criacao do cliente ${username}`, null);
    } else {
      // Revendedor nasce com o saldo inicial transferido do criador.
      const initial = input.initialCredits ?? 0;
      if (initial > 0) {
        await debitCredits(tx, actor, initial, `Saldo inicial de ${username}`, null);
        data.credits = initial;
      }
      data.connectionLimit = 1;
    }

    const created = await tx.user.create({ data, select: CLIENT_SELECT });

    // Cliente final vira usuario do Linux na VPS.
    if (input.role === 'CLIENT') {
      await enqueue({
        action: 'CREATE',
        user: { ...created, passwordHash },
        tx,
      });
    }

    if (input.role !== 'CLIENT' && (input.initialCredits ?? 0) > 0) {
      await tx.creditTransaction.create({
        data: {
          kind: 'TRANSFER',
          amount: input.initialCredits,
          fromUserId: actor.id,
          toUserId: created.id,
          description: 'Saldo inicial na criacao',
        },
      });
    }

    return decorate(created);
  });
}

/** Renova (soma dias) um cliente final, debitando creditos do ator. */
export async function renewClient(actor, userId, { planId, days }) {
  const target = await prisma.user.findUnique({ where: { id: userId } });
  if (!target) throw notFound('Cliente nao encontrado');
  if (target.role !== 'CLIENT') throw badRequest('Somente clientes finais podem ser renovados', 'NOT_A_CLIENT');

  return prisma.$transaction(async (tx) => {
    let addDays = days ?? 0;
    let cost = days ?? 0;
    let connectionLimit = target.connectionLimit;
    let newPlanId = target.planId;

    if (planId) {
      const plan = await tx.plan.findUnique({ where: { id: planId } });
      if (!plan || !plan.isActive) throw notFound('Plano inexistente ou inativo', 'PLAN_NOT_FOUND');
      addDays = plan.days;
      cost = plan.creditCost;
      connectionLimit = plan.connectionLimit;
      newPlanId = plan.id;
    }

    if (addDays <= 0) throw badRequest('Informe um plano ou a quantidade de dias', 'MISSING_PLAN');

    await debitCredits(tx, actor, cost, `Renovacao de ${target.username}`, target.id);

    // Se ja expirou, conta a partir de agora; se nao, soma ao saldo restante.
    const base = target.expiresAt && new Date(target.expiresAt) > new Date()
      ? new Date(target.expiresAt)
      : new Date();

    const updated = await tx.user.update({
      where: { id: userId },
      data: {
        expiresAt: new Date(base.getTime() + addDays * 86_400_000),
        connectionLimit,
        planId: newPlanId,
        isBlocked: false,
      },
      select: CLIENT_SELECT,
    });

    // Nova validade e novo limite precisam chegar ao `chage` e ao maxlogins.
    await enqueueLatest({
      action: 'UPDATE',
      user: { ...updated, passwordHash: target.passwordHash },
      tx,
    });

    return decorate(updated);
  });
}

export async function updateUser(actor, userId, input) {
  const target = await prisma.user.findUnique({ where: { id: userId } });
  if (!target) throw notFound('Usuario nao encontrado');
  if (target.role === 'ADMIN' && actor.role !== 'ADMIN') {
    throw forbidden('Nao e possivel alterar um administrador');
  }

  const data = {};
  for (const field of ['fullName', 'whatsapp', 'note', 'isActive', 'isBlocked']) {
    if (input[field] !== undefined) data[field] = input[field];
  }
  if (input.connectionLimit !== undefined) {
    if (target.role !== 'CLIENT') throw badRequest('Limite de conexoes so se aplica a clientes');
    data.connectionLimit = input.connectionLimit;
  }
  if (input.password) {
    data.passwordHash = await hashPassword(input.password);
  }

  const updated = await prisma.user.update({ where: { id: userId }, data, select: CLIENT_SELECT });

  // Trocar a senha ou bloquear derruba as sessoes ativas do app.
  if (input.password || input.isBlocked === true || input.isActive === false) {
    await prisma.session.updateMany({
      where: { userId, closedAt: null },
      data: { closedAt: new Date() },
    });
  }

  if (target.role === 'CLIENT') {
    const nowLocked = updated.isBlocked || !updated.isActive;
    const wasLocked = target.isBlocked || !target.isActive;

    if (data.passwordHash) {
      // Senha nova precisa ir ao /etc/shadow; UPDATE ja reaplica tudo.
      await enqueueLatest({
        action: 'UPDATE',
        user: { ...updated, passwordHash: data.passwordHash },
      });
    }

    if (nowLocked !== wasLocked) {
      await enqueue({ action: nowLocked ? 'LOCK' : 'UNLOCK', user: updated });
    } else if (input.connectionLimit !== undefined && !data.passwordHash) {
      await enqueueLatest({
        action: 'UPDATE',
        user: { ...updated, passwordHash: target.passwordHash },
      });
    }
  }

  return decorate(updated);
}

export async function deleteUser(actor, userId) {
  if (actor.id === userId) throw badRequest('Voce nao pode remover a propria conta');

  const target = await prisma.user.findUnique({
    where: { id: userId },
    select: {
      id: true,
      username: true,
      role: true,
      credits: true,
      _count: { select: { children: true } },
    },
  });
  if (!target) throw notFound('Usuario nao encontrado');
  if (target.role === 'ADMIN') throw forbidden('Administradores nao podem ser removidos pela API');
  if (target._count.children > 0) {
    throw conflict('Este usuario possui uma rede abaixo dele. Transfira ou remova a rede primeiro.', 'HAS_CHILDREN');
  }

  await prisma.$transaction(async (tx) => {
    // Credito nao usado volta para o upline (nunca some do sistema).
    if (target.credits > 0 && actor.role !== 'ADMIN') {
      await tx.user.update({ where: { id: actor.id }, data: { credits: { increment: target.credits } } });
      await tx.creditTransaction.create({
        data: {
          kind: 'REFUND',
          amount: target.credits,
          fromUserId: target.id,
          toUserId: actor.id,
          description: 'Devolucao de saldo na exclusao do usuario',
        },
      });
    }
    // Enfileirado antes do delete: o FK e SetNull, entao a tarefa sobrevive
    // ao usuario e o agente ainda sabe qual conta remover pelo username.
    if (target.role === 'CLIENT') {
      await enqueue({ action: 'DELETE', user: { ...target, role: 'CLIENT' }, tx });
    }

    await tx.user.delete({ where: { id: userId } });
  });

  return { ok: true };
}
