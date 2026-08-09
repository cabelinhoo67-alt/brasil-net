import { prisma } from '../../lib/prisma.js';

/**
 * Fila de provisionamento (outbox).
 *
 * Toda mudanca em cliente final vira uma ou mais tarefas — uma por servidor
 * ativo que tenha agente cadastrado. O agente da VPS puxa, executa e confirma.
 *
 * Nada aqui pode derrubar a operacao do painel: se o enfileiramento falhar,
 * registramos e seguimos. A reconciliacao periodica do agente
 * (`GET /api/agent/sync`) conserta qualquer divergencia depois.
 */

/** Servidores que devem receber o usuario: ativos e com agente configurado. */
async function targetServers(tx = prisma) {
  return tx.server.findMany({
    where: { isActive: true, agentToken: { not: null } },
    select: { id: true },
  });
}

/**
 * @param {object} options
 * @param {'CREATE'|'UPDATE'|'LOCK'|'UNLOCK'|'DELETE'} options.action
 * @param {object} options.user   registro do usuario (precisa de username)
 * @param {object} [options.tx]   client dentro de uma transacao
 */
export async function enqueue({ action, user, tx = prisma }) {
  try {
    if (user.role && user.role !== 'CLIENT') return; // so cliente final vira login SSH

    const servers = await targetServers(tx);
    if (servers.length === 0) return;

    const base = {
      username: user.username,
      userId: user.id ?? null,
      action,
      passwordHash: action === 'CREATE' || action === 'UPDATE' ? user.passwordHash ?? null : null,
      expiresAt: user.expiresAt ?? null,
      connectionLimit: user.connectionLimit ?? null,
    };

    await tx.provisionTask.createMany({
      data: servers.map((server) => ({ ...base, serverId: server.id })),
    });
  } catch (error) {
    console.error(`[provision] falha ao enfileirar ${action} de ${user.username}:`, error.message);
  }
}

/**
 * Enfileira descartando as tarefas pendentes *da mesma acao*.
 *
 * Dez renovacoes seguidas viram dez UPDATE com o mesmo resultado final, entao
 * mantemos so o ultimo — cada UPDATE carrega o estado completo (hash, validade
 * e limite), nunca um delta.
 *
 * Importante: so coalescemos acao com acao igual. LOCK e UNLOCK representam
 * transicoes de estado e sumir com elas deixaria a VPS fora de sincronia — um
 * cliente desbloqueado e renovado no mesmo intervalo continuaria travado ate a
 * proxima reconciliacao.
 */
export async function enqueueLatest({ action, user, tx = prisma }) {
  try {
    if (user.role && user.role !== 'CLIENT') return;

    await tx.provisionTask.deleteMany({
      where: { username: user.username, status: 'PENDING', action },
    });
  } catch (error) {
    console.error('[provision] falha ao limpar fila anterior:', error.message);
  }

  await enqueue({ action, user, tx });
}

/** Fotografia do que deve existir na VPS — base da reconciliacao do agente. */
export async function desiredState() {
  const users = await prisma.user.findMany({
    where: { role: 'CLIENT' },
    select: {
      username: true,
      passwordHash: true,
      expiresAt: true,
      connectionLimit: true,
      isActive: true,
      isBlocked: true,
    },
    orderBy: { username: 'asc' },
  });

  return users.map((user) => ({
    username: user.username,
    passwordHash: user.passwordHash,
    expiresAt: user.expiresAt,
    connectionLimit: user.connectionLimit,
    locked: user.isBlocked || !user.isActive,
  }));
}
