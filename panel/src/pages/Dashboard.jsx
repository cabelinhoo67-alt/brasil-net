import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { useAuth } from '../context/AuthContext';
import { ROLE_SHORT, can, isSimpleView } from '../lib/roles';
import { clientStatus, date } from '../lib/format';
import PageHeader from '../components/PageHeader';
import Badge, { LiveDot } from '../components/ui/Badge';
import { ErrorState, Loading } from '../components/ui/Feedback';

function Stat({ label, value, hint, tone = 'neutral', to }) {
  const accent = {
    ember: 'border-ember-500/30 shadow-[0_0_24px_-12px_rgba(230,33,43,0.9)]',
    ok: 'border-ok-500/25',
    warn: 'border-warn-500/25',
    neutral: 'border-white/[0.06]',
  }[tone];

  const body = (
    <div className={`h-full rounded-2xl border bg-void-850 p-4 transition-colors ${accent} ${to ? 'hover:border-ember-500/50' : ''}`}>
      <p className="text-[10px] uppercase tracking-[0.18em] text-ash-400">{label}</p>
      <p className="mt-2 text-3xl font-black leading-none text-white">{value}</p>
      {hint && <p className="mt-2 text-[11px] text-ash-400">{hint}</p>}
    </div>
  );

  return to ? <Link to={to}>{body}</Link> : body;
}

