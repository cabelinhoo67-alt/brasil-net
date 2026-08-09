/**
 * Estado de conversa por contato. Fica em memoria de proposito:
 * e um fluxo curto e o pedido em si ja esta persistido no banco do backend.
 * Se o bot reiniciar, o cliente digita "menu" e recomeca em 2 segundos.
 */
const conversations = new Map();
const TTL_MS = 30 * 60 * 1000;

export const STEP = {
  IDLE: 'IDLE',
  CHOOSING_PLAN: 'CHOOSING_PLAN',
  WAITING_PAYMENT: 'WAITING_PAYMENT',
};

export function getState(jid) {
  const entry = conversations.get(jid);
  if (!entry) return { step: STEP.IDLE };
  if (Date.now() - entry.updatedAt > TTL_MS) {
    conversations.delete(jid);
    return { step: STEP.IDLE };
  }
  return entry.data;
}

export function setState(jid, data) {
  conversations.set(jid, { data, updatedAt: Date.now() });
}

export function clearState(jid) {
  conversations.delete(jid);
}

/** Evita que o bot responda duas vezes a mesma mensagem reenviada pelo WhatsApp. */
const seen = new Map();
export function alreadyHandled(messageId) {
  const now = Date.now();
  for (const [id, at] of seen) {
    if (now - at > 5 * 60 * 1000) seen.delete(id);
  }
  if (seen.has(messageId)) return true;
  seen.set(messageId, now);
  return false;
}
