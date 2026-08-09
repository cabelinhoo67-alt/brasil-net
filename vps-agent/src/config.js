import 'dotenv/config';

export const config = {
  apiUrl: (process.env.API_URL || 'http://localhost:3333').replace(/\/$/, ''),
  agentToken: process.env.AGENT_TOKEN || '',

  /** Grupo que marca as contas gerenciadas. Nada fora dele e tocado. */
  group: process.env.TUNNEL_GROUP || 'tunnel',

  /** Sem shell: o cliente so precisa de encaminhamento de portas. */
  shell: process.env.TUNNEL_SHELL || '/usr/sbin/nologin',

  limitsDir: process.env.LIMITS_DIR || '/etc/security/limits.d',

  /** Intervalo entre buscas na fila de tarefas. */
  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS || 10_000),

  /** Reconciliacao completa: conserta divergencia depois de queda longa. */
  syncIntervalMs: Number(process.env.SYNC_INTERVAL_MS || 15 * 60_000),

  batchSize: Number(process.env.BATCH_SIZE || 25),

  /** Modo simulacao: registra o que faria, sem tocar no sistema. */
  dryRun: process.env.DRY_RUN === 'true',

  logLevel: process.env.LOG_LEVEL || 'info',
  version: '1.0.0',
};

export function validateConfig() {
  const problems = [];

  if (!config.agentToken) {
    problems.push('AGENT_TOKEN vazio — gere um no painel (Servidores > gerar token)');
  }
  if (!config.apiUrl.startsWith('http')) {
    problems.push('API_URL invalida');
  }
  if (config.apiUrl.startsWith('http://') && !config.apiUrl.includes('localhost')) {
    // Nao e fatal, mas o token e os hashes viajam nessa conexao.
    problems.push('AVISO: API_URL sem HTTPS — use TLS em producao');
  }

  return problems;
}
