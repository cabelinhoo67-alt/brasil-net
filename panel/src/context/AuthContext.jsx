import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { api, subscribeUnauthorized, tokenStore } from '../lib/api';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [booting, setBooting] = useState(true);

  const logout = useCallback(() => {
    tokenStore.clear();
    setUser(null);
  }, []);

  // Token vencido em qualquer chamada derruba a sessao do painel.
  useEffect(() => subscribeUnauthorized(logout), [logout]);

  // Revalida o token guardado no localStorage ao abrir o painel.
  useEffect(() => {
    let alive = true;

    (async () => {
      if (!tokenStore.get()) {
        setBooting(false);
        return;
      }
      try {
        const me = await api.auth.me();
        if (alive) setUser(me);
      } catch {
        tokenStore.clear();
      } finally {
        if (alive) setBooting(false);
      }
    })();

    return () => {
      alive = false;
    };
  }, []);

  const login = useCallback(async (username, password) => {
    const data = await api.auth.login(username, password);
    tokenStore.set(data.token);
    // O /me traz os contadores da rede que o login nao devolve.
    setUser(await api.auth.me());
  }, []);

  /** Recarrega saldo e contadores apos operacoes que mexem em credito. */
  const refresh = useCallback(async () => {
    try {
      setUser(await api.auth.me());
    } catch {
      // silencioso: a proxima navegacao tenta de novo
    }
  }, []);

  return (
    <AuthContext.Provider value={{ user, booting, login, logout, refresh }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error('useAuth precisa estar dentro de <AuthProvider>');
  return context;
}
