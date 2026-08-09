import { Router } from 'express';
import { z } from 'zod';
import rateLimit from 'express-rate-limit';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler } from '../../utils/http.js';
import { comparePassword, signAppToken } from '../../utils/security.js';
import { authenticate } from '../../middlewares/auth.js';
import { forbidden, notFound, unauthorized } from '../../utils/errors.js';
import { resolveOperator } from './operator.resolver.js';
import * as sessions from './sessions.service.js';
import { daysLeft } from '../users/users.service.js';
import { evaluate, readVersionInfo } from './version.service.js';

const router = Router();

const appLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60 });

/** Dados do SIM enviados pelo Flutter (lidos via TelephonyManager). */
const simSchema = z.object({
  operatorName: z.string().max(80).optional(),
  mccMnc: z.string().max(10).optional(),
  simSerialSuffix: z.string().max(8).optional(),
});

const loginSchema = z.object({
  username: z.string().min(3).trim(),
  password: z.string().min(1),
  deviceId: z.string().min(4).max(120),
  deviceName: z.string().max(80).optional(),
  appVersion: z.string().max(20).optional(),
  sim: simSchema.optional(),
});

function serializePayload(p) {
  return {
    id: p.id,
    name: p.name,
    mode: p.mode,
    content: p.content,
    sni: p.sni,
    proxyHost: p.proxyHost,
    proxyPort: p.proxyPort,
    dnsHost: p.dnsHost,
    publicKey: p.publicKey,
    extra: safeJson(p.extraJson),
    server: p.server
      ? {
          id: p.server.id,
          name: p.server.name,
          host: p.server.host,
          sshPort: p.server.sshPort,
          sslPort: p.server.sslPort,
          proxyPort: p.server.proxyPort,
        }
      : null,
  };
}

function safeJson(raw) {
  try {
    return JSON.parse(raw || '{}');
  } catch {
    return {};
  }
}

/** Carrega os payloads da operadora detectada. Sem operadora -> lista vazia. */
async function payloadsForOperator(operator) {
  if (!operator) return [];
  const items = await prisma.payload.findMany({
    where: { operatorId: operator.id, isActive: true },
    include: { server: true },
    orderBy: { sortOrder: 'asc' },
  });
  return items.filter((p) => p.server === null || p.server.isActive).map(serializePayload);
}

/**
 * POST /api/app/login
 * Valida credenciais, validade, limite de conexoes e ja devolve a configuracao
 * filtrada pela operadora do chip — o app nunca ve payload de outra operadora.
 */
router.post(
  '/login',
  appLimiter,
  asyncHandler(async (req, res) => {
    const body = loginSchema.parse(req.body);

    const user = await prisma.user.findUnique({
      where: { username: body.username.toLowerCase() },
      include: { plan: true },
    });
    if (!user) throw unauthorized('Usuario ou senha invalidos', 'BAD_CREDENTIALS');

    const ok = await comparePassword(body.password, user.passwordHash);
    if (!ok) throw unauthorized('Usuario ou senha invalidos', 'BAD_CREDENTIALS');

    if (user.role !== 'CLIENT') throw forbidden('Esta conta e de painel, nao de aplicativo', 'NOT_A_CLIENT');
    if (!user.isActive || user.isBlocked) throw forbidden('Conta bloqueada. Fale com seu revendedor.', 'USER_DISABLED');
    if (user.expiresAt && new Date(user.expiresAt) < new Date()) {
      throw forbidden('Seu acesso expirou. Renove com seu revendedor.', 'EXPIRED');
    }

    const operator = await resolveOperator(body.sim ?? {});

    await sessions.openSession(user, {
      deviceId: body.deviceId,
      deviceName: body.deviceName,
      appVersion: body.appVersion,
      operator: operator?.code ?? body.sim?.operatorName ?? null,
      ip: req.ip,
    });

    await prisma.user.update({ where: { id: user.id }, data: { lastLogin: new Date() } });

    res.json({
      token: signAppToken(user, body.deviceId),
      user: {
        id: user.id,
        username: user.username,
        fullName: user.fullName,
        expiresAt: user.expiresAt,
        daysLeft: daysLeft(user.expiresAt),
        connectionLimit: user.connectionLimit,
        plan: user.plan ? { id: user.plan.id, name: user.plan.name } : null,
      },
      operator: operator
        ? { code: operator.code, name: operator.name, logoUrl: operator.logoUrl, detected: true }
        : { code: null, name: body.sim?.operatorName ?? 'Desconhecida', logoUrl: null, detected: false },
      payloads: await payloadsForOperator(operator),
    });
  }),
);