/** Visao do revendedor: saldo em destaque e a propria carteira de clientes. */
function ResellerDashboard({ stats, user }) {
  const recent = useApi(() => api.users.list({ role: 'CLIENT', perPage: 6 }), []);

  return (
    <>
      <PageHeader
        title={`Ola, ${user.username}`}
        description="Seu saldo e a situacao dos seus clientes."
      />

      <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="card-ember p-5 sm:col-span-2">
          <p className="text-[10px] uppercase tracking-[0.18em] text-ash-400">
            Creditos disponiveis
          </p>
          <p className="mt-1 text-5xl font-black leading-none ember-text">{stats.credits ?? 0}</p>
          <p className="mt-3 text-[11px] text-ash-400">
            Cada credito vale conforme o plano. Sem saldo, fale com seu superior.
          </p>
        </div>

        <Stat label="Meus clientes" value={stats.clients} tone="neutral" to="/clientes" />
        <Stat
          label="Online agora"
          value={stats.onlineNow}
          hint="conectados no aplicativo"
          tone="ok"
        />
      </div>

      <div className="mb-6 grid gap-3 sm:grid-cols-2">
        <Stat label="Ativos" value={stats.activeClients} tone="ok" to="/clientes?status=active" />
        <Stat
          label="Vencidos"
          value={stats.expiredClients}
          hint="renove para reativar"
          tone={stats.expiredClients > 0 ? 'warn' : 'neutral'}
          to="/clientes?status=expired"
        />
      </div>

      <section className="card overflow-hidden">
        <header className="flex items-center justify-between border-b border-white/[0.06] px-4 py-3">
          <h2 className="text-sm font-semibold text-white">Clientes recentes</h2>
          <Link to="/clientes" className="text-xs font-semibold text-ember-400 hover:text-ember-300">
            Ver todos
          </Link>
        </header>

        {recent.loading ? (
          <Loading />
        ) : recent.error ? (
          <ErrorState error={recent.error} onRetry={recent.reload} />
        ) : recent.data.items.length === 0 ? (
          <p className="px-4 py-10 text-center text-xs text-ash-400">
            Voce ainda nao criou nenhum cliente.
          </p>
        ) : (
          <ul className="divide-y divide-white/[0.04]">
            {recent.data.items.map((client) => {
              const status = clientStatus(client);
              return (
                <li key={client.id} className="flex items-center gap-3 px-4 py-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-white">{client.username}</p>
                    <p className="truncate text-[11px] text-ash-400">
                      vence em {date(client.expiresAt)}
                    </p>
                  </div>
                  <Badge tone={status.tone}>{status.label}</Badge>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </>
  );
}

/** Visao do admin/master: numeros globais da rede inteira. */
function AdminDashboard({ stats, user }) {
  return (
    <>
      <PageHeader
        title="Painel geral"
        description="Numeros consolidados de toda a sua rede."
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Clientes" value={stats.clients} tone="ember" to="/clientes" />
        <Stat label="Revendedores" value={stats.resellers} to="/revendedores" />
        <Stat
          label="Online agora"
          value={stats.onlineNow}
          hint="sessoes ativas no app"
          tone="ok"
        />
        <Stat
          label="Creditos"
          value={can.hasUnlimitedCredits(user.role) ? '∞' : (stats.credits ?? 0)}
          hint={can.hasUnlimitedCredits(user.role) ? 'admin emite credito' : 'saldo disponivel'}
          tone="ember"
          to="/creditos"
        />
      </div>

      <div className="mb-6 grid gap-3 sm:grid-cols-2">
        <Stat
          label="Clientes ativos"
          value={stats.activeClients}
          hint="dentro da validade e desbloqueados"
          tone="ok"
          to="/clientes?status=active"
        />
        <Stat
          label="Clientes vencidos"
          value={stats.expiredClients}
          hint="oportunidade de renovacao"
          tone={stats.expiredClients > 0 ? 'warn' : 'neutral'}
          to="/clientes?status=expired"
        />
      </div>

      <div className="grid gap-3 lg:grid-cols-2">
        <RecentUsers />
        <RecentOrders enabled={can.viewOrders(user.role)} />
      </div>
    </>
  );
}

function RecentUsers() {
  const { data, loading, error, reload } = useApi(() => api.users.list({ perPage: 6 }), []);

  return (
    <section className="card overflow-hidden">
      <header className="flex items-center justify-between border-b border-white/[0.06] px-4 py-3">
        <h2 className="text-sm font-semibold text-white">Ultimos cadastros</h2>
        <Link to="/clientes" className="text-xs font-semibold text-ember-400 hover:text-ember-300">
          Ver todos
        </Link>
      </header>

      {loading ? (
        <Loading />
      ) : error ? (
        <ErrorState error={error} onRetry={reload} />
      ) : (
        <ul className="divide-y divide-white/[0.04]">
          {data.items.map((item) => (
            <li key={item.id} className="flex items-center gap-3 px-4 py-3">
              <LiveDot active={!item.expired && !item.isBlocked} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm text-white">{item.username}</p>
                <p className="truncate text-[11px] text-ash-400">
                  {ROLE_SHORT[item.role]} · criado por {item.parent?.username ?? '--'}
                </p>
              </div>
              <span className="shrink-0 text-[11px] text-ash-400">{date(item.createdAt)}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function RecentOrders({ enabled }) {
  const { data, loading } = useApi(
    () => (enabled ? api.orders.list({ perPage: 6 }) : Promise.resolve({ items: [] })),
    [enabled],
  );

  if (!enabled) return null;

  const TONE = { PAID: 'ok', PENDING: 'warn', EXPIRED: 'neutral', CANCELED: 'bad' };

  return (
    <section className="card overflow-hidden">
      <header className="flex items-center justify-between border-b border-white/[0.06] px-4 py-3">
        <h2 className="text-sm font-semibold text-white">Vendas automaticas</h2>
        <Link to="/vendas" className="text-xs font-semibold text-ember-400 hover:text-ember-300">
          Ver todas
        </Link>
      </header>

      {loading ? (
        <Loading />
      ) : data.items.length === 0 ? (
        <p className="px-4 py-10 text-center text-xs text-ash-400">
          Nenhuma venda pelo WhatsApp ainda.
        </p>
      ) : (
        <ul className="divide-y divide-white/[0.04]">
          {data.items.map((order) => (
            <li key={order.id} className="flex items-center gap-3 px-4 py-3">
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm text-white">{order.plan.name}</p>
                <p className="truncate text-[11px] text-ash-400">
                  {order.whatsapp.replace('@s.whatsapp.net', '')}
                </p>
              </div>
              <Badge tone={TONE[order.status] ?? 'neutral'}>{order.status}</Badge>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export default function Dashboard() {
  const { user } = useAuth();
  const { data, loading, error, reload } = useApi(() => api.dashboard(), []);

  if (loading) return <Loading label="Carregando o painel..." />;
  if (error) return <ErrorState error={error} onRetry={reload} />;

  return isSimpleView(user.role) ? (
    <ResellerDashboard stats={data} user={user} />
  ) : (
    <AdminDashboard stats={data} user={user} />
  );
}
