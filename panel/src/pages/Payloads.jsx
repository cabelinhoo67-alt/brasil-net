import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { useToast } from '../context/ToastContext';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import Badge from '../components/ui/Badge';
import Modal, { ConfirmModal } from '../components/ui/Modal';
import { Input, Select, Switch, Textarea } from '../components/ui/Field';
import { EmptyState, ErrorState, Loading } from '../components/ui/Feedback';

const MODES = [
  { value: 'SSH_DIRECT', label: 'SSH Direto' },
  { value: 'SSH_PAYLOAD', label: 'SSH + Payload' },
  { value: 'SSH_SSL', label: 'SSH + SSL/TLS' },
  { value: 'V2RAY', label: 'V2Ray / Xray' },
  { value: 'SLOWDNS', label: 'SlowDNS' },
  { value: 'UDP', label: 'UDP Custom' },
];

const BLANK = {
  name: '',
  operatorId: '',
  serverId: '',
  mode: 'SSH_SSL',
  content: '',
  sni: '',
  proxyHost: '',
  proxyPort: '',
  dnsHost: '',
  publicKey: '',
  sortOrder: 1,
  isActive: true,
};

function PayloadModal({ open, payload, operators, servers, onClose, onSaved }) {
  const toast = useToast();
  const [form, setForm] = useState(BLANK);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!open) return;
    setError(null);
    setForm(
      payload
        ? {
            ...BLANK,
            ...payload,
            serverId: payload.serverId ?? payload.server?.id ?? '',
            operatorId: payload.operatorId ?? payload.operator?.id ?? '',
            proxyPort: payload.proxyPort ?? '',
            sni: payload.sni ?? '',
            proxyHost: payload.proxyHost ?? '',
            dnsHost: payload.dnsHost ?? '',
            publicKey: payload.publicKey ?? '',
          }
        : { ...BLANK, operatorId: operators[0]?.id ?? '', serverId: servers[0]?.id ?? '' },
    );
  }, [open, payload, operators, servers]);

  async function onSubmit(event) {
    event.preventDefault();
    setSaving(true);
    setError(null);

    // Campos vazios viram null: o backend valida com Zod e rejeita string vazia
    // onde espera url/host.
    const clean = (v) => (v === '' ? null : v);

    const body = {
      name: form.name,
      operatorId: form.operatorId,
      serverId: clean(form.serverId),
      mode: form.mode,
      content: form.content ?? '',
      sni: clean(form.sni),
      proxyHost: clean(form.proxyHost),
      proxyPort: form.proxyPort === '' ? null : Number(form.proxyPort),
      dnsHost: clean(form.dnsHost),
      publicKey: clean(form.publicKey),
      sortOrder: Number(form.sortOrder) || 0,
      isActive: form.isActive,
    };

    try {
      if (payload) await api.payloads.update(payload.id, body);
      else await api.payloads.create(body);

      toast.success('Payload salvo.');
      onSaved();
      onClose();
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  const isSsh = form.mode.startsWith('SSH');

  return (
    <Modal
      open={open}
      onClose={onClose}
      size="lg"
      title={payload ? 'Editar payload' : 'Novo payload'}
      subtitle="Entregue apenas a quem estiver com o chip desta operadora"
      footer={
        <div className="flex gap-2">
          <Button variant="ghost" className="flex-1" onClick={onClose}>
            Cancelar
          </Button>
          <Button type="submit" form="payload-form" className="flex-1" loading={saving}>
            Salvar
          </Button>
        </div>
      }
    >
      <form id="payload-form" onSubmit={onSubmit} className="space-y-4">
        <Input
          label="Nome"
          value={form.name}
          onChange={(e) => setForm({ ...form, name: e.target.value })}
          placeholder="Claro - SSH/SSL"
          required
        />

        <div className="grid gap-3 sm:grid-cols-2">
          <Select
            label="Operadora"
            value={form.operatorId}
            onChange={(e) => setForm({ ...form, operatorId: e.target.value })}
            required
          >
            {operators.map((op) => (
              <option key={op.id} value={op.id}>
                {op.name} ({op.code})
              </option>
            ))}
          </Select>

          <Select
            label="Servidor"
            value={form.serverId}
            onChange={(e) => setForm({ ...form, serverId: e.target.value })}
          >
            <option value="">Nenhum</option>
            {servers.map((server) => (
              <option key={server.id} value={server.id}>
                {server.name} — {server.host}
              </option>
            ))}
          </Select>
        </div>

        <Select
          label="Modo"
          value={form.mode}
          onChange={(e) => setForm({ ...form, mode: e.target.value })}
        >
          {MODES.map((mode) => (
            <option key={mode.value} value={mode.value}>
              {mode.label}
            </option>
          ))}
        </Select>

        <Textarea
          label={form.mode === 'V2RAY' ? 'Link vmess:// ou vless://' : 'Conteudo do payload'}
          rows={4}
          value={form.content}
          onChange={(e) => setForm({ ...form, content: e.target.value })}
          placeholder="CONNECT [host_port] [protocol][crlf]Host: [host][crlf][crlf]"
        />

        {isSsh && (
          <div className="grid gap-3 sm:grid-cols-3">
            <Input
              label="SNI"
              value={form.sni}
              onChange={(e) => setForm({ ...form, sni: e.target.value })}
              placeholder="www.claro.com.br"
            />
            <Input
              label="Proxy host"
              value={form.proxyHost}
              onChange={(e) => setForm({ ...form, proxyHost: e.target.value })}
            />
            <Input
              label="Proxy porta"
              type="number"
              value={form.proxyPort}
              onChange={(e) => setForm({ ...form, proxyPort: e.target.value })}
            />
          </div>
        )}

        {form.mode === 'SLOWDNS' && (
          <div className="grid gap-3 sm:grid-cols-2">
            <Input
              label="DNS host"
              value={form.dnsHost}
              onChange={(e) => setForm({ ...form, dnsHost: e.target.value })}
            />
            <Input
              label="Chave publica"
              value={form.publicKey}
              onChange={(e) => setForm({ ...form, publicKey: e.target.value })}
            />
          </div>
        )}

        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            label="Ordem"
            hint="menor aparece primeiro"
            type="number"
            value={form.sortOrder}
            onChange={(e) => setForm({ ...form, sortOrder: e.target.value })}
          />
          <div className="flex items-end">
            <Switch
              label="Ativo"
              description="Some do app na hora se desligar"
              checked={form.isActive}
              onChange={(v) => setForm({ ...form, isActive: v })}
            />
          </div>
        </div>

        {error && (
          <p className="rounded-xl border border-bad-500/40 bg-bad-500/10 px-3 py-2 text-xs text-red-200">
            {error}
          </p>
        )}
      </form>
    </Modal>
  );
}

export default function Payloads() {
  const toast = useToast();
  const [operatorFilter, setOperatorFilter] = useState('');
  const [editing, setEditing] = useState(undefined);
  const [removing, setRemoving] = useState(null);
  const [busy, setBusy] = useState(false);

  const operators = useApi(() => api.operators.list(), []);
  const servers = useApi(() => api.servers.list(), []);
  const payloads = useApi(
    () => api.payloads.list(operatorFilter ? { operatorId: operatorFilter } : undefined),
    [operatorFilter],
  );

  async function remove() {
    setBusy(true);
    try {
      await api.payloads.remove(removing.id);
      toast.success('Payload removido.');
      payloads.reload();
      operators.reload();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setBusy(false);
      setRemoving(null);
    }
  }

  async function duplicate(payload) {
    try {
      await api.payloads.duplicate(payload.id);
      toast.success('Copia criada (desativada). Ajuste e ative.');
      payloads.reload();
    } catch (err) {
      toast.error(err.message);
    }
  }

  const loading = operators.loading || servers.loading || payloads.loading;
  const error = operators.error || servers.error || payloads.error;

  return (
    <>
      <PageHeader
        title="Payloads"
        description="Configuracoes de conexao, sempre vinculadas a uma operadora."
        actions={
          <Button
            onClick={() => setEditing(null)}
            disabled={!operators.data?.items?.length}
          >
            + Novo payload
          </Button>
        }
      />

      {operators.data?.items?.length === 0 && (
        <div className="card mb-4 border-warn-500/30 p-4 text-sm text-amber-200">
          Cadastre uma operadora antes de criar payloads.
        </div>
      )}

      <div className="card overflow-hidden">
        <div className="border-b border-white/[0.06] p-4">
          <div className="sm:max-w-xs">
            <Select value={operatorFilter} onChange={(e) => setOperatorFilter(e.target.value)}>
              <option value="">Todas as operadoras</option>
              {(operators.data?.items ?? []).map((op) => (
                <option key={op.id} value={op.id}>
                  {op.name}
                </option>
              ))}
            </Select>
          </div>
        </div>

        {loading ? (
          <Loading />
        ) : error ? (
          <ErrorState error={error} onRetry={payloads.reload} />
        ) : payloads.data.items.length === 0 ? (
          <EmptyState
            icon="▤"
            title="Nenhum payload"
            description="Sem payload cadastrado, o app abre com a lista vazia."
          />
        ) : (
          <ul className="divide-y divide-white/[0.04]">
            {payloads.data.items.map((payload) => (
              <li key={payload.id} className="p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="mb-1 flex flex-wrap items-center gap-2">
                      <p className="truncate font-semibold text-white">{payload.name}</p>
                      <Badge tone="ember">{payload.operator.code}</Badge>
                      <Badge tone={payload.isActive ? 'ok' : 'neutral'}>
                        {payload.isActive ? 'ativo' : 'inativo'}
                      </Badge>
                    </div>

                    <p className="text-[11px] text-ash-400">
                      {MODES.find((m) => m.value === payload.mode)?.label ?? payload.mode}
                      {payload.server && ` · ${payload.server.name} (${payload.server.host})`}
                      {payload.sni && ` · SNI ${payload.sni}`}
                    </p>

                    {payload.content && (
                      <pre className="mt-2 overflow-x-auto rounded-lg border border-white/[0.06] bg-void-900 px-3 py-2 font-mono text-[11px] text-ash-300">
                        {payload.content}
                      </pre>
                    )}
                  </div>

                  <div className="flex shrink-0 gap-1.5">
                    <Button size="sm" variant="ghost" onClick={() => setEditing(payload)}>
                      Editar
                    </Button>
                    <Button size="sm" variant="subtle" onClick={() => duplicate(payload)}>
                      Clonar
                    </Button>
                    <Button size="sm" variant="danger" onClick={() => setRemoving(payload)}>
                      Excluir
                    </Button>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      <PayloadModal
        open={editing !== undefined}
        payload={editing}
        operators={operators.data?.items ?? []}
        servers={servers.data?.items ?? []}
        onClose={() => setEditing(undefined)}
        onSaved={() => {
          payloads.reload();
          operators.reload();
        }}
      />

      <ConfirmModal
        open={Boolean(removing)}
        onClose={() => setRemoving(null)}
        onConfirm={remove}
        loading={busy}
        title="Excluir payload"
        message={`"${removing?.name}" sera removido. Quem estiver conectado nao cai na hora, mas ele some da lista do app.`}
        confirmLabel="Excluir"
      />
    </>
  );
}
