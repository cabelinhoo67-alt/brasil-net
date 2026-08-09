/**
 * Envolve handlers async para que rejeicoes cheguem ao middleware de erro
 * sem precisar de try/catch em cada controller.
 */
export const asyncHandler = (fn) => (req, res, next) =>
  Promise.resolve(fn(req, res, next)).catch(next);

export function paginate(query) {
  const page = Math.max(1, Number(query.page) || 1);
  const perPage = Math.min(100, Math.max(1, Number(query.perPage) || 20));
  return { page, perPage, skip: (page - 1) * perPage, take: perPage };
}

export function pageResult(items, total, { page, perPage }) {
  return {
    items,
    meta: {
      page,
      perPage,
      total,
      totalPages: Math.max(1, Math.ceil(total / perPage)),
    },
  };
}
