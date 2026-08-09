import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { api } from '../lib/api';
import { useApi, useDebounced } from '../hooks/useApi';
import { useToast } from '../context/ToastContext';
import { clientStatus, date } from '../lib/format';
import { ROLE_SHORT } from '../lib/roles';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import Badge from '../components/ui/Badge';
import DataTable from '../components/ui/DataTable';
import Pagination from '../components/ui/Pagination';
import { EmptyState, ErrorState, Loading } from '../components/ui/Feedback';
import { Input, Select } from '../components/ui/Field';
import UserFormModal from '../components/UserFormModal';
import UserDetailModal from '../components/UserDetailModal';
import Modal from '../components/ui/Modal';

/** Mostrado uma unica vez logo apos criar o acesso — a senha nao volta depois. */
function CredentialsModal({ data, onClose }) {
  const toast = useToast();
  if (!data) return null;

  const text = `Usuario: ${data.user.username}\nSenha: ${data.password}`;

  return (
    <Modal
      open
      onClose={onClose}
      size="sm"
      title="Acesso criado"
      subtitle="Anote agora: a senha nao pode ser consultada depois."
      footer={
        <div className="flex gap-2">
          <Button
            variant="ghost"
            className="flex-1"
            onClick={() => {
              navigator.clipboard.writeText(text).then(
                () => toast.success('Copiado.'),
                () => toast.error('Nao consegui copiar.'),
              );
            }}
          >
            Copiar
          </Button>
          <Button className="flex-1" onClick={onClose}>
            Entendi
          </Button>
        </div>
      }
    >
      <div className="space-y-2 rounded-xl border border-ember-600/30 bg-void-800 p-4 font-mono text-sm">
        <p>
          <span className="text-ash-400">usuario: </span>
          <span className="text-white">{data.user.username}</span>
        </p>
        <p>
          <span className="text-ash-400">senha:   </span>
          <span className="text-ember-300">{data.password}</span>
        </p>
      </div>
    </Modal>
  );
}

/**
 * Listagem reaproveitada por Clientes e Revendedores.
 * O backend ja limita o resultado a rede do usuario logado, entao aqui
 * so filtramos por papel e situacao.
 */
export default function UsersPage({ role, title, description }) {
  const [params, setParams] = useSearchParams();

  const [page, setPage] = useState(1);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState(params.get('status') ?? '');
  const debouncedSearch = useDebounced(search);

  const [creating, setCreating] = useState(false);
  const [detailId, setDetailId] = useState(null);
  const [credentials, setCredentials] = useState(null);

  const isClientList = role === 'CLIENT';

  const { data, loading, error, reload } = useApi(
    () =>
      api.users.list({
        page,
        perPage: 20,
        role: isClientList ? 'CLIENT' : undefined,
        search: debouncedSearch,
        status: isClientList ? status : undefined,
      }),
    [page, debouncedSearch, status, role],
  );

  function updateStatus(value) {
    setStatus(value);
    setPage(1);
    const next = new URLSearchParams(params);
    if (value) next.set('status', value);
    else next.delete('status');
    setParams(next, { replace: true });
  }

  const columns = [
    {
      key: 'username',
      header: 'Usuario',
      render: (row) => (
        <div className="min-w-0">
          <p className="truncate font-semibold text-white">{row.username}</p>
          <p className="truncate text-[11px] text-ash-400">
            {row.fullName || row.whatsapp || ROLE_SHORT[row.role]}
          </p>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Situacao',
      render: (row) => {
        const s = clientStatus(row);
        return <Badge tone={s.tone}>{s.label}</Badge>;
      },
    },
    isClientList
      ? {
          key: 'validity',
          header: 'Validade',
          render: (row) => (
            <span className="text-sm text-zinc-300">
              {date(row.expiresAt)}
              <span className="ml-1 text-[11px] text-ash-400">({row.daysLeft ?? 0}d)</span>
            </span>
          ),
        }
      : {
          key: 'credits',
          header: 'Creditos',
          render: (row) => <span className="font-bold text-ember-300">{row.credits}</span>,
        },
    {
      key: 'parent',
      header: 'Criado por',
      hideOnMobile: true,
      render: (row) => (
        <span className="text-xs text-ash-400">{row.parent?.username ?? '--'}</span>
      ),
    },
    {
      key: 'action',
      header: '',
      className: 'w-20 text-right',
      render: () => <span className="text-xs font-semibold text-ember-400">Abrir</span>,
    },
  ];

  return (
    <>
      <PageHeader
        title={title}
        description={description}
        actions={
          <Button onClick={() => setCreating(true)}>
            + Novo {isClientList ? 'cliente' : 'revendedor'}
          </Button>
        }
      />

      <div className="card overflow-hidden">
        <div className="flex flex-col gap-3 border-b border-white/[0.06] p-4 sm:flex-row">
          <div className="flex-1">
            <Input
              placeholder="Buscar por usuario, nome ou WhatsApp..."
              value={search}
              onChange={(e) => {
                setSearch(e.target.value);
                setPage(1);
              }}
            />
          </div>

          {isClientList && (
            <div className="sm:w-48">
              <Select value={status} onChange={(e) => updateStatus(e.target.value)}>
                <option value="">Todas as situacoes</option>
                <option value="active">Somente ativos</option>
                <option value="expired">Somente vencidos</option>
              </Select>
            </div>
          )}
        </div>

        {loading ? (
          <Loading />
        ) : error ? (
          <ErrorState error={error} onRetry={reload} />
        ) : (
          <>
            <DataTable
              columns={columns}
              rows={data.items}
              onRowClick={(row) => setDetailId(row.id)}
              empty={
                <EmptyState
                  icon="◇"
                  title={search || status ? 'Nada encontrado' : 'Nenhum cadastro ainda'}
                  description={
                    search || status
                      ? 'Ajuste a busca ou o filtro de situacao.'
                      : `Crie o primeiro ${isClientList ? 'cliente' : 'revendedor'} no botao acima.`
                  }
                />
              }
            />
            <Pagination meta={data.meta} onChange={setPage} />
          </>
        )}
      </div>

      <UserFormModal
        open={creating}
        onClose={() => setCreating(false)}
        defaultRole={role}
        onCreated={(user, password) => {
          setCredentials({ user, password });
          reload();
        }}
      />

      <UserDetailModal
        open={Boolean(detailId)}
        userId={detailId}
        onClose={() => setDetailId(null)}
        onChanged={reload}
      />

      <CredentialsModal data={credentials} onClose={() => setCredentials(null)} />
    </>
  );
}
