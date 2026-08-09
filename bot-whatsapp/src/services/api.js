import { config } from '../config.js';

async function request(path, options = {}) {
  const response = await fetch(`${config.apiUrl}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      'x-internal-key': config.internalKey,
      ...(options.headers || {}),
    },
    signal: AbortSignal.timeout(20_000),
  });

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    const message = data?.message || `Erro ${response.status} em ${path}`;
    const error = new Error(message);
    error.code = data?.code;
    error.status = response.status;
    throw error;
  }

  return data;
}

export const api = {
  listPlans: () => request('/api/payments/internal/plans'),

  createPix: ({ whatsapp, planId, ownerId }) =>
    request('/api/payments/internal/pix', {
      method: 'POST',
      body: JSON.stringify({ whatsapp, planId, ownerId }),
    }),

  getOrder: (orderId) => request(`/api/payments/internal/orders/${orderId}`),
};
