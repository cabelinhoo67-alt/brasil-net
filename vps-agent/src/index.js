import { api, ApiError } from './api.js';
import { config, validateConfig } from './config.js';
import { log } from './log.js';
import { reconcile } from './reconcile.js';
import * as system from './system.js';

let running = true;
let lastSync = 0;

/** Executa uma tarefa da fila. Devolve erro em string quando falha. */
async function runTask(task) {
  if (config.dryRun) {
    log.info(`[dry-run] ${task.action} ${task.username}`);
    return null;
  }

  switch (task.action) {
    case 'CREATE':
      await system.createUser({
        username: task.username,
        passwordHash: task.passwordHash,
        expiresAt: task.expiresAt,
        connectionLimit: task.connectionLimit,
      });
      return null;

    case 'UPDATE':
      // Conta some da VPS por qualquer motivo? Recria em vez de falhar.
      if (!(await system.userExists(task.username))) {
        log.warn(`${task.username} nao existe; recriando a partir do UPDATE`);
        await system.createUser({
          username: task.username,
          passwordHash: task.passwordHash,
          expiresAt: task.expiresAt,
          connectionLimit: task.connectionLimit,
        });
        return null;
      }
      await system.updateUser({
        username: task.username,
        passwordHash: task.passwordHash,
        expiresAt: task.expiresAt,
        connectionLimit: task.connectionLimit,
      });
      return null;

    case 'LOCK':
      await system.lockUser(task.username);
      return null;

    case 'UNLOCK':
      await system.unlockUser(task.username);
      return null;

    case 'DELETE':
      await system.deleteUser(task.username);
      return null;

    default:
      return `acao desconhecida: ${task.action}`;
  }
}

async function drainQueue() {
  const { items } = await api.fetchTasks();
  if (items.length === 0) return 0;

  log.info(`${items.length} tarefa(s) na fila`);

  for (const task of items) {
    try {
      const failure = await runTask(task);

      if (failure) {
        await api.reportResult(task.id, false, failure);
        log.error(`${task.action} ${task.username}: ${failure}`);
      } else {
        await api.reportResult(task.id, true);
      }
    } catch (error) {
      // Falha de execucao volta para a fila; o backend controla as tentativas.
      log.error(`${task.action} ${task.username}: ${error.message}`);
      try {
        await api.reportResult(task.id, false, error.message);
      } catch (reportError) {
        log.error(`nao consegui reportar a falha: ${reportError.message}`);
      }
    }
  }

  return items.length;
}

async function tick() {
  try {
    const managed = await system.listManagedUsers();
    await api.heartbeat(managed.length);

    // Esvazia a fila em lotes; se veio lote cheio, provavelmente ha mais.
    let processed = 0;
    for (;;) {
      const count = await drainQueue();
      processed += count;
      if (count < config.batchSize) break;
    }

    if (Date.now() - lastSync >= config.syncIntervalMs) {
      lastSync = Date.now();
      await reconcile();
    }

    if (processed > 0) log.info(`ciclo concluido: ${processed} tarefa(s)`);
  } catch (error) {
    if (error instanceof ApiError && error.status === 403) {
      // Token errado nao melhora com o tempo — vale gritar alto.
      log.error(`token do agente recusado pelo backend: ${error.message}`);
    } else {
      log.warn(`ciclo falhou: ${error.message}`);
    }
  }
}

async function main() {
  log.info(`tunnel-agent ${config.version} iniciando`);
  log.info(`backend: ${config.apiUrl} | grupo: ${config.group} | shell: ${config.shell}`);
  if (config.dryRun) log.warn('DRY_RUN ativo: nada sera alterado no sistema');

  const configProblems = validateConfig();
  for (const problem of configProblems) {
    if (problem.startsWith('AVISO')) log.warn(problem);
    else log.error(problem);
  }
  if (configProblems.some((p) => !p.startsWith('AVISO'))) {
    process.exit(1);
  }

  const envProblems = await system.preflight();
  for (const problem of envProblems) log.warn(problem);
  if (envProblems.some((p) => p.includes('root'))) {
    log.error('abortando: sem root o agente nao consegue criar contas');
    process.exit(1);
  }

  if (!config.dryRun) await system.ensureGroup();

  // Primeira reconciliacao imediata: se a VPS voltou de um reinstall, o
  // sistema converge antes de qualquer cliente tentar conectar.
  try {
    await reconcile();
    lastSync = Date.now();
  } catch (error) {
    log.warn(`reconciliacao inicial falhou: ${error.message}`);
  }

  while (running) {
    await tick();
    await new Promise((resolve) => setTimeout(resolve, config.pollIntervalMs));
  }
}

function shutdown(signal) {
  log.info(`${signal} recebido, encerrando`);
  running = false;
  setTimeout(() => process.exit(0), 1000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

process.on('unhandledRejection', (error) => {
  log.error(`rejeicao nao tratada: ${error?.message ?? error}`);
});

main().catch((error) => {
  log.error(`falha fatal: ${error.message}`);
  process.exit(1);
});
