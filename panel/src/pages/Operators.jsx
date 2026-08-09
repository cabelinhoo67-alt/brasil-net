import { useState } from 'react';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { useToast } from '../context/ToastContext';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import Badge from '../components/ui/Badge';
import Modal from '../components/ui/Modal';
import { Input, Switch } from '../components/ui/Field';
import { EmptyState, ErrorState, Loading } from '../components/ui/Feedback';

const BLANK = { code: '', name: '', mccMncList: '', sortOrder: 0, isActive: true };

function OperatorModal({ open, operator, onClose, onSaved }) {
  const toast = useToast();
  const [form, setForm] = useState(BLANK);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  // Reinicia o formulario sempre que o modal reabre com outro registro.
  const key = operator?.id ?? 'new';
  const [loadedKey, setLoadedKey] = useState(null);
  if (open && loadedKey !== key) {
    setForm(operator ? { ...BLANK, ...operator } : BLANK);
    setLoadedKey(key);
    setError(null);
  }
  if (!open && loadedKey !== null) setLoadedKey(null);

  async function onSubmit(event) {
    event.preventDefault();
    setSaving(true);
    setError(null);

    const body = {
      code: form.code,
      name: form.name,
      mccMncList: (form.mccMncList || '').replace(/\s/g, ''),
      sortOrder: Number(form.sortOrder) || 0,
      isActive: form.isActive,
    };

    try {
      if (operator) await api.operators.update(operator.id, body);
      else await api.operators.create(body);

      toast.success('Operadora salva.');
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
      title={operator ? `Editar ${operator.name}` : 'Nova operadora'}
      subtitle="O MCC/MNC e o que identifica o chip com seguranca"
      footer={
        <div className="flex gap-2">
          <Button variant="ghost" className="flex-1" onClick={onClose}>
            Cancelar
          </Button>
          <Button type="submit" form="op-form" className="flex-1" loading={saving}>
            Salvar
          </Button>
        </div>
      }
    >
      <form id="op-form" onSubmit={onSubmit} className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            label="Codigo"
            hint="maiusculas"
            value={form.code}
            onChange={(e) => setForm({ ...form, code: e.target.value.toUpperCase() })}
            placeholder="CLARO"
            required
          />
          <Input
            label="Nome exibido"
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="Claro"
            required
          />
        </div>

        <Input
          label="MCC/MNC"
          hint="separe por virgula"
          value={form.mccMncList}
          onChange={(e) => setForm({ ...form, mccMncList: e.target.value })}
          placeholder="72405,72438"
        />

        <p className="rounded-xl border border-white/[0.06] bg-void-800/50 px-3 py-2 text-[11px] text-ash-400">
          O Brasil usa MCC <span className="text-zinc-300">724</span>. Se um chip nao for
          reconhecido, veja no log da API qual codigo chegou e acrescente-o aqui — MVNOs tem
          codigo proprio.
        </p>

        <Input
          label="Ordem"
          type="number"
          value={form.sortOrder}
          onChange={(e) => setForm({ ...form, sortOrder: e.target.value })}
        />

        <Switch
          label="Operadora ativa"
          description="Inativa some da deteccao do aplicativo"
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

export default function Operators() {
  const { data, loading, error, reload } = useApi(() => api.operators.list(), []);
  const [editing, setEditing] = useState(undefined);

  return (
    <>
      <PageHeader
        title="Operadoras"
        description="O aplicativo so entrega payloads da operadora detectada no chip."
        actions={<Button onClick={() => setEditing(null)}>+ Nova operadora</Button>}
      />

      {loading ? (
        <Loading />
      ) : error ? (
        <ErrorState error={error} onRetry={reload} />
      ) : data.items.length === 0 ? (
        <div className="card">
          <EmptyState icon="▣" title="Nenhuma operadora" description="Cadastre Claro, Vivo, TIM..." />
        </div>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {data.items.map((operator) => (
            <button
              key={operator.id}
              onClick={() => setEditing(operator)}
              className="card group p-4 text-left transition-colors hover:border-ember-500/40"
            >
              <div className="mb-2 flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="truncate text-base font-bold text-white">{operator.name}</p>
                  <p className="truncate text-[11px] uppercase tracking-widest text-ember-500">
                    {operator.code}
                  </p>
                </div>
                <Badge tone={operator.isActive ? 'ok' : 'neutral'}>
                  {operator.isActive ? 'ativa' : 'inativa'}
                </Badge>
              </div>

              <p className="font-mono text-[11px] text-ash-400">
                {operator.mccMncList || 'sem MCC/MNC cadastrado'}
              </p>

              <div className="mt-3 flex items-center justify-between border-t border-white/[0.05] pt-3">
                <span className="text-xs text-ash-400">
                  {operator._count?.payloads ?? 0} payload(s)
                </span>
                <span className="text-xs font-semibold text-ember-400 opacity-0 transition-opacity group-hover:opacity-100">
                  Editar
                </span>
              </div>
            </button>
          ))}
        </div>
      )}

      <OperatorModal
        open={editing !== undefined}
        operator={editing}
        onClose={() => setEditing(undefined)}
        onSaved={reload}
      />
    </>
  );
}
