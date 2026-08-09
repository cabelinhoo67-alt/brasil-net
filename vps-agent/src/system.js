import { spawn } from 'node:child_process';
import { readFile, writeFile, unlink, mkdir } from 'node:fs/promises';
import path from 'node:path';

import { config } from './config.js';
import { log } from './log.js';

/**
 * Camada que fala com o sistema operacional.
 *
 * Regra de ouro deste arquivo: o agente so mexe em contas que ele mesmo criou,
 * identificadas por pertencerem ao grupo `config.group`. Qualquer pedido para
 * tocar em conta fora do grupo e recusado — um bug no backend, ou um token
 * vazado, nao pode virar `userdel root`.
 */

const USERNAME_RE = /^[a-z_][a-z0-9_-]{2,31}$/;

/** Contas que jamais podem ser alvo, mesmo que algo dê muito errado. */
const FORBIDDEN = new Set([
  'root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news',
  'uucp', 'proxy', 'www-data', 'backup', 'list', 'irc', 'nobody', 'systemd-network',
  'sshd', 'ubuntu', 'debian', 'admin', 'postgres', 'mysql', 'redis', 'docker',
]);

export class SystemError extends Error {}

function assertSafeUsername(username) {
  if (typeof username !== 'string' || !USERNAME_RE.test(username)) {
    throw new SystemError(`Nome de usuario invalido: "${username}"`);
  }
  if (FORBIDDEN.has(username)) {
    throw new SystemError(`Recusado: "${username}" e uma conta do sistema`);
  }
}

/** Executa um comando sem shell — os argumentos nunca sao interpretados. */
function run(command, args, { input, allowFail = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] });

    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => (stdout += chunk));
    child.stderr.on('data', (chunk) => (stderr += chunk));

    child.on('error', (error) =>
      reject(new SystemError(`Nao consegui executar ${command}: ${error.message}`)),
    );

    child.on('close', (code) => {
      if (code === 0 || allowFail) {
        resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
        return;
      }
      reject(
        new SystemError(
          `${command} ${args.join(' ')} falhou (codigo ${code}): ${stderr.trim() || stdout.trim()}`,
        ),
      );
    });

    if (input !== undefined) child.stdin.write(input);
    child.stdin.end();
  });
}

// ----------------------------- leitura do sistema --------------------------

/** Usuarios do /etc/passwd que pertencem ao nosso grupo. */
export async function listManagedUsers() {
  const gid = await groupId();

  const passwd = await readFile('/etc/passwd', 'utf8');
  const users = [];

  for (const line of passwd.split('\n')) {
    if (!line.trim()) continue;
    const [name, , uid, userGid, , home, shell] = line.split(':');
    if (Number(userGid) !== gid) continue;
    if (Number(uid) < 1000) continue; // nunca conta de sistema

    users.push({ username: name, uid: Number(uid), home, shell });
  }

  return users;
}

/**
 * Estado real de cada conta: hash, bloqueio e validade.
 * Ler /etc/shadow e o que permite ao agente saber o que ja esta certo e
 * evitar reescrever tudo a cada ciclo.
 */
export async function readShadow() {
  const raw = await readFile('/etc/shadow', 'utf8');
  const map = new Map();

  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    const parts = line.split(':');
    const username = parts[0];
    const hash = parts[1] ?? '';
    const expireDays = parts[7];

    map.set(username, {
      hash: hash.replace(/^!+/, ''),
      locked: hash.startsWith('!'),
      // Campo 8 do shadow: dias desde 1970 em que a conta expira.
      expiresAt:
        expireDays === '' || expireDays === undefined
          ? null
          : new Date(Number(expireDays) * 86_400_000),
    });
  }

  return map;
}

let cachedGid = null;

async function groupId() {
  if (cachedGid !== null) return cachedGid;

  const { code, stdout } = await run('getent', ['group', config.group], { allowFail: true });
  if (code !== 0 || !stdout) {
    throw new SystemError(`Grupo "${config.group}" nao existe. Rode o install.sh.`);
  }

  cachedGid = Number(stdout.split(':')[2]);
  return cachedGid;
}

export async function ensureGroup() {
  const { code } = await run('getent', ['group', config.group], { allowFail: true });
  if (code === 0) return;

  log.info(`criando grupo ${config.group}`);
  await run('groupadd', ['--system', config.group]);
  cachedGid = null;
}

/** Confere que a conta existe E pertence ao nosso grupo antes de alterar. */
async function assertManaged(username) {
  assertSafeUsername(username);

  const managed = await listManagedUsers();
  if (!managed.some((user) => user.username === username)) {
    throw new SystemError(
      `"${username}" nao pertence ao grupo ${config.group}; recusando alteracao`,
    );
  }
}

export async function userExists(username) {
  assertSafeUsername(username);
  const { code } = await run('id', ['-u', username], { allowFail: true });
  return code === 0;
}

// ------------------------------ escrita ------------------------------------

/**
 * Cria a conta.
 *
 * Shell `nologin` de proposito: o cliente so precisa de encaminhamento de
 * portas, que nao passa pelo shell. Assim ninguem ganha terminal na VPS.
 */
