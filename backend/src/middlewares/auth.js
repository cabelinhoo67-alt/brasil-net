import { prisma } from '../lib/prisma.js';
import { verifyToken } from '../utils/security.js';
import { forbidden, unauthorized } from '../utils/errors.js';
import { env } from '../config/env.js';

function extractToken(req) {
  const header = req.headers.authorization || '';
  const [type, token] = header.split(' ');
  if (type !== 'Bearer' || !token) return null;
  return token;
}

/**
 * @param {'panel'|'app'} scope escopo esperado do token
 */
export function authenticate(scope = 'panel') {
  return async (req, _res, next) => {
    try {
      const token = extractToken(req);
      if (!token) throw unauthorized('Token ausente', 'NO_TOKEN');

      let payload;
      try {
        payload = verifyToken(token);
      } catch {
        throw unauthorized('Token invalido ou expirado', 'INVALID_TOKEN');
      }

      if (payload.scope !== scope) {
        throw forbidden('Token nao pertence a este escopo', 'WRONG_SCOPE');
      }

      const user = await prisma.user.findUnique({ where: { id: payload.sub } });
      if (!user) throw unauthorized('Usuario inexistente', 'USER_GONE');
      if (!user.isActive || user.isBlocked) {
        throw forbidden('Usuario desativado ou bloqueado', 'USER_DISABLED');
      }

      req.user = user;
      req.tokenPayload = payload;
      next();
    } catch (err) {
      next(err);
    }
  };
}

/** Restringe a rota a determinados papeis. */
export function requireRole(...roles) {
  return (req, _res, next) => {
    if (!req.user) return next(unauthorized());
    if (!roles.includes(req.user.role)) {
      return next(forbidden('Seu nivel de acesso nao permite esta operacao', 'ROLE_DENIED'));
    }
    next();
  };
}

/** Autenticacao maquina-a-maquina (bot do WhatsApp -> backend). */
export function requireInternalKey(req, _res, next) {
  const key = req.headers['x-internal-key'];
  if (key !== env.INTERNAL_API_KEY) {
    return next(forbidden('Chave interna invalida', 'BAD_INTERNAL_KEY'));
  }
  next();
}
