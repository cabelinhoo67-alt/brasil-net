import { api } from '../services/api.js';
import { STEP, clearState, getState, setState } from '../services/state.js';
import * as msg from './messages.js';
import { config } from '../config.js';

/** Fila de acompanhamento: usada quando o webhook nao chega (fallback por poll). */
const watchers = new Map();

/**
 * @param {object} sock socket do Baileys
 * @param {string} jid  contato
 * @param {string} text conteudo normalizado
 */
export async function handleMessage(sock, jid, text) {
  const send = (body) => sock.sendMessage(jid, { text: body });
  const state = getState(jid);
  const input = text.trim().toLowerCase();

  if (['menu', 'oi', 'ola', 'olá', 'bom dia', 'boa tarde', 'boa noite', 'inicio', 'início'].includes(input)) {
    clearState(jid);
    return send(msg.welcome());
  }

  if (input === 'status') {
    return checkStatus(sock, jid);
  }

  switch (state.step) {
    case STEP.CHOOSING_PLAN:
      return choosePlan(sock, jid, input, state);

    case STEP.WAITING_PAYMENT:
      if (input === '0' || input === 'cancelar') {
        clearState(jid);
        return send('Pedido cancelado. Digite *menu* quando quiser recomecar.');
      }
      return checkStatus(sock, jid);

    default:
      return mainMenu(sock, jid, input);
  }
}

async function mainMenu(sock, jid, input) {
  const send = (body) => sock.sendMessage(jid, { text: body });

  switch (input) {
    case '1': {
      const { items } = await api.listPlans();
      if (!items.length) return send('Nenhum plano disponivel no momento. Fale com o suporte.');

      setState(jid, { step: STEP.CHOOSING_PLAN, plans: items });
      return send(msg.planList(items));
    }
    case '2':
      return send(msg.renewInfo());
    case '3':
      return send(msg.humanSupport());
    case '4':
      return send(msg.downloadApp());
    default:
      return send(msg.fallback());
  }
}

async function choosePlan(sock, jid, input, state) {
  const send = (body) => sock.sendMessage(jid, { text: body });

  if (input === '0') {
    clearState(jid);
    return send(msg.welcome());
  }

  const index = Number(input) - 1;
  const plan = state.plans?.[index];
  if (!plan) return send('Opcao invalida. Digite o numero do plano ou *0* para voltar.');

  await send('Gerando seu Pix, um instante...');

  try {
    const order = await api.createPix({ whatsapp: jid, planId: plan.id });

    setState(jid, { step: STEP.WAITING_PAYMENT, orderId: order.orderId, planName: plan.name });

    await send(msg.pixInstructions(plan, order.amountCents));
    // Mensagem separada e "limpa": o cliente segura para copiar o codigo inteiro.
    await sock.sendMessage(jid, { text: order.pix.copyPaste });

    startWatching(sock, jid, order.orderId);
  } catch (err) {
    console.error('[flow] falha ao gerar Pix:', err.message);
    clearState(jid);
    await send('Nao consegui gerar o Pix agora. Tente novamente em instantes ou digite *3* para falar com um atendente.');
  }
}

async function checkStatus(sock, jid) {
  const send = (body) => sock.sendMessage(jid, { text: body });
  const state = getState(jid);

  if (!state.orderId) return send('Voce nao tem nenhum pedido em aberto. Digite *menu* para comecar.');

  const order = await api.getOrder(state.orderId).catch(() => null);

  if (order?.status === 'PAID' && order.credentials) {
    stopWatching(state.orderId);
    clearState(jid);
    return send(msg.credentials(order));
  }

  return send(msg.paymentPending());
}

/**
 * Fallback de confirmacao: mesmo com o webhook configurado, o poll cobre
 * o caso do backend estar atras de NAT/localhost sem URL publica.
 */
function startWatching(sock, jid, orderId) {
  stopWatching(orderId);
  let attempts = 0;

  const timer = setInterval(async () => {
    attempts += 1;
    if (attempts > config.pollMaxAttempts) return stopWatching(orderId);

    try {
      const order = await api.getOrder(orderId);
      if (order.status === 'PAID' && order.credentials) {
        stopWatching(orderId);
        clearState(jid);
        await sock.sendMessage(jid, { text: msg.credentials(order) });
      } else if (order.status === 'EXPIRED' || order.status === 'CANCELED') {
        stopWatching(orderId);
        clearState(jid);
        await sock.sendMessage(jid, { text: 'Seu Pix expirou. Digite *menu* para gerar um novo.' });
      }
    } catch (err) {
      console.error('[watcher] erro ao consultar pedido:', err.message);
    }
  }, config.pollIntervalMs);

  watchers.set(orderId, timer);
}

export function stopWatching(orderId) {
  const timer = watchers.get(orderId);
  if (timer) {
    clearInterval(timer);
    watchers.delete(orderId);
  }
}
