import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler } from '../../utils/http.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';

const router = Router();
router.use(authenticate('panel'));

const planSchema = z.object({
  name: z.string().min(2).max(60),
  days: z.number().int().min(1).max(3650),
  connectionLimit: z.number().int().min(1).max(50).optional(),
  creditCost: z.number().int().min(0).max(100000).optional(),
  priceCents: z.number().int().min(0).optional(),
  description: z.string().max(300).nullable().optional(),
  isPublic: z.boolean().optional(),
  isActive: z.boolean().optional(),
  sortOrder: z.number().int().optional(),
});

/** Qualquer nivel do painel precisa ler os planos para criar clientes. */
router.get(
  '/',
  asyncHandler(async (req, res) => {
    const where = req.user.role === 'ADMIN' ? {} : { isActive: true };
    const items = await prisma.plan.findMany({ where, orderBy: [{ sortOrder: 'asc' }, { days: 'asc' }] });
    res.json({ items });
  }),
);

router.post(
  '/',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    res.status(201).json(await prisma.plan.create({ data: planSchema.parse(req.body) }));
  }),
);

router.patch(
  '/:id',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const data = planSchema.partial().parse(req.body);
    res.json(await prisma.plan.update({ where: { id: req.params.id }, data }));
  }),
);

router.delete(
  '/:id',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    await prisma.plan.delete({ where: { id: req.params.id } });
    res.json({ ok: true });
  }),
);

export default router;
