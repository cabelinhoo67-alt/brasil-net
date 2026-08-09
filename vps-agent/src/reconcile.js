import { api } from './api.js';
import { log } from './log.js';
import { config } from './config.js';
import * as system from './system.js';

const day = (value) => (value ? new Date(value).toISOString().slice(0, 10) : null);

/**
 * Reconciliacao completa: compara o que o backend quer com o que existe na VPS
 * e corrige a diferenca.
 *
 * Isto e a rede de seguranca do sistema. A fila de tarefas cobre o dia a dia;
 * a reconciliacao cobre o que a fila nao pega — VPS reinstalada, agente parado
 * por dias, tarefa que estourou as tentativas, alguem mexendo na mao.
 *
 * Idempotente por construcao: rodar dez vezes seguidas da o mesmo resultado.
 */
export async function reconcile() {
  const { users: desired } = await api.fetchDesiredState();
  const existing = await system.listManagedUsers();
  const shadow = await system.readShadow();

  const existingNames = new Set(existing.map((user) => user.username));
  const desiredNames = new Set(desired.map((user) => user.username));

  const report = { created: 0, updated: 0, locked: 0, unlocked: 0, removed: 0, failed: 0 };

  for (const target of desired) {
    try {
      if (!existingNames.has(target.username)) {
        if (config.dryRun) {
          log.info(`[dry-run] criaria ${target.username}`);
        } else {
          await system.createUser(target);
          if (target.locked) await system.lockUser(target.username);
        }
        report.created += 1;
        continue;
      }

      const current = shadow.get(target.username);
      const currentLimit = await system.readMaxLogins(target.username);

      // Comparamos so o que importa; reescrever /etc/shadow a toa gera ruido
      // no log e derruba sessoes sem motivo.
      const passwordDiffers = current && current.hash !== target.passwordHash;
      const expiryDiffers = day(current?.expiresAt) !== day(target.expiresAt);
      const limitDiffers = currentLimit !== target.connectionLimit;

      if (passwordDiffers || expiryDiffers || limitDiffers) {
        if (config.dryRun) {
          log.info(
            `[dry-run] atualizaria ${target.username}` +
              ` (senha=${passwordDiffers} validade=${expiryDiffers} limite=${limitDiffers})`,
          );
        } else {
          await system.updateUser({
            username: target.username,
            passwordHash: passwordDiffers ? target.passwordHash : null,
            expiresAt: target.expiresAt,
            connectionLimit: target.connectionLimit,
          });
        }
        report.updated += 1;
      }

      if (current && current.locked !== target.locked) {
        if (config.dryRun) {
          log.info(`[dry-run] ${target.locked ? 'bloquearia' : 'desbloquearia'} ${target.username}`);
        } else if (target.locked) {
          await system.lockUser(target.username);
        } else {
          await system.unlockUser(target.username);
        }
        report[target.locked ? 'locked' : 'unlocked'] += 1;
      }
    } catch (error) {
      report.failed += 1;
      log.error(`reconciliacao de ${target.username}: ${error.message}`);
    }
  }

  // Contas gerenciadas que o backend nao conhece mais.
  for (const user of existing) {
    if (desiredNames.has(user.username)) continue;

    try {
      if (config.dryRun) {
        log.info(`[dry-run] removeria ${user.username}`);
      } else {
        await system.deleteUser(user.username);
      }
      report.removed += 1;
    } catch (error) {
      report.failed += 1;
      log.error(`remocao de ${user.username}: ${error.message}`);
    }
  }

  const changed =
    report.created + report.updated + report.locked + report.unlocked + report.removed;

  if (changed > 0 || report.failed > 0) {
    log.info(
      `reconciliacao: +${report.created} criadas, ${report.updated} atualizadas, ` +
        `${report.locked} bloqueadas, ${report.unlocked} liberadas, ` +
        `${report.removed} removidas, ${report.failed} falhas`,
    );
  } else {
    log.debug(`reconciliacao: nada a fazer (${desired.length} contas conferidas)`);
  }

  return { ...report, total: desired.length };
}
