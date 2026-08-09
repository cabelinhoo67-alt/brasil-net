import { config } from '../config.js';

export const brl = (cents) =>
  (cents / 100).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });

export function welcome() {
  return (
    `Ola! Bem-vindo(a) a *${config.companyName}*.\n\n` +
    'Escolha uma opcao:\n\n' +
    '*1* - Comprar acesso\n' +
    '*2* - Ja sou cliente (renovar)\n' +
    '*3* - Falar com atendente\n' +
    '*4* - Baixar o aplicativo\n\n' +
    '_Digite o numero da opcao._'
  );
}

export function planList(plans) {
  const lines = plans.map(
    (p, i) =>
      `*${i + 1}* - ${p.name}\n     ${p.days} dias | ${p.connectionLimit} conexao(oes) | ${brl(p.priceCents)}`,
  );

  return (
    'Planos disponiveis:\n\n' +
    lines.join('\n\n') +
    '\n\n_Digite o numero do plano desejado, ou *0* para voltar._'
  );
}

export function pixInstructions(plan, amountCents) {
  return (
    `Pedido gerado.\n\n` +
    `Plano: *${plan.name}*\n` +
    `Validade: *${plan.days} dias*\n` +
    `Valor: *${brl(amountCents)}*\n\n` +
    'Copie o codigo Pix da proxima mensagem e cole no app do seu banco.\n' +
    'Assim que o pagamento cair, envio seu login e senha automaticamente aqui. ' +
    'Pode deixar a conversa aberta.'
  );
}

export function credentials({ credentials: cred, plan }) {
  const expires = cred.expiresAt
    ? new Date(cred.expiresAt).toLocaleDateString('pt-BR')
    : `${plan.days} dias`;

  return (
    'Pagamento confirmado. Seu acesso esta pronto:\n\n' +
    `Usuario: *${cred.username}*\n` +
    `Senha: *${cred.password}*\n` +
    `Plano: ${plan.name}\n` +
    `Valido ate: *${expires}*\n\n` +
    (config.appDownloadUrl ? `Baixe o app: ${config.appDownloadUrl}\n\n` : '') +
    'Abra o aplicativo, faca login com esses dados e conecte. ' +
    'Guarde esta mensagem — a senha nao e reenviada por seguranca.'
  );
}

export function paymentPending() {
  return (
    'Ainda nao identifiquei o pagamento.\n\n' +
    'Se voce acabou de pagar, aguarde alguns instantes — a confirmacao costuma levar ate 2 minutos. ' +
    'Vou te avisar aqui assim que cair.\n\n' +
    'Digite *status* para consultar de novo ou *menu* para recomecar.'
  );
}

export function humanSupport() {
  const contact = config.supportNumber
    ? `\n\nChame no numero: wa.me/${config.supportNumber.replace(/\D/g, '')}`
    : '';
  return `Certo! Um atendente vai te responder por aqui em instantes.${contact}`;
}

export function downloadApp() {
  return config.appDownloadUrl
    ? `Baixe o aplicativo por este link:\n${config.appDownloadUrl}`
    : 'O link do aplicativo ainda nao foi configurado. Fale com o suporte.';
}

export function renewInfo() {
  return (
    'Para renovar, escolha um plano e pague o Pix — o sistema gera um novo acesso na hora.\n\n' +
    'Se quiser manter o *mesmo usuario e senha*, digite *3* e um atendente faz a renovacao manual.\n\n' +
    'Digite *1* para ver os planos.'
  );
}

export function fallback() {
  return 'Nao entendi. Digite *menu* para ver as opcoes.';
}
