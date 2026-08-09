const BASE = (import.meta.env.VITE_API_URL || 'http://localhost:3333').replace(/\/$/, '');
const TOKEN_KEY = 'panel_token';

export const tokenStore = {
  get: () => localStorage.getItem(TOKEN_KEY),
  set: (token) => localStorage.setItem(TOKEN_KEY, token),
  clear: () => localStorage.removeItem(TOKEN_KEY),
};

/** Erro da API ja com o `code` estavel que o backend devolve. */
export class ApiError extends Error {
  constructor(message, { code, status, issues } = {}) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.status = status;
    this.issues = issues;
  }
}

/** Disparado quando o token vence: o AuthContext escuta e faz logout. */
const onUnauthorized = new Set();
export function subscribeUnauthorized(fn) {
  onUnauthorized.add(fn);
  return () => onUnauthorized.delete(fn);
}

function buildUrl(path, query) {
  const url = new URL(`${BASE}${path}`);
  if (query) {
    for (const [key, value] of Object.entries(query)) {
      if (value === undefined || value === null || value === '') continue;
      url.searchParams.set(key, String(value));
    }
  }
  return url.toString();
}

async function request(method, path, { body, query } = {}) {
  const token = tokenStore.get();

  let response;
  try {
    response = await fetch(buildUrl(path, query), {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError('Nao foi possivel falar com a API. Ela esta rodando?', { code: 'NETWORK' });
  }

  const text = await response.text();
  const data = text ? JSON.parse(text) : {};

  if (!response.ok) {
    // Token expirado ou revogado: derruba a sessao do painel.
    if (response.status === 401) onUnauthorized.forEach((fn) => fn());

    throw new ApiError(data.message || `Erro ${response.status}`, {
      code: data.code,
      status: response.status,
      issues: data.issues,
    });
  }

  return data;
}

const http = {
  get: (path, query) => request('GET', path, { query }),
  post: (path, body) => request('POST', path, { body }),
  patch: (path, body) => request('PATCH', path, { body }),
  del: (path) => request('DELETE', path),
};

export const api = {
  auth: {
    login: (username, password) => http.post('/api/auth/login', { username, password }),
    me: () => http.get('/api/auth/me'),
    changePassword: (currentPassword, newPassword) =>
      http.patch('/api/auth/password', { currentPassword, newPassword }),
  },

  dashboard: () => http.get('/api/dashboard'),

  users: {
    list: (query) => http.get('/api/users', query),
    get: (id) => http.get(`/api/users/${id}`),
    create: (body) => http.post('/api/users', body),
    update: (id, body) => http.patch(`/api/users/${id}`, body),
    remove: (id) => http.del(`/api/users/${id}`),
    renew: (id, body) => http.post(`/api/users/${id}/renew`, body),
    sessions: (id) => http.get(`/api/users/${id}/sessions`),
    killSessions: (id) => http.del(`/api/users/${id}/sessions`),
  },

  credits: {
    balance: () => http.get('/api/credits/balance'),
    history: (query) => http.get('/api/credits/history', query),
    transfer: (body) => http.post('/api/credits/transfer', body),
    withdraw: (body) => http.post('/api/credits/withdraw', body),
  },

  plans: {
    list: () => http.get('/api/plans'),
    create: (body) => http.post('/api/plans', body),
    update: (id, body) => http.patch(`/api/plans/${id}`, body),
    remove: (id) => http.del(`/api/plans/${id}`),
  },

  operators: {
    list: () => http.get('/api/payloads/operators'),
    create: (body) => http.post('/api/payloads/operators', body),
    update: (id, body) => http.patch(`/api/payloads/operators/${id}`, body),
    remove: (id) => http.del(`/api/payloads/operators/${id}`),
  },

  payloads: {
    list: (query) => http.get('/api/payloads', query),
    create: (body) => http.post('/api/payloads', body),
    update: (id, body) => http.patch(`/api/payloads/${id}`, body),
    remove: (id) => http.del(`/api/payloads/${id}`),
    duplicate: (id, operatorId) => http.post(`/api/payloads/${id}/duplicate`, { operatorId }),
  },

  servers: {
    list: () => http.get('/api/servers'),
    create: (body) => http.post('/api/servers', body),
    update: (id, body) => http.patch(`/api/servers/${id}`, body),
    remove: (id) => http.del(`/api/servers/${id}`),

    // Agente que roda na VPS criando os usuarios do Linux
    generateAgentToken: (id) => http.post(`/api/servers/${id}/agent-token`),
    revokeAgentToken: (id) => http.del(`/api/servers/${id}/agent-token`),
    retryFailedTasks: (id) => http.post(`/api/servers/${id}/retry-failed`),
  },

  orders: {
    list: (query) => http.get('/api/payments/orders', query),
  },
};
