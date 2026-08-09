import { ZodError } from 'zod';
import { Prisma } from '@prisma/client';
import { AppError } from '../utils/errors.js';
import { env } from '../config/env.js';

export function notFoundHandler(req, res) {
  res.status(404).json({ error: true, code: 'ROUTE_NOT_FOUND', message: `Rota ${req.method} ${req.path} nao existe` });
}

// eslint-disable-next-line no-unused-vars
export function errorHandler(err, _req, res, _next) {
  if (err instanceof ZodError) {
    return res.status(422).json({
      error: true,
      code: 'VALIDATION_ERROR',
      message: 'Dados invalidos',
      issues: err.issues.map((i) => ({ field: i.path.join('.'), message: i.message })),
    });
  }

  if (err instanceof AppError) {
    return res.status(err.status).json({ error: true, code: err.code, message: err.message });
  }

  if (err instanceof Prisma.PrismaClientKnownRequestError) {
    if (err.code === 'P2002') {
      const field = Array.isArray(err.meta?.target) ? err.meta.target.join(', ') : 'campo';
      return res.status(409).json({ error: true, code: 'DUPLICATED', message: `Ja existe um registro com este ${field}` });
    }
    if (err.code === 'P2025') {
      return res.status(404).json({ error: true, code: 'NOT_FOUND', message: 'Registro nao encontrado' });
    }
  }

  console.error('[error]', err);
  return res.status(500).json({
    error: true,
    code: 'INTERNAL_ERROR',
    message: 'Erro interno no servidor',
    ...(env.NODE_ENV === 'development' ? { detail: err.message, stack: err.stack } : {}),
  });
}