export async function createUser({ username, passwordHash, expiresAt, connectionLimit }) {
  assertSafeUsername(username);
  await ensureGroup();

  if (await userExists(username)) {
    // Conta ja existe: pode ser reprocessamento da fila. Convergimos em vez
    // de falhar — o resultado final e o mesmo.
    log.warn(`${username} ja existe, aplicando atualizacao`);
    await updateUser({ username, passwordHash, expiresAt, connectionLimit });
    return;
  }

  await run('useradd', [
    '--gid', config.group,
    '--shell', config.shell,
    '--create-home',
    '--comment', 'tunnel-agent',
    username,
  ]);

  await setPassword(username, passwordHash);
  await setExpiry(username, expiresAt);
  await setMaxLogins(username, connectionLimit);

  log.info(`conta criada: ${username}`);
}

export async function updateUser({ username, passwordHash, expiresAt, connectionLimit }) {
  await assertManaged(username);

  if (passwordHash) await setPassword(username, passwordHash);
  await setExpiry(username, expiresAt);
  await setMaxLogins(username, connectionLimit);

  // Atualizar senha nao derruba quem ja esta logado; derrubamos na mao para
  // a troca valer na hora.
  if (passwordHash) await killSessions(username);

  log.info(`conta atualizada: ${username}`);
}

export async function lockUser(username) {
  await assertManaged(username);
  await run('usermod', ['--lock', username]);
  await killSessions(username);
  log.info(`conta bloqueada: ${username}`);
}

export async function unlockUser(username) {
  await assertManaged(username);
  await run('usermod', ['--unlock', username]);
  log.info(`conta desbloqueada: ${username}`);
}

export async function deleteUser(username) {
  assertSafeUsername(username);

  if (!(await userExists(username))) {
    await removeLimits(username);
    return; // ja nao existe: nada a fazer
  }

  await assertManaged(username);
  await killSessions(username);
  await removeLimits(username);

  await run('userdel', ['--remove', username], { allowFail: true });
  log.info(`conta removida: ${username}`);
}

/**
 * Aplica o hash bcrypt direto no /etc/shadow.
 *
 * A senha em claro nunca sai do painel: o mesmo hash que autentica no app
 * autentica no SSH. Depende do libxcrypt aceitar `$2a$`/`$2b$` — padrao em
 * Debian 11+, Ubuntu 20.04+ e derivados.
 */
async function setPassword(username, passwordHash) {
  if (!passwordHash) return;

  if (!/^\$(2[aby]|6|5|y)\$/.test(passwordHash)) {
    throw new SystemError(`Formato de hash nao reconhecido para ${username}`);
  }

  await run('chpasswd', ['--encrypted'], { input: `${username}:${passwordHash}\n` });
}

/**
 * Validade da conta. O proprio sshd recusa login depois da data — o cliente
 * para de conectar sozinho, sem depender do backend estar no ar.
 */
async function setExpiry(username, expiresAt) {
  if (!expiresAt) {
    await run('chage', ['--expiredate', '-1', username]);
    return;
  }

  const date = new Date(expiresAt);
  const iso = date.toISOString().slice(0, 10);
  await run('chage', ['--expiredate', iso, username]);
}

/**
 * Limite de conexoes simultaneas no proprio SSH, via pam_limits.
 *
 * Isto e o cinto de seguranca do controle que o backend ja faz por heartbeat:
 * mesmo que alguem burle o app, o sshd recusa a sessao excedente.
 */
async function setMaxLogins(username, connectionLimit) {
  const limit = Number(connectionLimit);
  if (!Number.isFinite(limit) || limit < 1) {
    await removeLimits(username);
    return;
  }

  await mkdir(config.limitsDir, { recursive: true });

  const file = limitsFile(username);
  const content =
    `# gerado pelo tunnel-agent — nao editar a mao\n` +
    `${username} - maxlogins ${limit}\n`;

  await writeFile(file, content, { mode: 0o644 });
}

function limitsFile(username) {
  return path.join(config.limitsDir, `99-tunnel-${username}.conf`);
}

async function removeLimits(username) {
  try {
    await unlink(limitsFile(username));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

export async function readMaxLogins(username) {
  try {
    const raw = await readFile(limitsFile(username), 'utf8');
    const match = raw.match(/maxlogins\s+(\d+)/);
    return match ? Number(match[1]) : null;
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

/** Encerra tudo que a conta tiver aberto (sessoes SSH, tuneis). */
export async function killSessions(username) {
  assertSafeUsername(username);
  await run('pkill', ['-KILL', '-u', username], { allowFail: true });
}

// --------------------------- diagnostico -----------------------------------

/** Checagens de ambiente rodadas uma vez na subida do agente. */
export async function preflight() {
  const problems = [];

  if (process.getuid && process.getuid() !== 0) {
    problems.push('o agente precisa rodar como root (useradd/chpasswd exigem)');
  }

  for (const binary of ['useradd', 'usermod', 'userdel', 'chpasswd', 'chage', 'getent']) {
    const { code } = await run('sh', ['-c', `command -v ${binary}`], { allowFail: true });
    if (code !== 0) problems.push(`comando ausente: ${binary}`);
  }

  // pam_limits e o que faz o maxlogins valer no SSH.
  try {
    const pam = await readFile('/etc/pam.d/sshd', 'utf8');
    if (!/^\s*session\s+required\s+pam_limits\.so/m.test(pam)) {
      problems.push(
        'pam_limits.so nao esta ativo em /etc/pam.d/sshd — o limite de conexoes nao sera aplicado pelo sshd',
      );
    }
  } catch {
    problems.push('nao consegui ler /etc/pam.d/sshd');
  }

  return problems;
}