/**
 * GET /api/app/config?operatorName=Claro&mccMnc=72405
 * Refresh da configuracao sem refazer login (usado ao trocar de chip).
 */
router.get(
  '/config',
  authenticate('app'),
  asyncHandler(async (req, res) => {
    const sim = simSchema.parse({
      operatorName: req.query.operatorName,
      mccMnc: req.query.mccMnc,
    });
    const operator = await resolveOperator(sim);

    const fresh = await prisma.user.findUnique({
      where: { id: req.user.id },
      include: { plan: true },
    });
    if (!fresh) throw notFound('Usuario nao encontrado');

    const expired = fresh.expiresAt ? new Date(fresh.expiresAt) < new Date() : false;

    res.json({
      user: {
        username: fresh.username,
        expiresAt: fresh.expiresAt,
        daysLeft: daysLeft(fresh.expiresAt),
        connectionLimit: fresh.connectionLimit,
        expired,
        blocked: fresh.isBlocked || !fresh.isActive,
      },
      operator: operator
        ? { code: operator.code, name: operator.name, logoUrl: operator.logoUrl, detected: true }
        : { code: null, name: sim.operatorName ?? 'Desconhecida', logoUrl: null, detected: false },
      payloads: expired ? [] : await payloadsForOperator(operator),
    });
  }),
);

/**
 * POST /api/app/session/heartbeat
 * Mantem a sessao viva; o backend responde se a conta ainda e valida,
 * permitindo derrubar o tunel remotamente (bloqueio, expiracao, kick).
 */
router.post(
  '/session/heartbeat',
  authenticate('app'),
  asyncHandler(async (req, res) => {
    const deviceId = req.tokenPayload.deviceId;
    const fresh = await prisma.user.findUnique({ where: { id: req.user.id } });

    const expired = fresh.expiresAt ? new Date(fresh.expiresAt) < new Date() : false;
    if (expired || fresh.isBlocked || !fresh.isActive) {
      await sessions.closeSession(req.user.id, deviceId);
      return res.status(403).json({
        error: true,
        code: expired ? 'EXPIRED' : 'USER_DISABLED',
        message: expired ? 'Seu acesso expirou' : 'Conta bloqueada',
        disconnect: true,
      });
    }

    const session = await sessions.heartbeat(req.user.id, deviceId);
    if (!session) {
      return res.status(409).json({
        error: true,
        code: 'SESSION_CLOSED',
        message: 'Sua sessao foi encerrada em outro dispositivo',
        disconnect: true,
      });
    }

    const activeSessions = await prisma.session.count({
      where: { userId: req.user.id, closedAt: null },
    });

    res.json({
      ok: true,
      daysLeft: daysLeft(fresh.expiresAt),
      activeSessions,
      connectionLimit: fresh.connectionLimit,
      serverTime: new Date().toISOString(),
    });
  }),
);

/** POST /api/app/session/close — desconexao limpa, libera o slot na hora. */
router.post(
  '/session/close',
  authenticate('app'),
  asyncHandler(async (req, res) => {
    const closed = await sessions.closeSession(req.user.id, req.tokenPayload.deviceId);
    res.json({ ok: true, closed });
  }),
);

/**
 * GET /api/app/version?build=NN
 * Checagem de atualizacao (OTA). Sem autenticacao: o app consulta no ciclo de
 * vida (abertura, retomada, apos o login) sem depender de estar logado.
 *
 * A comparacao e sempre por build (inteiro monotonico), nunca por string de
 * versao — ordenar "1.10.0" vs "1.9.0" como texto daria o resultado errado.
 */
router.get(
  '/version',
  appLimiter,
  asyncHandler(async (req, res) => {
    const info = await readVersionInfo();
    res.json(evaluate(info, req.query.build));
  }),
);

/**
 * GET /api/app/ping
 * Endpoint minimo e sem autenticacao para o app medir latencia (RTT).
 */
router.get('/ping', (_req, res) => {
  res.json({ pong: true, t: Date.now() });
});

export default router;
