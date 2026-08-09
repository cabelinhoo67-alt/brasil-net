import { useState } from 'react';
import { useAuth } from '../context/AuthContext';
import Button from '../components/ui/Button';
import { Input } from '../components/ui/Field';

export default function Login() {
  const { login } = useAuth();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(event) {
    event.preventDefault();
    setLoading(true);
    setError(null);

    try {
      await login(username, password);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="relative flex min-h-dvh items-center justify-center overflow-hidden px-4">
      {/* Chama negra: brasa saturada no centro, dissolvendo no preto. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute left-1/2 top-1/2 size-[680px] -translate-x-1/2 -translate-y-1/2 rounded-full opacity-70 blur-3xl"
        style={{
          background:
            'radial-gradient(circle, rgba(230,33,43,0.22) 0%, rgba(143,11,22,0.10) 42%, transparent 68%)',
        }}
      />

      <div className="relative w-full max-w-sm">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-4 grid size-16 place-items-center rounded-2xl border border-ember-500/40 bg-gradient-to-b from-ember-600/25 to-transparent shadow-[0_0_40px_-10px_rgba(230,33,43,0.9)]">
            <span className="text-3xl leading-none">🔥</span>
          </div>
          <h1 className="text-2xl font-black tracking-[0.2em] text-white">AMATERASU</h1>
          <p className="mt-1 text-[11px] uppercase tracking-[0.3em] text-ember-500">
            Painel de revenda
          </p>
        </div>

        <form onSubmit={onSubmit} className="card-ember space-y-4 p-6">
          <Input
            label="Usuario"
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="seu usuario"
            required
          />

          <Input
            label="Senha"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="••••••••"
            required
          />

          {error && (
            <p className="rounded-xl border border-bad-500/40 bg-bad-500/10 px-3 py-2 text-xs text-red-200">
              {error}
            </p>
          )}

          <Button type="submit" size="lg" loading={loading} className="w-full">
            ENTRAR
          </Button>
        </form>

        <p className="mt-6 text-center text-[11px] text-ash-400">
          Cliente final acessa pelo aplicativo, nao por aqui.
        </p>
      </div>
    </div>
  );
}
