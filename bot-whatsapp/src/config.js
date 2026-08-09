import 'dotenv/config';

export const config = {
  port: Number(process.env.BOT_PORT || 3334),
  apiUrl: (process.env.API_URL || 'http://localhost:3333').replace(/\/$/, ''),
  internalKey: process.env.INTERNAL_API_KEY || '',
  sessionPath: process.env.SESSION_PATH || './auth_session',
  companyName: process.env.COMPANY_NAME || 'Minha Revenda',
  supportNumber: process.env.SUPPORT_NUMBER || '',
  appDownloadUrl: process.env.APP_DOWNLOAD_URL || '',
  // Numeros (somente digitos, com DDI) que podem usar comandos administrativos
  adminNumbers: (process.env.ADMIN_NUMBERS || '')
    .split(',')
    .map((n) => n.replace(/\D/g, ''))
    .filter(Boolean),
  // Quanto tempo o bot fica consultando o status do pedido antes de desistir
  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS || 20_000),
  pollMaxAttempts: Number(process.env.POLL_MAX_ATTEMPTS || 45),
};

if (!config.internalKey) {
  console.error('[config] INTERNAL_API_KEY vazio — o backend vai recusar as chamadas do bot.');
}
