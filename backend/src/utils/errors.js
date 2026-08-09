export class AppError extends Error {
  /**
   * @param {string} message mensagem exibida ao cliente da API
   * @param {number} status  codigo HTTP
   * @param {string} [code]  identificador estavel para o app tratar o erro
   */
  constructor(message, status = 400, code = 'BAD_REQUEST') {
    super(message);
    this.name = 'AppError';
    this.status = status;
    this.code = code;
  }
}

export const badRequest = (m, code = 'BAD_REQUEST') => new AppError(m, 400, code);
export const unauthorized = (m = 'Nao autenticado', code = 'UNAUTHORIZED') => new AppError(m, 401, code);
export const forbidden = (m = 'Sem permissao', code = 'FORBIDDEN') => new AppError(m, 403, code);
export const notFound = (m = 'Nao encontrado', code = 'NOT_FOUND') => new AppError(m, 404, code);
export const conflict = (m, code = 'CONFLICT') => new AppError(m, 409, code);
