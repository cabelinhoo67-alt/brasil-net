import { config } from './config.js';

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

function write(level, message) {
  if (LEVELS[level] < (LEVELS[config.logLevel] ?? 20)) return;

  const stamp = new Date().toISOString();
  const line = `${stamp} [${level.toUpperCase()}] ${message}`;

  // systemd captura stdout/stderr; nao precisamos de arquivo de log proprio.
  if (level === 'error') console.error(line);
  else console.log(line);
}

export const log = {
  debug: (m) => write('debug', m),
  info: (m) => write('info', m),
  warn: (m) => write('warn', m),
  error: (m) => write('error', m),
};
