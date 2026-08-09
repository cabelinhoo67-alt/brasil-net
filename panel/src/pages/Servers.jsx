import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { useToast } from '../context/ToastContext';
import { relative } from '../lib/format';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import Badge, { LiveDot } from '../components/ui/Badge';
import Modal, { ConfirmModal } from '../components/ui/Modal';
import { Input, Switch } from '../components/ui/Field';
import { EmptyState, ErrorState, Loading } from '../components/ui/Feedback';

/** Agente visto há menos de 2 min conta como online. */
const AGENT_ONLINE_MS = 120_000;

function agentState(server) {
  if (!server.hasAgent) {
    return { tone: 'neutral', label: 'sem agente', online: false };
  }
  if (!server.agentLastSeen) {
    return { tone: 'warn', label: 'nunca conectou', online: false };
  }
  const online = Date.now() - new Date(server.agentLastSeen).getTime() < AGENT_ONLINE_MS;
  return {
    tone: online ? 'ok' : 'bad',
    label: online ? 'agente online' : `visto ${relative(server.agentLastSeen)}`,
    online,
  };
}

/**
 * O token completo aparece uma unica vez. Depois disso ele so existe no
 * .env da VPS — regenerar invalida o anterior.
 */
function AgentTokenModal({ data, onClose }) {
  const toast = useToast();
  if (!data) return null;

  const envBlock = `API_URL=${window.location.origin.replace(':5173', ':3333')}\nAGENT_TOKEN="${data.agentToken}"`;

  return (
    <Modal
      open
      onClose={onClose}
      title="Token do agente"
      subtitle={`${data.serverName} — copie agora, ele nao volta a aparecer`}
      footer={
        <div className="flex gap-2">
          <Button
            variant="ghost"
            className="flex-1"
            onClick={() =>
              navigator.clipboard.writeText(envBlock).then(
                () => toast.success('Copiado.'),
                () => toast.error('Nao consegui copiar.'),
              )
            }
          >
            Copiar
          </Button>
          <Button className="flex-1" onClick={onClose}>
            Entendi
          </Button>
        </div>
      }
    >
      <p className="mb-3 text-xs text-ash-400">
        Cole no arquivo <code className="text-ember-300">/opt/tunnel-agent/.env</code> da VPS e
        reinicie o servico com <code className="text-ember-300">systemctl restart tunnel-agent</code>.
      </p>

      <pre className="overflow-x-auto rounded-xl border border-ember-600/30 bg-void-900 p-4 font-mono text-[11px] leading-relaxed text-zinc-200">
        {envBlock}
      </pre>

      <p className="mt-3 text-[11px] text-amber-300">
        Regenerar o token derruba o agente que estiver usando o anterior.
      </p>
    </Modal>
  );
}

const BLANK = {
  name: '',
  host: '',
  sshPort: 22,
  sslPort: 443,
  proxyPort: 80,
  country: 'BR',
  maxUsers: 0,
  isActive: true,
};

