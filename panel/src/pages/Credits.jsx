import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { can, isSimpleView } from '../lib/roles';
import { dateTime } from '../lib/format';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import Badge from '../components/ui/Badge';
import Modal from '../components/ui/Modal';
import Pagination from '../components/ui/Pagination';
import DataTable from '../components/ui/DataTable';
import { EmptyState, ErrorState, Loading } from '../components/ui/Feedback';
import { Input, Select } from '../components/ui/Field';

const KIND = {
  ADD: { label: 'Emissao', tone: 'ember' },
  TRANSFER: { label: 'Transferencia', tone: 'ok' },
  CONSUME: { label: 'Consumo', tone: 'neutral' },
  REFUND: { label: 'Estorno', tone: 'warn' },
};

/** Transferir para baixo ou recolher de volta usam o mesmo formulario. */
function TransferModal({ open, onClose, mode, onDone }) {
  const { user, refresh } = useAuth();
  const toast = useToast();

  const [targets, setTargets] = useState([]);
  const [targetId, setTargetId] = useState('');
  const [amount, setAmount] = useState(10);
  const [description, setDescription] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const isWithdraw = mode === 'withdraw';

  useEffect(() => {
    if (!open) return;
    setError(null);
    setAmount(10);
    setDescription('');

    // Só revendedores têm saldo; clientes finais ficam fora da lista.
    api.users
      .list({ perPage: 100 })
      .then(({ items }) => {
        const eligible = items.filter((item) => item.role !== 'CLIENT');
        setTargets(eligible);
        setTargetId(eligible[0]?.id ?? '');
      })
      .catch((err) => setError(err.message));
  }, [open]);

  async function onSubmit(event) {
    event.preventDefault();
    setSaving(true);
    setError(null);

    try {
      const body = isWithdraw
        ? { fromUserId: targetId, amount: Number(amount), description }
        : { toUserId: targetId, amount: Number(amount), description };

      await (isWithdraw ? api.credits.withdraw(body) : api.credits.transfer(body));

      toast.success(isWithdraw ? 'Creditos recolhidos.' : 'Creditos enviados.');
      await refresh();
      onDone?.();
      onClose();
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  const overBalance =
    !isWithdraw && !can.hasUnlimitedCredits(user.role) && Number(amount) > (user.credits ?? 0);

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={isWithdraw ? 'Recolher creditos' : 'Enviar creditos'}
      subtitle={
        can.hasUnlimitedCredits(user.role) && !isWithdraw
          ? 'Como admin, voce emite credito novo no sistema'
          : `Seu saldo: ${user.credits ?? 0}`
      }
      footer={
        <div className="flex gap-2">
          <Button variant="ghost" className="flex-1" onClick={onClose}>
            Cancelar
          </Button>
          <Button
            type="submit"
            form="credit-form"
            className="flex-1"
            loading={saving}
            disabled={!targetId || overBalance}
          >
            {isWithdraw ? 'Recolher' : 'Enviar'}
          </Button>
        </div>
      }
    >
      <form id="credit-form" onSubmit={onSubmit} className="space-y-4">
        <Select
          label={isWithdraw ? 'Recolher de' : 'Enviar para'}
          value={targetId}
          onChange={(e) => setTargetId(e.target.value)}
        >
          {targets.length === 0 && <option value="">Nenhum revendedor na sua rede</option>}
          {targets.map((item) => (
            <option key={item.id} value={item.id}>
              {item.username} ({item.credits} cred.)
            </option>
          ))}
        </Select>

        <Input
          label="Quantidade"
          type="number"
          min={1}
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          required
        />

        <Input
          label="Observacao (opcional)"
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="ex.: pagamento recebido via Pix"
        />

        {overBalance && (
          <p className="rounded-xl border border-bad-500/40 bg-bad-500/10 px-3 py-2 text-xs text-red-200">
            Valor maior que o seu saldo.
          </p>
        )}
        {error && (
          <p className="rounded-xl border border-bad-500/40 bg-bad-500/10 px-3 py-2 text-xs text-red-200">
            {error}
          </p>
        )}
      </form>
    </Modal>
  );
}

export default function Credits() {
  const { user } = useAuth();
  const [page, setPage] = useState(1);
  const [modal, setModal] = useState(null);

  const { data, loading, error, reload } = useApi(
    () => api.credits.history({ page, perPage: 20 }),
    [page],
  );

  const simple = isSimpleView(user.role);

  const columns = [
    {
      key: 'kind',
      header: 'Tipo',
      render: (row) => (
        <Badge tone={KIND[row.kind]?.tone ?? 'neutral'}>{KIND[row.kind]?.label ?? row.kind}</Badge>
      ),
    },
    {
      key: 'amount',
      header: 'Qtd.',
      render: (row) => <span className="font-bold text-white">{row.amount}</span>,
    },
    {
      key: 'from',
      header: 'De',
      render: (row) => (
        <span className="text-sm text-zinc-300">{row.fromUser?.username ?? 'sistema'}</span>
      ),
    },
    {
      key: 'to',
      header: 'Para',
      render: (row) => (
        <span className="text-sm text-zinc-300">{row.toUser?.username ?? '--'}</span>
      ),
    },
    {
      key: 'description',
      header: 'Observacao',
      hideOnMobile: true,
      render: (row) => (
        <span className="text-xs text-ash-400">{row.description ?? '--'}</span>
      ),
    },
    {
      key: 'date',
      header: 'Quando',
      render: (row) => <span className="text-xs text-ash-400">{dateTime(row.createdAt)}</span>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Creditos"
        description={
          simple
            ? 'Seu saldo e o historico de movimentacoes.'
            : 'Distribua saldo para a sua rede e acompanhe o extrato.'
        }
        actions={
          !simple && (
            <>
              <Button variant="ghost" onClick={() => setModal('withdraw')}>
                Recolher
              </Button>
              <Button onClick={() => setModal('transfer')}>
                {can.issueCredits(user.role) ? 'Emitir creditos' : 'Enviar creditos'}
              </Button>
            </>
          )
        }
      />

      <div className="mb-6 grid gap-3 sm:grid-cols-3">
        <div className="card-ember p-5 sm:col-span-1">
          <p className="text-[10px] uppercase tracking-[0.18em] text-ash-400">Saldo atual</p>
          <p className="mt-1 text-4xl font-black leading-none ember-text">
            {can.hasUnlimitedCredits(user.role) ? '∞' : (user.credits ?? 0)}
          </p>
        </div>

        <div className="card p-5 sm:col-span-2">
          <p className="text-[10px] uppercase tracking-[0.18em] text-ash-400">Como funciona</p>
          <p className="mt-2 text-sm text-zinc-300">
            {simple
              ? 'Criar um cliente consome creditos conforme o plano escolhido. Renovar tambem. Precisa de mais saldo? Fale com quem te cadastrou.'
              : 'Voce envia creditos para os revendedores abaixo de voce. Eles gastam ao criar e renovar clientes. Excluir um revendedor devolve o saldo nao usado para voce.'}
          </p>
        </div>
      </div>

      <div className="card overflow-hidden">
        <header className="border-b border-white/[0.06] px-4 py-3">
          <h2 className="text-sm font-semibold text-white">Extrato</h2>
        </header>

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
                  icon="❖"
                  title="Sem movimentacoes"
                  description="Transferencias e consumos aparecem aqui."
                />
              }
            />
            <Pagination meta={data.meta} onChange={setPage} />
          </>
        )}
      </div>

      <TransferModal
        open={Boolean(modal)}
        mode={modal}
        onClose={() => setModal(null)}
        onDone={reload}
      />
    </>
  );
}
