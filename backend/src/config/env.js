import 'dotenv/config';
import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  PORT: z.coerce.number().default(3333),

  DATABASE_URL: z.string().min(1, 'DATABASE_URL e obrigatorio'),

  JWT_SECRET: z.string().min(16, 'JWT_SECRET precisa ter ao menos 16 caracteres'),
  JWT_PANEL_EXPIRES: z.string().default('8h'),
  JWT_APP_EXPIRES: z.string().default('7d'),

  // Chave estatica usada na comunicacao maquina-a-maquina (bot -> backend)
  INTERNAL_API_KEY: z.string().min(8),

  // Mercado Pago
  MP_ACCESS_TOKEN: z.string().default(''),
  MP_WEBHOOK_SECRET: z.string().default(''),
  PIX_EXPIRATION_MINUTES: z.coerce.number().default(30),

  // Callback do bot: backend avisa o bot quando o Pix e confirmado
  BOT_CALLBACK_URL: z.string().default('http://localhost:3334/internal/order-paid'),

  // Sessao considerada morta apos N segundos sem heartbeat
  SESSION_TIMEOUT_SECONDS: z.coerce.number().default(120),
});

const parsed = schema.safeParse(process.env);

if (!parsed.success) {
  console.error('\n[env] Configuracao invalida no arquivo .env:\n');
  for (const issue of parsed.error.issues) {
    console.error(`  - ${issue.path.join('.')}: ${issue.message}`);
  }
  process.exit(1);
}

export const env = parsed.data;
