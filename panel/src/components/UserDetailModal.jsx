import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { ROLE_LABEL } from '../lib/roles';
import { clientStatus, date, dateTime, relative } from '../lib/format';
import Modal, { ConfirmModal } from './ui/Modal';
import Button from './ui/Button';
import Badge from './ui/Badge';
import { Input, Select } from './ui/Field';
import { Spinner } from './ui/Feedback';

function Row({ label, children }) {
  return (
    <div className="flex items-center justify-between gap-4 py-2">
      <span className="text-xs text-ash-400">{label}</span>
      <span className="text-right text-sm text-zinc-200">{children}</span>
    </div>
  );
}

export default function UserDetailModal({ userId, open, onClose, onChanged }) {
  const { user: me, refresh } = useAuth();
  const toast = useToast();

  const [detail, setDetail] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [plans, setPlans] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState(null);

  const [renewPlanId, setRenewPlanId] = useState('');
  const [renewDays, setRenewDays] = useState('');
  const [newPassword, setNewPassword] = useState('');

  const isClient = detail?.role === 'CLIENT';

  async function load() {
    setLoading(true);
    try {
      const data = await api.users.get(userId);
      setDetail(data);

      if (data.role === 'CLIENT') {
        const [{ items: sess }, { items: planItems }] = await Promise.all([
          api.users.sessions(userId),
          api.plans.list(),
        ]);
        setSessions(sess);
        setPlans(planItems);
        setRenewPlanId(data.plan?.id ?? planItems[0]?.id ?? '');
      }
    } catch (err) {
      toast.error(err.message);
      onClose();
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (open && userId) load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, userId]);

  async function act(fn, successMessage) {
    setBusy(true);
    try {
      await fn();
      toast.success(successMessage);
      await Promise.all([load(), refresh()]);
      onChanged?.();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setBusy(false);
      setConfirm(null);
    }
  }

  const renewCost = renewPlanId
    ? (plans.find((p) => p.id === renewPlanId)?.creditCost ?? 0)
    : Number(renewDays) || 0;

  return (
    <>
      <Modal
        open={open}
        onClose={onClose}
        size="lg"
        title={detail?.username ?? 'Carregando...'}
        subtitle={detail ? ROLE_LABEL[detail.role] : undefined}
      >
        {loading || !detail ? (
          <div className="flex justify-center py-12">
            <Spinner />
          </div>
        ) : (
          <div className="space-y-5">
            {/* ------------------------------ resumo ------------------------------ */}
            <section className="divide-y divide-white/[0.05] rounded-xl border border-white/[0.06] bg-void-800/50 px-4">
              <Row label="Situacao">
                <Badge tone={clientStatus(detail).tone}>{clientStatus(detail).label}</Badge>
              </Row>
              {isClient && (
                <>
                  <Row label="Validade">
                    {date(detail.expiresAt)}{' '}
                    <span className="text-ash-400">
                      ({detail.daysLeft ?? 0} dia{detail.daysLeft === 1 ? '' : 's'})
                    </span>
                  </Row>
                  <Row label="Conexoes">
                    {detail.activeSessions ?? 0} de {detail.connectionLimit} em uso
                  </Row>
                  <Row label="Plano">{detail.plan?.name ?? 'avulso'}</Row>
                </>
              )}
              {!isClient && <Row label="Creditos">{detail.credits}</Row>}
              <Row label="Criado por">{detail.parent?.username ?? '--'}</Row>
              <Row label="Cadastro">{date(detail.createdAt)}</Row>
              <Row label="Ultimo login">
                {detail.lastLogin ? dateTime(detail.lastLogin) : 'nunca acessou'}
              </Row>
              {detail.whatsapp && <Row label="WhatsApp">{detail.whatsapp}</Row>}
            </section>

            {/* ------------------------------ renovar ----------------------------- */}
            {isClient && (
              <section className="rounded-xl border border-ember-600/25 bg-ember-600/[0.04] p-4">
                <h3 className="mb-3 text-sm font-semibold text-white">Renovar acesso</h3>

                <div className="grid gap-3 sm:grid-cols-2">
                  <Select
                    label="Plano"
                    value={renewPlanId}
                    onChange={(e) => setRenewPlanId(e.target.value)}
                  >
                    <option value="">Dias avulsos</option>
                    {plans.map((plan) => (
                      <option key={plan.id} value={plan.id}>
                        {plan.name} — {plan.days}d · {plan.creditCost} cred.
                      </option>
                    ))}
                  </Select>

                  {!renewPlanId && (
                    <Input
                      label="Dias"
                      type="number"
                      min={1}
                      value={renewDays}
                      onChange={(e) => setRenewDays(e.target.value)}
                    />
                  )}
                </div>

                <div className="mt-3 flex items-center justify-between gap-3">
                  <span className="text-xs text-ash-400">
                    Custo:{' '}
                    <span className="font-bold text-ember-300">
                      {me.role === 'ADMIN' ? 'gratis (admin)' : `${renewCost} credito(s)`}
                    </span>
                  </span>
                  <Button
                    size="sm"
                    loading={busy}
                    disabled={!renewPlanId && !renewDays}
                    onClick={() =>
                      act(
                        () =>
                          api.users.renew(
                            detail.id,
                            renewPlanId ? { planId: renewPlanId } : { days: Number(renewDays) },
                          ),
                        'Acesso renovado.',
                      )
                    }
                  >
                    Renovar
                  </Button>
                </div>
                <p className="mt-2 text-[11px] text-ash-400">
                  Se ainda nao venceu, os dias sao somados ao saldo restante.
                </p>
              </section>
            )}

            {/* ------------------------------ sessoes ----------------------------- */}
            {isClient && (
              <section className="rounded-xl border border-white/[0.06]">
                <header className="flex items-center justify-between border-b border-white/[0.06] px-4 py-3">
                  <h3 className="text-sm font-semibold text-white">Conexoes ativas</h3>
                  {sessions.length > 0 && (
                    <Button
                      size="sm"
                      variant="danger"
                      onClick={() =>
                        setConfirm({
                          title: 'Derrubar conexoes',
                          message: `Todas as ${sessions.length} conexao(oes) deste cliente serao encerradas. Ele podera reconectar em seguida.`,
                          confirmLabel: 'Derrubar',
                          run: () =>
                            act(() => api.users.killSessions(detail.id), 'Conexoes encerradas.'),
                        })
                      }
                    >
                      Derrubar todas
                    </Button>
                  )}
                </header>

                {sessions.length === 0 ? (
                  <p className="px-4 py-6 text-center text-xs text-ash-400">
                    Nenhum aparelho conectado agora.
                  </p>
                ) : (
                  <ul className="divide-y divide-white/[0.04]">
                    {sessions.map((session) => (
                      <li key={session.id} className="px-4 py-3">
                        <p className="text-sm text-white">{session.deviceName ?? 'Aparelho'}</p>
                        <p className="text-[11px] text-ash-400">
                          {session.operator ?? 'operadora ?'} · {session.ip ?? 'ip ?'} · visto{' '}
                          {relative(session.lastSeenAt)}
                        </p>
                      </li>
                    ))}
                  </ul>
                )}
              </section>
            )}

            {/* ------------------------------ acoes ------------------------------- */}
            <section className="space-y-3 rounded-xl border border-white/[0.06] p-4">
              <h3 className="text-sm font-semibold text-white">Administrar</h3>

              <div className="flex gap-2">
                <Input
                  placeholder="Nova senha"
                  value={newPassword}
                  onChange={(e) => setNewPassword(e.target.value)}
                />
                <Button
                  variant="ghost"
                  disabled={newPassword.length < 4}
                  loading={busy}
                  onClick={() =>
                    act(async () => {
                      await api.users.update(detail.id, { password: newPassword });
                      setNewPassword('');
                    }, 'Senha alterada. As sessoes ativas foram encerradas.')
                  }
                >
                  Trocar
                </Button>
              </div>

              <div className="flex flex-wrap gap-2">
                <Button
                  variant="ghost"
                  size="sm"
                  loading={busy}
                  onClick={() =>
                    act(
                      () => api.users.update(detail.id, { isBlocked: !detail.isBlocked }),
                      detail.isBlocked ? 'Usuario desbloqueado.' : 'Usuario bloqueado.',
                    )
                  }
                >
                  {detail.isBlocked ? 'Desbloquear' : 'Bloquear'}
                </Button>

                <Button
                  variant="danger"
                  size="sm"
                  onClick={() =>
                    setConfirm({
                      title: 'Excluir usuario',
                      message: `"${detail.username}" sera removido definitivamente. O saldo nao usado volta para voce.`,
                      confirmLabel: 'Excluir',
                      run: () =>
                        act(async () => {
                          await api.users.remove(detail.id);
                          onClose();
                        }, 'Usuario removido.'),
                    })
                  }
                >
                  Excluir
                </Button>
              </div>

              {detail.isBlocked && (
                <p className="text-[11px] text-amber-300">
                  Bloqueado: o aplicativo derruba a conexao no proximo heartbeat.
                </p>
              )}
            </section>
          </div>
        )}
      </Modal>

      <ConfirmModal
        open={Boolean(confirm)}
        onClose={() => setConfirm(null)}
        onConfirm={() => confirm?.run()}
        title={confirm?.title}
        message={confirm?.message}
        confirmLabel={confirm?.confirmLabel}
        loading={busy}
      />
    </>
  );
}
