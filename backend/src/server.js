import { createApp } from './app.js';
import { env } from './config/env.js';
import { disconnectPrisma, prisma } from './lib/prisma.js';

const app = createApp();

const server = app.listen(env.PORT, () => {
  console.log(`\n  API online em http://localhost:${env.PORT}`);
  console.log(`  Ambiente: ${env.NODE_ENV}`);
  console.log(`  Webhook Pix: POST /api/payments/webhook/mercadopago\n`);
});

/**
 * Faxina periodica das sessoes zumbis (app fechado a forca / celular sem bateria).
 * Sem isso o limite de conexoes simultaneas trava o cliente por ate uma hora.
 */
const CLEANUP_INTERVAL_MS = 60_000;
const cleanup = setInterval(async () => {
  try {
    const deadline = new Date(Date.now() - env.SESSION_TIMEOUT_SECONDS * 1000);
    const { count } = await prisma.session.updateMany({
      where: { closedAt: null, lastSeenAt: { lt: deadline } },
      data: { closedAt: new Date() },
    });
    if (count > 0) console.log(`[cleanup] ${count} sessao(oes) expirada(s) encerrada(s)`);
  } catch (err) {
    console.error('[cleanup] falhou:', err.message);
  }
}, CLEANUP_INTERVAL_MS);

async function shutdown(signal) {
  console.log(`\n${signal} recebido, encerrando...`);
  clearInterval(cleanup);
  server.close(async () => {
    await disconnectPrisma();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
