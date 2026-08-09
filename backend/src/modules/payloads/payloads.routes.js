import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler } from '../../utils/http.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';

const router = Router();

// Somente ADMIN e MASTER administram a configuracao entregue ao app.
router.use(authenticate('panel'), requireRole('ADMIN', 'MASTER'));

// ----------------------------- OPERADORAS ---------------------------------

const operatorSchema = z.object({
  code: z.string().min(2).max(20).transform((v) => v.toUpperCase()),
  name: z.string().min(2).max(60),
  mccMncList: z.string().max(300).optional(),
  logoUrl: z.string().url().nullable().optional(),
  isActive: z.boolean().optional(),
  sortOrder: z.number().int().optional(),
});

router.get(
  '/operators',
  asyncHandler(async (_req, res) => {
    const items = await prisma.operator.findMany({
      orderBy: [{ sortOrder: 'asc' }, { name: 'asc' }],
      include: { _count: { select: { payloads: true } } },
    });
    res.json({ items });
  }),
);

router.post(
  '/operators',
  asyncHandler(async (req, res) => {
    const data = operatorSchema.parse(req.body);
    res.status(201).json(await prisma.operator.create({ data }));
  }),
);

router.patch(
  '/operators/:id',
  asyncHandler(async (req, res) => {
    const data = operatorSchema.partial().parse(req.body);
    res.json(await prisma.operator.update({ where: { id: req.params.id }, data }));
  }),
);

router.delete(
  '/operators/:id',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    await prisma.operator.delete({ where: { id: req.params.id } });
    res.json({ ok: true });
  }),
);

// ------------------------------ PAYLOADS ----------------------------------

const payloadSchema = z.object({
  name: z.string().min(2).max(80),
  operatorId: z.string().uuid(),
  serverId: z.string().uuid().nullable().optional(),
  mode: z.enum(['SSH_DIRECT', 'SSH_PAYLOAD', 'SSH_SSL', 'V2RAY', 'SLOWDNS', 'UDP']).default('SSH_PAYLOAD'),
  content: z.string().max(4000).optional(),
  sni: z.string().max(255).nullable().optional(),
  proxyHost: z.string().max(255).nullable().optional(),
  proxyPort: z.number().int().min(1).max(65535).nullable().optional(),
  dnsHost: z.string().max(255).nullable().optional(),
  publicKey: z.string().max(500).nullable().optional(),
  extraJson: z.string().max(4000).optional(),
  minAppVersion: z.string().max(20).nullable().optional(),
  isActive: z.boolean().optional(),
  sortOrder: z.number().int().optional(),
});

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const where = {};
    if (req.query.operatorId) where.operatorId = String(req.query.operatorId);
    if (req.query.isActive !== undefined) where.isActive = req.query.isActive === 'true';

    const items = await prisma.payload.findMany({
      where,
      include: {
        operator: { select: { id: true, code: true, name: true } },
        server: { select: { id: true, name: true, host: true } },
      },
      orderBy: [{ operatorId: 'asc' }, { sortOrder: 'asc' }],
    });
    res.json({ items });
  }),
);

router.post(
  '/',
  asyncHandler(async (req, res) => {
    const data = payloadSchema.parse(req.body);
    res.status(201).json(await prisma.payload.create({ data }));
  }),
);

router.patch(
  '/:id',
  asyncHandler(async (req, res) => {
    const data = payloadSchema.partial().parse(req.body);
    res.json(await prisma.payload.update({ where: { id: req.params.id }, data }));
  }),
);

router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    await prisma.payload.delete({ where: { id: req.params.id } });
    res.json({ ok: true });
  }),
);

/** POST /api/payloads/:id/duplicate — util para clonar config entre operadoras. */
router.post(
  '/:id/duplicate',
  asyncHandler(async (req, res) => {
    const source = await prisma.payload.findUniqueOrThrow({ where: { id: req.params.id } });
    const { id, createdAt, updatedAt, ...rest } = source;
    const clone = await prisma.payload.create({
      data: {
        ...rest,
        name: `${source.name} (copia)`,
        operatorId: req.body.operatorId ?? source.operatorId,
        isActive: false,
      },
    });
    res.status(201).json(clone);
  }),
);

export default router;
