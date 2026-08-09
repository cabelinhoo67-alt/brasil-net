import { useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { ROLE_LABEL, can, isSimpleView } from '../lib/roles';

/**
 * Menu montado a partir do papel do usuario.
 *
 * O revendedor enxerga so o essencial (painel, clientes, creditos): a
 * infraestrutura — servidores, operadoras, payloads, planos — nao e assunto
 * dele e o backend recusaria essas rotas de qualquer forma.
 */
function navigationFor(role) {
  const items = [
    { to: '/', label: 'Painel', icon: '◈', end: true },
    { to: '/clientes', label: 'Clientes', icon: '◇' },
  ];

  if (can.manageResellers(role)) {
    items.push({ to: '/revendedores', label: 'Revendedores', icon: '◆' });
  }

  items.push({ to: '/creditos', label: 'Creditos', icon: '❖' });

  if (can.manageInfra(role)) {
    items.push(
      { divider: 'Infraestrutura' },
      { to: '/operadoras', label: 'Operadoras', icon: '▣' },
      { to: '/payloads', label: 'Payloads', icon: '▤' },
      { to: '/servidores', label: 'Servidores', icon: '▥' },
    );
  }

  if (can.managePlans(role)) items.push({ to: '/planos', label: 'Planos', icon: '▦' });
  if (can.managePlans(role)) items.push({ to: '/versao-app', label: 'Versao do app', icon: '▲' });
  if (can.viewOrders(role)) items.push({ to: '/vendas', label: 'Vendas', icon: '▧' });

  items.push({ divider: 'Conta' }, { to: '/conta', label: 'Minha conta', icon: '◉' });

  return items;
}

function Brand() {
  return (
    <div className="flex items-center gap-3 px-5 py-5">
      <div className="relative grid size-10 place-items-center rounded-xl border border-ember-500/40 bg-gradient-to-b from-ember-600/25 to-transparent">
        <span className="text-lg leading-none">🔥</span>
        <span className="absolute inset-0 rounded-xl shadow-[0_0_22px_-6px_rgba(230,33,43,0.85)]" />
      </div>
      <div className="min-w-0">
        <p className="truncate text-sm font-black tracking-widest text-white">AMATERASU</p>
        <p className="truncate text-[10px] uppercase tracking-[0.2em] text-ember-500">
          Painel de revenda
        </p>
      </div>
    </div>
  );
}

function SidebarContent({ onNavigate }) {
  const { user, logout } = useAuth();
  const items = navigationFor(user.role);

  return (
    <div className="flex h-full flex-col">
      <Brand />
      <div className="flame-divider mx-5" />

      <nav className="flex-1 space-y-1 overflow-y-auto px-3 py-4">
        {items.map((item, index) =>
          item.divider ? (
            <p
              key={`d-${index}`}
              className="px-3 pb-1 pt-4 text-[10px] font-semibold uppercase tracking-[0.18em] text-ash-400/70"
            >
              {item.divider}
            </p>
          ) : (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              onClick={onNavigate}
              className={({ isActive }) =>
                `group flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition-all ${
                  isActive
                    ? 'border border-ember-500/35 bg-gradient-to-r from-ember-600/20 to-transparent font-semibold text-white shadow-[inset_2px_0_0_0_#e6212b]'
                    : 'border border-transparent text-ash-300 hover:bg-white/[0.04] hover:text-white'
                }`
              }
            >
              <span className="w-4 text-center text-xs opacity-80">{item.icon}</span>
              {item.label}
            </NavLink>
          ),
        )}
      </nav>

      <div className="border-t border-white/[0.06] p-3">
        <div className="rounded-xl bg-void-800/70 px-3 py-2.5">
          <p className="truncate text-sm font-semibold text-white">{user.username}</p>
          <p className="truncate text-[11px] text-ember-400">{ROLE_LABEL[user.role]}</p>
        </div>
        <button
          onClick={logout}
          className="mt-2 w-full rounded-xl px-3 py-2 text-left text-xs text-ash-400 transition-colors hover:bg-bad-500/10 hover:text-red-300"
        >
          Sair da conta
        </button>
      </div>
    </div>
  );
}

/** Saldo no topo: e a informacao que o revendedor mais consulta. */
function CreditPill() {
  const { user } = useAuth();

  if (can.hasUnlimitedCredits(user.role)) {
    return (
      <div className="flex items-center gap-2 rounded-xl border border-ember-500/30 bg-ember-600/10 px-3 py-1.5">
        <span className="text-xs">∞</span>
        <span className="text-xs font-semibold text-ember-300">Credito ilimitado</span>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2 rounded-xl border border-ember-500/30 bg-ember-600/10 px-3 py-1.5">
      <span className="text-[10px] uppercase tracking-widest text-ash-400">Saldo</span>
      <span className="text-sm font-black text-ember-300">{user.credits ?? 0}</span>
    </div>
  );
}

export default function Layout() {
  const [open, setOpen] = useState(false);
  const { user } = useAuth();
  const location = useLocation();

  return (
    <div className="flex min-h-dvh">
      {/* Sidebar fixa no desktop */}
      <aside className="hidden w-64 shrink-0 border-r border-white/[0.06] bg-void-900/80 backdrop-blur lg:block">
        <div className="sticky top-0 h-dvh">
          <SidebarContent />
        </div>
      </aside>

      {/* Gaveta no celular */}
      {open && (
        <div className="fixed inset-0 z-50 lg:hidden">
          <div className="absolute inset-0 bg-black/80" onClick={() => setOpen(false)} />
          <aside className="relative h-full w-72 border-r border-ember-600/20 bg-void-900">
            <SidebarContent onNavigate={() => setOpen(false)} />
          </aside>
        </div>
      )}

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-30 flex items-center gap-3 border-b border-white/[0.06] bg-void-950/80 px-4 py-3 backdrop-blur-md">
          <button
            onClick={() => setOpen(true)}
            aria-label="Abrir menu"
            className="rounded-lg border border-white/10 px-2.5 py-1.5 text-sm lg:hidden"
          >
            ☰
          </button>

          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-semibold text-white">
              {isSimpleView(user.role) ? 'Minha revenda' : 'Gestao do sistema'}
            </p>
            <p className="truncate text-[11px] text-ash-400">{location.pathname}</p>
          </div>

          <CreditPill />
        </header>

        <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-6 sm:px-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
