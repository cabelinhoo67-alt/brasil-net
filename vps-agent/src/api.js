import { config } from './config.js';

class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

async function request(method, path, body) {
  let response;

  try {
    response = await fetch(`${config.apiUrl}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        'x-agent-token': config.agentToken,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
  } catch (error) {
    throw new ApiError(`backend inacessivel: ${error.message}`, 0);
  }

  const text = await response.text();
  const data = text ? JSON.parse(text) : {};

  if (!response.ok) {
    throw new ApiError(data.message || `HTTP ${response.status}`, response.status);
  }

  return data;
}

export const api = {
  heartbeat: (userCount) =>
    request('POST', '/api/agent/heartbeat', { version: config.version, userCount }),

  fetchTasks: () => request('GET', `/api/agent/tasks?limit=${config.batchSize}`),

  reportResult: (taskId, ok, error) =>
    request('POST', `/api/agent/tasks/${taskId}/result`, { ok, error }),

  fetchDesiredState: () => request('GET', '/api/agent/sync'),
};

export { ApiError };
