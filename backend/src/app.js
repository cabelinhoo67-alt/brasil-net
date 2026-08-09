import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';

import { env } from './config/env.js';
import { errorHandler, notFoundHandler } from './middlewares/error.js';
import { authenticate, requireRole } from './middlewares/auth.js';
import { asyncHandler } from './utils/http.js';
import { prisma } from './lib/prisma.js';
import { descendantIds } from './utils/hierarchy.js';

import authRoutes from './modules/auth/auth.routes.js';
import usersRoutes from './modules/users/users.routes.js';
import creditsRoutes from './modules/credits/credits.routes.js';
import payloadsRoutes from './modules/payloads/payloads.routes.js';
import serversRoutes from './modules/servers/servers.routes.js';
import plansRoutes from './modules/plans/plans.routes.js';
import mobileRoutes from './modules/mobile/mobile.routes.js';
import paymentsRoutes from './modules/payments/payments.routes.js';
import agentRoutes from './modules/agent/agent.routes.js';
import settingsRoutes from './modules/settings/settings.routes.js';

export function createApp() {
  const app = express();

  app.set('trust proxy', 1); // atras de nginx/cloudflare: req.ip real
  app.use(helmet());
  app.use(cors({ origin: true }));
  app.use(express.json({ limit: '1mb' }));
  app.use(morgan(env.NODE_ENV === 'development' ? 'dev' : 'combined'));

  app.get('/health', (_req, res) => res.json({ ok: true, uptime: process.uptime() }));

  app.use('/api/auth', authRoutes);
  app.use('/api/users', usersRoutes);
  app.use('/api/credits', creditsRoutes);
  app.use('/api/payloads', payloadsRoutes);
  app.use('/api/servers', serversRoutes);
  app.use('/api/plans', plansRoutes);
  app.use('/api/payments', paymentsRoutes);
  app.use('/api/settings', settingsRoutes);

  // API consumida pelo aplicativo Flutter
  app.use('/api/app', mobileRoutes);

  // Fila de provisionamento consumida pelos agentes das VPS
  app.use('/api/agent', agentRoutes);

  /** GET /api/dashboard — numeros da rede do usuario logado. */
  app.get(
    '/api/dashboard',
    authenticate('panel'),
    requireRole('ADMIN', 'MASTER', 'RESELLER'),
    asyncHandler(async (req, res) => {
      const ids = req.user.role === 'ADMIN' ? null : await descendantIds(req.user.id);
      const networkFilter = ids ? { id: { in: ids.filter((i) => i !== req.user.id) } } : {};
      const now = new Date();

      const [clients, activeClients, expiredClients, resellers, onlineNow, balance] = await Promise.all([
        prisma.user.count({ where: { ...networkFilter, role: 'CLIENT' } }),
        prisma.user.count({ where: { ...networkFilter, role: 'CLIENT', expiresAt: { gte: now }, isBlocked: false } }),
        prisma.user.count({ where: { ...networkFilter, role: 'CLIENT', expiresAt: { lt: now } } }),
        prisma.user.count({ where: { ...networkFilter, role: { in: ['MASTER', 'RESELLER'] } } }),
        prisma.session.count({
          where: {
            closedAt: null,
            lastSeenAt: { gte: new Date(Date.now() - env.SESSION_TIMEOUT_SECONDS * 1000) },
            ...(ids ? { user: { id: { in: ids } } } : {}),
          },
        }),
        prisma.user.findUnique({ where: { id: req.user.id }, select: { credits: true } }),
      ]);

      res.json({
        clients,
        activeClients,
        expiredClients,
        resellers,
        onlineNow,
        credits: req.user.role === 'ADMIN' ? null : balance.credits,
      });
    }),
  );

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
