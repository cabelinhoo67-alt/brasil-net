import { prisma } from '../../lib/prisma.js';
import { env } from '../../config/env.js';
import { conflict } from '../../utils/errors.js';

const timeoutMs = () => env.SESSION_TIMEOUT_SECONDS * 1000;

/** Fecha sessoes que pararam de mandar heartbeat (app fechado a forca, bateria, etc). */
export async function reapStaleSessions(userId) {
  const deadline = new Date(Date.now() - timeoutMs());
  await prisma.session.updateMany({
    where: { userId, closedAt: null, lastSeenAt: { lt: deadline } },
    data: { closedAt: new Date() },
  });
}

/**
 * Abre (ou reaproveita) uma sessao respeitando o limite de conexoes simultaneas.
 * O mesmo deviceId reconecta sem consumir um novo slot.
 */
export async function openSession(user, { deviceId, deviceName, appVersion, operator, ip }) {
  await reapStaleSessions(user.id);

  const existing = await prisma.session.findFirst({
    where: { userId: user.id, deviceId, closedAt: null },
  });

  if (existing) {
    return prisma.session.update({
      where: { id: existing.id },
      data: { lastSeenAt: new Date(), ip, appVersion, operator, deviceName },
    });
  }

  const active = await prisma.session.count({ where: { userId: user.id, closedAt: null } });
  if (active >= user.connectionLimit) {
    throw conflict(
      `Limite de ${user.connectionLimit} conexao(oes) simultanea(s) atingido. Feche o app no outro aparelho.`,
      'CONNECTION_LIMIT',
    );
  }

  return prisma.session.create({
    data: { userId: user.id, deviceId, deviceName, appVersion, operator, ip },
  });
}

export async function heartbeat(userId, deviceId) {
  await reapStaleSessions(userId);

  const session = await prisma.session.findFirst({
    where: { userId, deviceId, closedAt: null },
  });
  if (!session) return null;

  return prisma.session.update({
    where: { id: session.id },
    data: { lastSeenAt: new Date() },
  });
}

export async function closeSession(userId, deviceId) {
  const result = await prisma.session.updateMany({
    where: { userId, deviceId, closedAt: null },
    data: { closedAt: new Date() },
  });
  return result.count;
}
