import { Router } from 'express';
import { z } from 'zod';
import rateLimit from 'express-rate-limit';
import { prisma } from '../../lib/prisma.js';
import { asyncHandler } from '../../utils/http.js';
import { comparePassword, hashPassword, signPanelToken } from '../../utils/security.js';
import { forbidden, unauthorized } from '../../utils/errors.js';
import { authenticate } from '../../middlewares/auth.js';
import { RESELLER_ROLES } from '../../utils/hierarchy.js';

const router = Router();

const loginLimiter = rateLimit({
  windowMs: 5 * 60 * 1000,
  limit: 20,
  message: { error: true, code: 'RATE_LIMITED', message: 'Muitas tentativas. Aguarde alguns minutos.' },
});

const loginSchema = z.object({
  username: z.string().min(3).trim(),
  password: z.string().min(4),
});

/** POST /api/auth/login — acesso ao painel (admin/master/revendedor). */
router.post(
  '/login',
  loginLimiter,
  asyncHandler(async (req, res) => {
    const { username, password } = loginSchema.parse(req.body);

    const user = await prisma.user.findUnique({ where: { username: username.toLowerCase() } });
    if (!user) throw unauthorized('Usuario ou senha invalidos', 'BAD_CREDENTIALS');

    const ok = await comparePassword(password, user.passwordHash);
    if (!ok) throw unauthorized('Usuario ou senha invalidos', 'BAD_CREDENTIALS');

    if (!RESELLER_ROLES.includes(user.role)) {
      throw forbidden('Clientes finais acessam apenas pelo aplicativo', 'PANEL_DENIED');
    }
    if (!user.isActive || user.isBlocked) {
      throw forbidden('Conta desativada. Fale com seu superior.', 'USER_DISABLED');
    }

    await prisma.user.update({ where: { id: user.id }, data: { lastLogin: new Date() } });

    res.json({
      token: signPanelToken(user),
      user: {
        id: user.id,
        username: user.username,
        fullName: user.fullName,
        role: user.role,
        credits: user.credits,
      },
    });
  }),
);

/** GET /api/auth/me — dados do usuario logado + resumo da rede. */
router.get(
  '/me',
  authenticate('panel'),
  asyncHandler(async (req, res) => {
    const [directChildren, clients] = await Promise.all([
      prisma.user.count({ where: { parentId: req.user.id } }),
      prisma.user.count({ where: { parentId: req.user.id, role: 'CLIENT' } }),
    ]);

    res.json({
      id: req.user.id,
      username: req.user.username,
      fullName: req.user.fullName,
      role: req.user.role,
      credits: req.user.role === 'ADMIN' ? null : req.user.credits, // null = ilimitado
      whatsapp: req.user.whatsapp,
      stats: { directChildren, clients },
    });
  }),
);

const changePasswordSchema = z.object({
  currentPassword: z.string().min(4),
  newPassword: z.string().min(6),
});

/** PATCH /api/auth/password — troca da propria senha. */
router.patch(
  '/password',
  authenticate('panel'),
  asyncHandler(async (req, res) => {
    const { currentPassword, newPassword } = changePasswordSchema.parse(req.body);

    const ok = await comparePassword(currentPassword, req.user.passwordHash);
    if (!ok) throw unauthorized('Senha atual incorreta', 'BAD_CREDENTIALS');

    await prisma.user.update({
      where: { id: req.user.id },
      data: { passwordHash: await hashPassword(newPassword) },
    });

    res.json({ ok: true });
  }),
);

export default router;
