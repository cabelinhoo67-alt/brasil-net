import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { useToast } from '../context/ToastContext';
import { brl } from '../lib/format';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import Badge from '../components/ui/Badge';
import Modal, { ConfirmModal } from '../components/ui/Modal';
import { Input, Switch } from '../components/ui/Field';
import { EmptyState, ErrorState, Loading } from '../components/ui/Feedback';

const BLANK = {
  name: '',
  days: 30,
  connectionLimit: 1,
  creditCost: 1,
  price: '25,00',
  description: '',
  isPublic: true,
  isActive: true,
  sortOrder: 0,
};

const toCents = (value) => Math.round(Number(String(value).replace(',', '.')) * 100) || 0;

function PlanModal({ open, plan, onClose, onSaved }) {
  const toast = useToast();
  const [form, setForm] = useState(BLANK);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!open) return;
    setError(null);
    setForm(
      plan
        ? { ...BLANK, ...plan, price: (plan.priceCents / 100).toFixed(2).replace('.', ','), description: plan.description ?? '' }
        : BLANK,
    );
  }, [open, plan]);

  async function onSubmit(event) {
    event.preventDefault();
    setSaving(true);
    setError(null);

    const body = {
      name: form.name,
      days: Number(form.days),
      connectionLimit: Number(form.connectionLimit),
      creditCost: Number(form.creditCost),
      priceCents: toCents(form.price),
      description: form.description || null,
      isPublic: form.isPublic,
      isActive: form.isActive,
      sortOrder: Number(form.sortOrder) || 0,
    };

    try {
      if (plan) await api.plans.update(plan.id, body);
      else await api.plans.create(body);

      toast.success('Plano salvo.');
      onSaved();
      onClose();
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={plan ? `Editar ${plan.name}` : 'Novo plano'}
      subtitle="Define validade, conexoes, custo em credito e preco de venda"
      footer={
        <div className="flex gap-2">
          <Button variant="ghost" className="flex-1" onClick={onClose}>
            Cancelar
          </Button>
          <Button type="submit" form="plan-form" className="flex-1" loading={saving}>
            Salvar
          </Button>
        </div>
      }
    >
      <form id="plan-form" onSubmit={onSubmit} className="space-y-4">
        <Input
          label="Nome"
          value={form.name}
          onChange={(e) => setForm({ ...form, name: e.target.value })}
          placeholder="Mensal 1 conexao"
          required
        />

        <div className="grid gap-3 sm:grid-cols-3">
          <Input
            label="Dias"
            type="number"
            min={1}
            value={form.days}
            onChange={(e) => setForm({ ...form, days: e.target.value })}
            required
          />
          <Input
            label="Conexoes"
            type="number"
            min={1}
            value={form.connectionLimit}
            onChange={(e) => setForm({ ...form, connectionLimit: e.target.value })}
          />
          <Input
            label="Custo (creditos)"
            hint="cobrado do revendedor"
            type="number"
            min={0}
            value={form.creditCost}
            onChange={(e) => setForm({ ...form, creditCost: e.target.value })}
          />
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            label="Preco de venda"
            hint="usado no Pix do bot"
            value={form.price}
            onChange={(e) => setForm({ ...form, price: e.target.value })}
            placeholder="25,00"
          />
          <Input
            label="Ordem"
            type="number"
            value={form.sortOrder}
            onChange={(e) => setForm({ ...form, sortOrder: e.target.value })}
          />
        </div>

        <Input
          label="Descricao (opcional)"
          value={form.description}
          onChange={(e) => setForm({ ...form, description: e.target.value })}
          placeholder="30 dias, 1 aparelho"
        />

        <Switch
          label="Aparece no bot do WhatsApp"
          description="Precisa tambem ter preco maior que zero"
          checked={form.isPublic}
          onChange={(v) => setForm({ ...form, isPublic: v })}
        />

        <Switch
          label="Plano ativo"
          description="Inativo some das listas de criacao e renovacao"
          checked={form.isActive}
          onChange={(v) => setForm({ ...form, isActive: v })}
        />

        {error && (
          <p className="rounded-xl border border-bad-500/40 bg-bad-500/10 px-3 py-2 text-xs text-red-200">
            {error}
          </p>
        )}
      </form>
    </Modal>
  );
}

export default function Plans() {
  const toast = useToast();
  const { data, loading, error, reload } = useApi(() => api.plans.list(), []);
  const [editing, setEditing] = useState(undefined);
  const [removing, setRemoving] = useState(null);
  const [busy, setBusy] = useState(false);

  async function remove() {
    setBusy(true);
    try {
      await api.plans.remove(removing.id);
      toast.success('Plano removido.');
      reload();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setBusy(false);
      setRemoving(null);
    }
  }

  return (
    <>
      <PageHeader
        title="Planos"
        description="Base do custo em creditos e do preco cobrado no Pix."
        actions={<Button onClick={() => setEditing(null)}>+ Novo plano</Button>}
      />

      {loading ? (
        <Loading />
      ) : error ? (
        <ErrorState error={error} onRetry={reload} />
      ) : data.items.length === 0 ? (
        <div className="card">
          <EmptyState icon="▦" title="Nenhum plano" description="Crie ao menos um plano mensal." />
        </div>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {data.items.map((plan) => (
            <div key={plan.id} className="card flex flex-col p-4">
              <div className="mb-3 flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="truncate text-base font-bold text-white">{plan.name}</p>
                  <p className="text-[11px] text-ash-400">{plan.description ?? '—'}</p>
                </div>
                {!plan.isActive && <Badge tone="bad">inativo</Badge>}
              </div>

              <p className="text-3xl font-black leading-none ember-text">
                {plan.priceCents > 0 ? brl(plan.priceCents) : 'sem preco'}
              </p>

              <div className="mt-3 flex flex-wrap gap-1.5">
                <Badge>{plan.days} dias</Badge>
                <Badge>{plan.connectionLimit} conexao(oes)</Badge>
                <Badge tone="ember">{plan.creditCost} credito(s)</Badge>
                {plan.isPublic && plan.priceCents > 0 && <Badge tone="ok">no bot</Badge>}
              </div>

              <div className="mt-4 flex gap-1.5 border-t border-white/[0.05] pt-3">
                <Button size="sm" variant="ghost" className="flex-1" onClick={() => setEditing(plan)}>
                  Editar
                </Button>
                <Button size="sm" variant="danger" onClick={() => setRemoving(plan)}>
                  Excluir
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}

      <PlanModal
        open={editing !== undefined}
        plan={editing}
        onClose={() => setEditing(undefined)}
        onSaved={reload}
      />

      <ConfirmModal
        open={Boolean(removing)}
        onClose={() => setRemoving(null)}
        onConfirm={remove}
        loading={busy}
        title="Excluir plano"
        message={`"${removing?.name}" sera removido. Clientes ja criados com ele nao sao afetados.`}
        confirmLabel="Excluir"
      />
    </>
  );
}
