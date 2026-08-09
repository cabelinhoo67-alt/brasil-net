import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler } from '../../utils/http.js';
import { forbidden, notFound } from '../../utils/errors.js';
import { desiredState } from './provision.queue.js';

const router = Router();

const MAX_ATTEMPTS = 5;

/**
 * Autenticacao do agente: token por servidor, enviado em `x-agent-token`.
 * Cada VPS so enxerga a propria fila.
 */
const authenticateAgent = asyncHandler(async (req, _res, next) => {
  const token = req.headers['x-agent-token'];
  if (!token || typeof token !== 'string') {
    throw forbidden('Token do agente ausente', 'NO_AGENT_TOKEN');
  }

  const server = await prisma.server.findUnique({ where: { agentToken: token } });
  if (!server) throw forbidden('Token do agente invalido', 'BAD_AGENT_TOKEN');

  req.server = server;
  next();
});

router.use(authenticateAgent);

/**
 * POST /api/agent/heartbeat
 * O agente se anuncia. E o que faz o painel mostrar "online" no servidor.
 */
router.post(
  '/heartbeat',
  asyncHandler(async (req, res) => {
    const body = z
      .object({
        version: z.string().max(20).optional(),
        userCount: z.number().int().min(0).optional(),
      })
      .parse(req.body ?? {});

    await prisma.server.update({
      where: { id: req.server.id },
      data: {
        agentLastSeen: new Date(),
        agentVersion: body.version ?? req.server.agentVersion,
        agentUserCount: body.userCount ?? req.server.agentUserCount,
      },
    });

    const pending = await prisma.provisionTask.count({
      where: { serverId: req.server.id, status: 'PENDING' },
    });

    res.json({
      ok: true,
      serverName: req.server.name,
      pendingTasks: pending,
      serverTime: new Date().toISOString(),
    });
  }),
);

/**
 * GET /api/agent/tasks
 * Devolve o lote pendente, mais antigo primeiro. As tarefas so saem da fila
 * quando o agente confirma — se ele morrer no meio, o lote volta inteiro.
 */
router.get(
  '/tasks',
  asyncHandler(async (req, res) => {
    const limit = Math.min(100, Math.max(1, Number(req.query.limit) || 25));

    const tasks = await prisma.provisionTask.findMany({
      where: {
        serverId: req.server.id,
        status: 'PENDING',
        attempts: { lt: MAX_ATTEMPTS },
      },
      orderBy: { createdAt: 'asc' },
      take: limit,
      select: {
        id: true,
        username: true,
        action: true,
        passwordHash: true,
        expiresAt: true,
        connectionLimit: true,
        attempts: true,
        createdAt: true,
      },
    });

    res.json({ items: tasks });
  }),
);

const resultSchema = z.object({
  ok: z.boolean(),
  error: z.string().max(500).optional(),
});

/** POST /api/agent/tasks/:id/result — confirmacao de execucao. */
router.post(
  '/tasks/:id/result',
  asyncHandler(async (req, res) => {
    const body = resultSchema.parse(req.body);

    const task = await prisma.provisionTask.findUnique({ where: { id: req.params.id } });
    if (!task || task.serverId !== req.server.id) {
      throw notFound('Tarefa nao encontrada para este servidor');
    }

    if (body.ok) {
      await prisma.provisionTask.update({
        where: { id: task.id },
        data: { status: 'DONE', processedAt: new Date(), lastError: null },
      });
      return res.json({ ok: true });
    }

    const attempts = task.attempts + 1;
    const giveUp = attempts >= MAX_ATTEMPTS;

    await prisma.provisionTask.update({
      where: { id: task.id },
      data: {
        // Continua PENDING enquanto houver tentativa sobrando; a sync
        // periodica cobre o caso de desistencia.
        status: giveUp ? 'FAILED' : 'PENDING',
        attempts,
        lastError: body.error ?? 'erro desconhecido',
        processedAt: giveUp ? new Date() : null,
      },
    });

    res.json({ ok: true, retry: !giveUp, attempts });
  }),
);

/**
 * GET /api/agent/sync
 * Estado desejado completo. O agente compara com o que existe na VPS e
 * converge — e o que conserta divergencia depois de queda longa.
 */
router.get(
  '/sync',
  asyncHandler(async (req, res) => {
    const users = await desiredState();

    await prisma.server.update({
      where: { id: req.server.id },
      data: { agentLastSeen: new Date() },
    });

    res.json({ users, generatedAt: new Date().toISOString() });
  }),
);

export default router;
