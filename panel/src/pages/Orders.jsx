import { useState } from 'react';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { brl, dateTime } from '../lib/format';
import PageHeader from '../components/PageHeader';
import Badge from '../components/ui/Badge';
import DataTable from '../components/ui/DataTable';
import Pagination from '../components/ui/Pagination';
import { Select } from '../components/ui/Field';
import { EmptyState, ErrorState, Loading } from '../components/ui/Feedback';

const STATUS = {
  PAID: { label: 'Pago', tone: 'ok' },
  PENDING: { label: 'Aguardando', tone: 'warn' },
  EXPIRED: { label: 'Expirado', tone: 'neutral' },
  CANCELED: { label: 'Cancelado', tone: 'bad' },
};

export default function Orders() {
  const [page, setPage] = useState(1);
  const [status, setStatus] = useState('');

  const { data, loading, error, reload } = useApi(
    () => api.orders.list({ page, perPage: 20, status: status || undefined }),
    [page, status],
  );

  const paidCents = (data?.items ?? [])
    .filter((order) => order.status === 'PAID')
    .reduce((sum, order) => sum + order.amountCents, 0);

  const columns = [
    {
      key: 'whatsapp',
      header: 'Comprador',
      render: (row) => (
        <div className="min-w-0">
          <p className="truncate font-medium text-white">
            {row.whatsapp.replace('@s.whatsapp.net', '')}
          </p>
          <p className="truncate text-[11px] text-ash-400">{row.plan.name}</p>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Situacao',
      render: (row) => (
        <Badge tone={STATUS[row.status]?.tone ?? 'neutral'}>
          {STATUS[row.status]?.label ?? row.status}
        </Badge>
      ),
    },
    {
      key: 'amount',
      header: 'Valor',
      render: (row) => <span className="font-bold text-white">{brl(row.amountCents)}</span>,
    },
    {
      key: 'user',
      header: 'Acesso gerado',
      render: (row) =>
        row.createdUser ? (
          <span className="font-mono text-xs text-ember-300">{row.createdUser.username}</span>
        ) : (
          <span className="text-xs text-ash-400">--</span>
        ),
    },
    {
      key: 'date',
      header: 'Criado em',
      hideOnMobile: true,
      render: (row) => <span className="text-xs text-ash-400">{dateTime(row.createdAt)}</span>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Vendas automaticas"
        description="Pedidos gerados pelo bot do WhatsApp com pagamento via Pix."
      />

      <div className="card overflow-hidden">
        <div className="flex flex-col gap-3 border-b border-white/[0.06] p-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="sm:w-56">
            <Select
              value={status}
              onChange={(e) => {
                setStatus(e.target.value);
                setPage(1);
              }}
            >
              <option value="">Todas as situacoes</option>
              <option value="PAID">Pagos</option>
              <option value="PENDING">Aguardando pagamento</option>
              <option value="EXPIRED">Expirados</option>
              <option value="CANCELED">Cancelados</option>
            </Select>
          </div>

          {!loading && !error && (
            <p className="text-xs text-ash-400">
              Pago nesta pagina:{' '}
              <span className="font-bold text-ember-300">{brl(paidCents)}</span>
            </p>
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
              empty={
                <EmptyState
                  icon="▧"
                  title="Nenhuma venda ainda"
                  description="Assim que um cliente pagar o Pix pelo WhatsApp, o pedido aparece aqui."
                />
              }
            />
            <Pagination meta={data.meta} onChange={setPage} />
          </>
        )}
      </div>
    </>
  );
}
