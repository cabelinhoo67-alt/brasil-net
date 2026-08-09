import { prisma } from '../lib/prisma.js';
import { forbidden } from './errors.js';

/** Papeis que cada role pode criar (regra da cascata). */
export const CREATABLE_ROLES = {
  ADMIN: ['MASTER', 'RESELLER', 'CLIENT'],
  MASTER: ['RESELLER', 'CLIENT'],
  RESELLER: ['CLIENT'],
  CLIENT: [],
};

export const RESELLER_ROLES = ['ADMIN', 'MASTER', 'RESELLER'];

export function assertCanCreate(actorRole, targetRole) {
  if (!CREATABLE_ROLES[actorRole]?.includes(targetRole)) {
    throw forbidden(`Um ${actorRole} nao pode criar um ${targetRole}`, 'ROLE_NOT_ALLOWED');
  }
}

/**
 * Devolve os ids de toda a arvore abaixo de `rootId` (incluindo ele mesmo).
 * Usa CTE recursiva: uma unica query independente da profundidade da cascata.
 */
export async function descendantIds(rootId) {
  const rows = await prisma.$queryRaw`
    WITH RECURSIVE tree AS (
      SELECT id FROM users WHERE id = ${rootId}
      UNION ALL
      SELECT u.id FROM users u INNER JOIN tree t ON u."parentId" = t.id
    )
    SELECT id FROM tree
  `;
  return rows.map((r) => r.id);
}

/**
 * Garante que `actor` pode enxergar/alterar `targetId`.
 * ADMIN enxerga tudo; os demais so enxergam a propria descendencia.
 */
export async function assertOwnership(actor, targetId) {
  if (actor.role === 'ADMIN') return;
  if (actor.id === targetId) return;

  const ids = await descendantIds(actor.id);
  if (!ids.includes(targetId)) {
    throw forbidden('Este usuario nao pertence a sua rede', 'NOT_IN_NETWORK');
  }
}

/** Escopo de listagem: ADMIN ve tudo, os outros veem a propria arvore. */
export async function scopeFilter(actor) {
  if (actor.role === 'ADMIN') return {};
  const ids = await descendantIds(actor.id);
  return { id: { in: ids.filter((id) => id !== actor.id) } };
}
