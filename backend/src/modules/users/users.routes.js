import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler, pageResult, paginate } from '../../utils/http.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { assertOwnership, scopeFilter } from '../../utils/hierarchy.js';
import { notFound } from '../../utils/errors.js';
import * as service from './users.service.js';

const router = Router();

router.use(authenticate('panel'), requireRole('ADMIN', 'MASTER', 'RESELLER'));

const createSchema = z.object({
  username: z.string().min(3).max(32).regex(/^[a-zA-Z0-9._-]+$/, 'Use apenas letras, numeros, ponto, hifen ou underline'),
  password: z.string().min(4).max(64),
  role: z.enum(['MASTER', 'RESELLER', 'CLIENT']),
  fullName: z.string().max(120).optional(),
  whatsapp: z.string().max(24).optional(),
  note: z.string().max(500).optional(),
  planId: z.string().uuid().optional(),
  days: z.number().int().min(1).max(3650).optional(),
  connectionLimit: z.number().int().min(1).max(50).optional(),
  initialCredits: z.number().int().min(0).max(100000).optional(),
});

/** GET /api/users — lista a rede do usuario logado. */
router.get(
  '/',
  asyncHandler(async (req, res) => {
    const pg = paginate(req.query);
    const scope = await scopeFilter(req.user);

    const where = { ...scope };
    if (req.query.role) where.role = req.query.role;
    if (req.query.parentId) where.parentId = req.query.parentId;
    if (req.query.search) {
      where.OR = [
        { username: { contains: String(req.query.search), mode: 'insensitive' } },
        { fullName: { contains: String(req.query.search), mode: 'insensitive' } },
        { whatsapp: { contains: String(req.query.search) } },
      ];
    }
    if (req.query.status === 'expired') where.expiresAt = { lt: new Date() };
    if (req.query.status === 'active') where.expiresAt = { gte: new Date() };

    const [items, total] = await Promise.all([
      prisma.user.findMany({
        where,
        select: service.userSelect,
        orderBy: { createdAt: 'desc' },
        skip: pg.skip,
        take: pg.take,
      }),
      prisma.user.count({ where }),
    ]);

    res.json(pageResult(items.map(service.decorate), total, pg));
  }),
);

/** GET /api/users/:id */
router.get(
  '/:id',
  asyncHandler(async (req, res) => {
    await assertOwnership(req.user, req.params.id);
    const user = await prisma.user.findUnique({ where: { id: req.params.id }, select: service.userSelect });
    if (!user) throw notFound('Usuario nao encontrado');

    const activeSessions = await prisma.session.count({
      where: { userId: user.id, closedAt: null },
    });

    res.json({ ...service.decorate(user), activeSessions });
  }),
);

/** POST /api/users — cria revendedor ou cliente final. */
router.post(
  '/',
  asyncHandler(async (req, res) => {
    const input = createSchema.parse(req.body);
    const created = await service.createUser(req.user, input);
    res.status(201).json(created);
  }),
);

const renewSchema = z.object({
  planId: z.string().uuid().optional(),
  days: z.number().int().min(1).max(3650).optional(),
});

/** POST /api/users/:id/renew */
router.post(
  '/:id/renew',
  asyncHandler(async (req, res) => {
    await assertOwnership(req.user, req.params.id);
    const input = renewSchema.parse(req.body);
    res.json(await service.renewClient(req.user, req.params.id, input));
  }),
);

const updateSchema = z.object({
  fullName: z.string().max(120).nullable().optional(),
  whatsapp: z.string().max(24).nullable().optional(),
  note: z.string().max(500).nullable().optional(),
  password: z.string().min(4).max(64).optional(),
  connectionLimit: z.number().int().min(1).max(50).optional(),
  isActive: z.boolean().optional(),
  isBlocked: z.boolean().optional(),
});

/** PATCH /api/users/:id */
router.patch(
  '/:id',
  asyncHandler(async (req, res) => {
    await assertOwnership(req.user, req.params.id);
    const input = updateSchema.parse(req.body);
    res.json(await service.updateUser(req.user, req.params.id, input));
  }),
);

/** DELETE /api/users/:id */
router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    await assertOwnership(req.user, req.params.id);
    res.json(await service.deleteUser(req.user, req.params.id));
  }),
);

/** GET /api/users/:id/sessions — conexoes simultaneas do cliente. */
router.get(
  '/:id/sessions',
  asyncHandler(async (req, res) => {
    await assertOwnership(req.user, req.params.id);
    const sessions = await prisma.session.findMany({
      where: { userId: req.params.id, closedAt: null },
      orderBy: { lastSeenAt: 'desc' },
    });
    res.json({ items: sessions });
  }),
);

/** DELETE /api/users/:id/sessions — derruba todas as conexoes do cliente. */
router.delete(
  '/:id/sessions',
  asyncHandler(async (req, res) => {
    await assertOwnership(req.user, req.params.id);
    const result = await prisma.session.updateMany({
      where: { userId: req.params.id, closedAt: null },
      data: { closedAt: new Date() },
    });
    res.json({ ok: true, closed: result.count });
  }),
);

export default router;
