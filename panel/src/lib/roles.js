export const ROLE_LABEL = {
  ADMIN: 'Administrador Geral',
  MASTER: 'Master Revendedor',
  RESELLER: 'Revendedor',
  CLIENT: 'Cliente Final',
};

export const ROLE_SHORT = {
  ADMIN: 'Admin',
  MASTER: 'Master',
  RESELLER: 'Revenda',
  CLIENT: 'Cliente',
};

/** Papeis que cada nivel pode criar — espelha CREATABLE_ROLES do backend. */
export const CREATABLE_ROLES = {
  ADMIN: ['MASTER', 'RESELLER', 'CLIENT'],
  MASTER: ['RESELLER', 'CLIENT'],
  RESELLER: ['CLIENT'],
  CLIENT: [],
};

/**
 * Permissoes da interface.
 *
 * Isto e conveniencia de UX, nao seguranca: quem manda e o backend, que
 * recusa a operacao de qualquer jeito. Aqui so evitamos mostrar botao que
 * o usuario levaria 403 ao clicar.
 */
export const can = {
  manageResellers: (role) => role === 'ADMIN' || role === 'MASTER',
  manageInfra: (role) => role === 'ADMIN' || role === 'MASTER', // servidores, operadoras, payloads
  managePlans: (role) => role === 'ADMIN',
  viewOrders: (role) => role === 'ADMIN' || role === 'MASTER',
  issueCredits: (role) => role === 'ADMIN', // ADMIN emite credito novo em vez de transferir
  hasUnlimitedCredits: (role) => role === 'ADMIN',
};

/** Revendedor tem uma visao enxuta: so saldo e a propria carteira de clientes. */
export const isSimpleView = (role) => role === 'RESELLER';