function ServerModal({ open, server, onClose, onSaved }) {
  const toast = useToast();
  const [form, setForm] = useState(BLANK);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!open) return;
    setError(null);
    setForm(server ? { ...BLANK, ...server } : BLANK);
  }, [open, server]);

  async function onSubmit(event) {
    event.preventDefault();
    setSaving(true);
    setError(null);

    const body = {
      name: form.name,
      host: form.host,
      sshPort: Number(form.sshPort),
      sslPort: Number(form.sslPort),
      proxyPort: Number(form.proxyPort),
      country: (form.country || 'BR').toUpperCase().slice(0, 2),
      maxUsers: Number(form.maxUsers) || 0,
      isActive: form.isActive,
    };

    try {
      if (server) await api.servers.update(server.id, body);
      else await api.servers.create(body);

      toast.success('Servidor salvo.');
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
      title={server ? `Editar ${server.name}` : 'Novo servidor'}
      footer={
        <div className="flex gap-2">
          <Button variant="ghost" className="flex-1" onClick={onClose}>
            Cancelar
          </Button>
          <Button type="submit" form="server-form" className="flex-1" loading={saving}>
            Salvar
          </Button>
        </div>
      }
    >
      <form id="server-form" onSubmit={onSubmit} className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            label="Nome"
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="Servidor BR-01"
            required
          />
          <Input
            label="Host"
            value={form.host}
            onChange={(e) => setForm({ ...form, host: e.target.value })}
            placeholder="br01.seudominio.com.br"
            required
          />
        </div>

        <div className="grid gap-3 sm:grid-cols-3">
          <Input
            label="Porta SSH"
            type="number"
            value={form.sshPort}
            onChange={(e) => setForm({ ...form, sshPort: e.target.value })}
          />
          <Input
            label="Porta SSL"
            type="number"
            value={form.sslPort}
            onChange={(e) => setForm({ ...form, sslPort: e.target.value })}
          />
          <Input
            label="Porta proxy"
            type="number"
            value={form.proxyPort}
            onChange={(e) => setForm({ ...form, proxyPort: e.target.value })}
          />
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            label="Pais"
            hint="2 letras"
            value={form.country}
            onChange={(e) => setForm({ ...form, country: e.target.value })}
            maxLength={2}
          />
          <Input
            label="Limite de usuarios"
            hint="0 = ilimitado"
            type="number"
            value={form.maxUsers}
            onChange={(e) => setForm({ ...form, maxUsers: e.target.value })}
          />
        </div>

        <Switch
          label="Servidor ativo"
          description="Inativo esconde todos os payloads ligados a ele"
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

export default function Servers() {
  const toast = useToast();
  const { data, loading, error, reload } = useApi(() => api.servers.list(), []);
  const [editing, setEditing] = useState(undefined);
  const [tokenData, setTokenData] = useState(null);
  const [regenerating, setRegenerating] = useState(null);
  const [busy, setBusy] = useState(false);

  async function generateToken(server) {
    setBusy(true);
    try {
      setTokenData(await api.servers.generateAgentToken(server.id));
      reload();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setBusy(false);
      setRegenerating(null);
    }
  }

  async function retryFailed(server) {
    try {
      const { requeued } = await api.servers.retryFailedTasks(server.id);
      toast.success(`${requeued} tarefa(s) de volta na fila.`);
      reload();
    } catch (err) {
      toast.error(err.message);
    }
  }

  return (
    <>
      <PageHeader
        title="Servidores"
        description="Endereco, portas e o agente que cria os usuarios SSH na VPS."
        actions={<Button onClick={() => setEditing(null)}>+ Novo servidor</Button>}
      />

      {loading ? (
        <Loading />
      ) : error ? (
        <ErrorState error={error} onRetry={reload} />
      ) : data.items.length === 0 ? (
        <div className="card">
          <EmptyState
            icon="▥"
            title="Nenhum servidor"
            description="Cadastre a VPS onde o tunel termina."
          />
        </div>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {data.items.map((server) => {
            const agent = agentState(server);

            return (
              <div key={server.id} className="card flex flex-col p-4">
                <div className="mb-2 flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="truncate text-base font-bold text-white">{server.name}</p>
                    <p className="truncate font-mono text-[11px] text-ash-400">{server.host}</p>
                  </div>
                  <Badge tone={server.isActive ? 'ok' : 'bad'}>
                    {server.isActive ? 'ativo' : 'inativo'}
                  </Badge>
                </div>

                <div className="mt-2 flex flex-wrap gap-1.5">
                  <Badge>SSH {server.sshPort}</Badge>
                  <Badge>SSL {server.sslPort}</Badge>
                  <Badge>Proxy {server.proxyPort}</Badge>
                </div>

                {/* Estado do agente: é o que diz se os logins existem de fato na VPS */}
                <div className="mt-3 rounded-xl border border-white/[0.06] bg-void-900/60 p-3">
                  <div className="flex items-center justify-between gap-2">
                    <span className="flex items-center gap-2 text-xs">
                      <LiveDot active={agent.online} />
                      <span className={agent.online ? 'text-emerald-300' : 'text-ash-300'}>
                        {agent.label}
                      </span>
                    </span>
                    {server.agentVersion && (
                      <span className="text-[10px] text-ash-400">v{server.agentVersion}</span>
                    )}
                  </div>

                  {server.hasAgent && (
                    <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-ash-400">
                      <span>{server.agentUserCount ?? 0} conta(s) na VPS</span>
                      {server.pendingTasks > 0 && (
                        <span className="text-amber-300">{server.pendingTasks} na fila</span>
                      )}
                      {server.failedTasks > 0 && (
                        <span className="text-red-300">{server.failedTasks} com falha</span>
                      )}
                    </div>
                  )}

                  <div className="mt-2.5 flex flex-wrap gap-1.5">
                    <Button
                      size="sm"
                      variant={server.hasAgent ? 'subtle' : 'primary'}
                      loading={busy}
                      onClick={() =>
                        server.hasAgent ? setRegenerating(server) : generateToken(server)
                      }
                    >
                      {server.hasAgent ? 'Regerar token' : 'Gerar token do agente'}
                    </Button>

                    {server.failedTasks > 0 && (
                      <Button size="sm" variant="ghost" onClick={() => retryFailed(server)}>
                        Reenfileirar falhas
                      </Button>
                    )}
                  </div>
                </div>

                <div className="mt-3 flex items-center justify-between border-t border-white/[0.05] pt-3 text-xs text-ash-400">
                  <span>
                    {server._count?.payloads ?? 0} payload(s) ·{' '}
                    {server.maxUsers === 0 ? 'sem limite' : `max ${server.maxUsers}`}
                  </span>
                  <button
                    onClick={() => setEditing(server)}
                    className="font-semibold text-ember-400 hover:text-ember-300"
                  >
                    Editar
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      <AgentTokenModal data={tokenData} onClose={() => setTokenData(null)} />

      <ConfirmModal
        open={Boolean(regenerating)}
        onClose={() => setRegenerating(null)}
        onConfirm={() => generateToken(regenerating)}
        loading={busy}
        title="Regerar token"
        message={`O agente que roda em "${regenerating?.name}" vai parar de sincronizar ate receber o token novo.`}
        confirmLabel="Regerar"
      />

      <ServerModal
        open={editing !== undefined}
        server={editing}
        onClose={() => setEditing(undefined)}
        onSaved={reload}
      />
    </>
  );
}
