import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler } from '../../utils/http.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';

const router = Router();
router.use(authenticate('panel'), requireRole('ADMIN', 'MASTER'));

/** O token do agente nunca volta inteiro numa listagem. */
const publicServer = ({ agentToken, ...server }) => ({
  ...server,
  hasAgent: Boolean(agentToken),
});

const serverSchema = z.object({
  name: z.string().min(2).max(80),
  host: z.string().min(3).max(255),
  sshPort: z.number().int().min(1).max(65535).optional(),
  sslPort: z.number().int().min(1).max(65535).optional(),
  proxyPort: z.number().int().min(1).max(65535).optional(),
  country: z.string().length(2).optional(),
  maxUsers: z.number().int().min(0).optional(),
  isActive: z.boolean().optional(),
});

router.get(
  '/',
  asyncHandler(async (_req, res) => {
    const items = await prisma.server.findMany({
      orderBy: { name: 'asc' },
      include: {
        _count: { select: { payloads: true } },
      },
    });

    // Quantas tarefas de provisionamento estao esperando cada agente.
    const pending = await prisma.provisionTask.groupBy({
      by: ['serverId'],
      where: { status: 'PENDING' },
      _count: { _all: true },
    });
    const pendingBy = Object.fromEntries(pending.map((p) => [p.serverId, p._count._all]));

    const failed = await prisma.provisionTask.groupBy({
      by: ['serverId'],
      where: { status: 'FAILED' },
      _count: { _all: true },
    });
    const failedBy = Object.fromEntries(failed.map((p) => [p.serverId, p._count._all]));

    res.json({
      items: items.map((server) => ({
        ...publicServer(server),
        pendingTasks: pendingBy[server.id] ?? 0,
        failedTasks: failedBy[server.id] ?? 0,
      })),
    });
  }),
);

router.post(
  '/',
  asyncHandler(async (req, res) => {
    const created = await prisma.server.create({ data: serverSchema.parse(req.body) });
    res.status(201).json(publicServer(created));
  }),
);

router.patch(
  '/:id',
  asyncHandler(async (req, res) => {
    const data = serverSchema.partial().parse(req.body);
    const updated = await prisma.server.update({ where: { id: req.params.id }, data });
    res.json(publicServer(updated));
  }),
);

/**
 * POST /api/servers/:id/agent-token
 * Gera (ou regenera) o token do agente. O valor completo aparece uma unica
 * vez nesta resposta — depois disso so existe no .env da VPS.
 */
router.post(
  '/:id/agent-token',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const agentToken = crypto.randomBytes(32).toString('hex');

    const server = await prisma.server.update({
      where: { id: req.params.id },
      data: { agentToken, agentLastSeen: null, agentVersion: null },
    });

    res.json({ serverId: server.id, serverName: server.name, agentToken });
  }),
);

/** DELETE /api/servers/:id/agent-token — revoga o acesso do agente. */
router.delete(
  '/:id/agent-token',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    await prisma.server.update({
      where: { id: req.params.id },
      data: { agentToken: null, agentLastSeen: null, agentVersion: null, agentUserCount: null },
    });
    res.json({ ok: true });
  }),
);

/** POST /api/servers/:id/retry-failed — recoloca as tarefas travadas na fila. */
router.post(
  '/:id/retry-failed',
  asyncHandler(async (req, res) => {
    const { count } = await prisma.provisionTask.updateMany({
      where: { serverId: req.params.id, status: 'FAILED' },
      data: { status: 'PENDING', attempts: 0, lastError: null, processedAt: null },
    });
    res.json({ ok: true, requeued: count });
  }),
);

router.delete(
  '/:id',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    await prisma.server.delete({ where: { id: req.params.id } });
    res.json({ ok: true });
  }),
);

export default router;
