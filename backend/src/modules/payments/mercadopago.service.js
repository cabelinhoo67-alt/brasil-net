import { MercadoPagoConfig, Payment } from 'mercadopago';
import { env } from '../../config/env.js';
import { badRequest } from '../../utils/errors.js';

let paymentClient = null;

function client() {
  if (!env.MP_ACCESS_TOKEN) {
    throw badRequest('MP_ACCESS_TOKEN nao configurado no .env do backend', 'MP_NOT_CONFIGURED');
  }
  if (!paymentClient) {
    paymentClient = new Payment(new MercadoPagoConfig({ accessToken: env.MP_ACCESS_TOKEN }));
  }
  return paymentClient;
}

/**
 * Cria uma cobranca Pix e devolve o "copia e cola" + QR em base64.
 * O idempotencyKey evita cobranca duplicada se o bot reenviar a requisicao.
 */
export async function createPixCharge({ amountCents, description, payerEmail, externalReference }) {
  const expiration = new Date(Date.now() + env.PIX_EXPIRATION_MINUTES * 60_000);

  const response = await client().create({
    body: {
      transaction_amount: Number((amountCents / 100).toFixed(2)),
      description,
      payment_method_id: 'pix',
      external_reference: externalReference,
      date_of_expiration: expiration.toISOString(),
      payer: {
        email: payerEmail || 'comprador@example.com',
        first_name: 'Cliente',
      },
    },
    requestOptions: { idempotencyKey: externalReference },
  });

  const tx = response.point_of_interaction?.transaction_data ?? {};

  return {
    providerRefId: String(response.id),
    status: response.status,
    copyPaste: tx.qr_code ?? null,
    qrBase64: tx.qr_code_base64 ?? null,
    ticketUrl: tx.ticket_url ?? null,
    expiresAt: expiration,
  };
}

export async function getPayment(paymentId) {
  const response = await client().get({ id: String(paymentId) });
  return {
    id: String(response.id),
    status: response.status, // approved | pending | rejected | cancelled
    externalReference: response.external_reference ?? null,
    amountCents: Math.round((response.transaction_amount ?? 0) * 100),
  };
}
