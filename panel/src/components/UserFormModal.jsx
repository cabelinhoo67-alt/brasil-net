import { useEffect, useMemo, useState } from 'react';
import { api } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { CREATABLE_ROLES, ROLE_LABEL } from '../lib/roles';
import Modal from './ui/Modal';
import Button from './ui/Button';
import { Input, Select } from './ui/Field';

/** Sugere um usuario/senha legivel — a maioria das revendas usa isso. */
function randomToken(size = 6) {
  const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
  return Array.from({ length: size }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join('');
}

export default function UserFormModal({ open, onClose, onCreated, defaultRole = 'CLIENT' }) {
  const { user, refresh } = useAuth();
  const toast = useToast();

  const allowedRoles = CREATABLE_ROLES[user.role] ?? [];
  const [role, setRole] = useState(defaultRole);
  const [form, setForm] = useState({ username: '', password: '', fullName: '', whatsapp: '' });
  const [planId, setPlanId] = useState('');
  const [days, setDays] = useState('');
  const [connectionLimit, setConnectionLimit] = useState(1);
  const [initialCredits, setInitialCredits] = useState(0);
  const [plans, setPlans] = useState([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!open) return;

    setRole(defaultRole);
    setForm({ username: `${defaultRole === 'CLIENT' ? 'cli' : 'rev'}${randomToken(5)}`, password: randomToken(8), fullName: '', whatsapp: '' });
    setDays('');
    setConnectionLimit(1);
    setInitialCredits(0);
    setError(null);

    api.plans
      .list()
      .then(({ items }) => {
        setPlans(items);
        setPlanId(items[0]?.id ?? '');
      })
      .catch(() => setPlans([]));
  }, [open, defaultRole]);

  const selectedPlan = useMemo(() => plans.find((p) => p.id === planId), [plans, planId]);

  // Sem plano escolhido, o backend cobra 1 credito por dia avulso.
  const cost = role !== 'CLIENT'
    ? Number(initialCredits) || 0
    : planId
      ? (selectedPlan?.creditCost ?? 0)
      : Number(days) || 0;

  const unlimited = user.role === 'ADMIN';
  const insufficient = !unlimited && cost > (user.credits ?? 0);

  async function onSubmit(event) {
    event.preventDefault();
    setSaving(true);
    setError(null);

    const body = {
      username: form.username.trim(),
      password: form.password,
      role,
      ...(form.fullName ? { fullName: form.fullName } : {}),
      ...(form.whatsapp ? { whatsapp: form.whatsapp } : {}),
    };

    if (role === 'CLIENT') {
      if (planId) body.planId = planId;
      else {
        body.days = Number(days);
        body.connectionLimit = Number(connectionLimit);
      }
    } else if (Number(initialCredits) > 0) {
      body.initialCredits = Number(initialCredits);
    }

    try {
      const created = await api.users.create(body);
      toast.success(`${ROLE_LABEL[role]} "${created.username}" criado.`);
      await refresh();
      onCreated?.(created, form.password);
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
      title="Novo acesso"
      subtitle={
        unlimited
          ? 'Voce tem credito ilimitado'
          : `Seu saldo: ${user.credits ?? 0} credito(s)`
      }
      footer={
        <div className="flex items-center gap-3">
          <div className="flex-1 text-xs">
            <span className="text-ash-400">Custo: </span>
            <span className={insufficient ? 'font-bold text-red-400' : 'font-bold text-ember-300'}>
              {unlimited ? 'gratis (admin)' : `${cost} credito(s)`}
            </span>
          </div>
          <Button variant="ghost" onClick={onClose}>
            Cancelar
          </Button>
          <Button
            type="submit"
            form="user-form"
            loading={saving}
            disabled={insufficient}
          >
            Criar
          </Button>
        </div>
      }
    >
      <form id="user-form" onSubmit={onSubmit} className="space-y-4">
        {allowedRoles.length > 1 && (
          <Select label="Tipo de acesso" value={role} onChange={(e) => setRole(e.target.value)}>
            {allowedRoles.map((item) => (
              <option key={item} value={item}>
                {ROLE_LABEL[item]}
              </option>
            ))}
          </Select>
        )}

        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            label="Usuario"
            value={form.username}
            onChange={(e) => setForm({ ...form, username: e.target.value })}
            required
            minLength={3}
          />
          <Input
            label="Senha"
            hint="anote antes de salvar"
            value={form.password}
            onChange={(e) => setForm({ ...form, password: e.target.value })}
            required
            minLength={4}
          />
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            label="Nome (opcional)"
            value={form.fullName}
            onChange={(e) => setForm({ ...form, fullName: e.target.value })}
          />
          <Input
            label="WhatsApp (opcional)"
            placeholder="5511999999999"
            value={form.whatsapp}
            onChange={(e) => setForm({ ...form, whatsapp: e.target.value })}
          />
        </div>

        {role === 'CLIENT' ? (
          <>
            <Select
              label="Plano"
              hint="define validade, conexoes e custo"
              value={planId}
              onChange={(e) => setPlanId(e.target.value)}
            >
              <option value="">Dias avulsos (1 credito por dia)</option>
              {plans.map((plan) => (
                <option key={plan.id} value={plan.id}>
                  {plan.name} — {plan.days}d · {plan.connectionLimit} con. · {plan.creditCost} cred.
                </option>
              ))}
            </Select>

            {!planId && (
              <div className="grid gap-3 sm:grid-cols-2">
                <Input
                  label="Dias de validade"
                  type="number"
                  min={1}
                  max={3650}
                  value={days}
                  onChange={(e) => setDays(e.target.value)}
                  required
                />
                <Input
                  label="Conexoes simultaneas"
                  type="number"
                  min={1}
                  max={50}
                  value={connectionLimit}
                  onChange={(e) => setConnectionLimit(e.target.value)}
                />
              </div>
            )}
          </>
        ) : (
          <Input
            label="Creditos iniciais"
            hint="sai do seu saldo"
            type="number"
            min={0}
            value={initialCredits}
            onChange={(e) => setInitialCredits(e.target.value)}
          />
        )}

        {insufficient && (
          <p className="rounded-xl border border-bad-500/40 bg-bad-500/10 px-3 py-2 text-xs text-red-200">
            Saldo insuficiente para esta operacao.
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
