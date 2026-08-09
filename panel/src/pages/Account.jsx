import { useState } from 'react';
import { api } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { ROLE_LABEL } from '../lib/roles';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import { Input } from '../components/ui/Field';

export default function Account() {
  const { user, logout } = useAuth();
  const toast = useToast();

  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [confirm, setConfirm] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function onSubmit(event) {
    event.preventDefault();

    if (next !== confirm) {
      setError('A confirmacao nao confere com a nova senha.');
      return;
    }

    setSaving(true);
    setError(null);

    try {
      await api.auth.changePassword(current, next);
      toast.success('Senha alterada. Entre novamente.');
      setTimeout(logout, 1200);
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <PageHeader title="Minha conta" description="Dados de acesso ao painel." />

      <div className="grid gap-4 lg:grid-cols-2">
        <section className="card p-5">
          <h2 className="mb-4 text-sm font-semibold text-white">Perfil</h2>

          <dl className="divide-y divide-white/[0.05]">
            {[
              ['Usuario', user.username],
              ['Nivel', ROLE_LABEL[user.role]],
              ['Nome', user.fullName || '--'],
              ['WhatsApp', user.whatsapp || '--'],
              ['Creditos', user.credits === null ? 'ilimitado' : user.credits],
              ['Cadastros diretos', user.stats?.directChildren ?? 0],
              ['Clientes diretos', user.stats?.clients ?? 0],
            ].map(([label, value]) => (
              <div key={label} className="flex items-center justify-between gap-4 py-2.5">
                <dt className="text-xs text-ash-400">{label}</dt>
                <dd className="text-sm text-zinc-200">{value}</dd>
              </div>
            ))}
          </dl>
        </section>

        <section className="card p-5">
          <h2 className="mb-1 text-sm font-semibold text-white">Trocar senha</h2>
          <p className="mb-4 text-xs text-ash-400">
            Voce sera desconectado depois da troca.
          </p>

          <form onSubmit={onSubmit} className="space-y-3">
            <Input
              label="Senha atual"
              type="password"
              autoComplete="current-password"
              value={current}
              onChange={(e) => setCurrent(e.target.value)}
              required
            />
            <Input
              label="Nova senha"
              hint="minimo 6 caracteres"
              type="password"
              autoComplete="new-password"
              minLength={6}
              value={next}
              onChange={(e) => setNext(e.target.value)}
              required
            />
            <Input
              label="Confirme a nova senha"
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              required
            />

            {error && (
              <p className="rounded-xl border border-bad-500/40 bg-bad-500/10 px-3 py-2 text-xs text-red-200">
                {error}
              </p>
            )}

            <Button type="submit" loading={saving} className="w-full">
              Alterar senha
            </Button>
          </form>
        </section>
      </div>
    </>
  );
}
