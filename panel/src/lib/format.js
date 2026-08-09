export const brl = (cents) =>
  ((cents ?? 0) / 100).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });

export function date(value) {
  if (!value) return '--';
  return new Date(value).toLocaleDateString('pt-BR');
}

export function dateTime(value) {
  if (!value) return '--';
  return new Date(value).toLocaleString('pt-BR', {
    day: '2-digit',
    month: '2-digit',
    year: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

/** "ha 5 min", "ha 2 h" — usado na lista de sessoes ativas. */
export function relative(value) {
  if (!value) return '--';
  const diff = Date.now() - new Date(value).getTime();
  const min = Math.floor(diff / 60000);
  if (min < 1) return 'agora';
  if (min < 60) return `ha ${min} min`;
  const hours = Math.floor(min / 60);
  if (hours < 24) return `ha ${hours} h`;
  return `ha ${Math.floor(hours / 24)} d`;
}

/**
 * Situacao do cliente a partir dos campos que a API ja devolve.
 * Ordem importa: bloqueio manual vence vencimento.
 */
export function clientStatus(user) {
  if (user.isBlocked || !user.isActive) {
    return { label: 'Bloqueado', tone: 'bad' };
  }
  if (user.expired) return { label: 'Vencido', tone: 'bad' };
  if (user.daysLeft !== null && user.daysLeft !== undefined && user.daysLeft <= 3) {
    return { label: `Vence em ${user.daysLeft}d`, tone: 'warn' };
  }
  return { label: 'Ativo', tone: 'ok' };
}

export const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
