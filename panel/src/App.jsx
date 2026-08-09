import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './context/AuthContext';
import { can } from './lib/roles';
import Layout from './components/Layout';
import { Spinner } from './components/ui/Feedback';

import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import UsersPage from './pages/UsersPage';
import Credits from './pages/Credits';
import Operators from './pages/Operators';
import Payloads from './pages/Payloads';
import Servers from './pages/Servers';
import Plans from './pages/Plans';
import AppVersion from './pages/AppVersion';
import Orders from './pages/Orders';
import Account from './pages/Account';

/**
 * Rota que exige um papel especifico.
 * Um revendedor que digitar /planos na barra de endereco cai no painel —
 * e mesmo que forcasse, o backend recusaria a chamada.
 */
function RequireRole({ allowed, children }) {
  const { user } = useAuth();
  return allowed(user.role) ? children : <Navigate to="/" replace />;
}

export default function App() {
  const { user, booting } = useAuth();

  if (booting) {
    return (
      <div className="grid min-h-dvh place-items-center">
        <Spinner className="size-8" />
      </div>
    );
  }

  if (!user) return <Login />;

  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Dashboard />} />

        <Route
          path="clientes"
          element={
            <UsersPage
              role="CLIENT"
              title="Clientes"
              description="Acessos usados no aplicativo."
            />
          }
        />

        <Route
          path="revendedores"
          element={
            <RequireRole allowed={can.manageResellers}>
              <UsersPage
                role="RESELLER"
                title="Revendedores"
                description="Sua rede de revenda e o saldo de cada um."
              />
            </RequireRole>
          }
        />

        <Route path="creditos" element={<Credits />} />

        <Route
          path="operadoras"
          element={
            <RequireRole allowed={can.manageInfra}>
              <Operators />
            </RequireRole>
          }
        />
        <Route
          path="payloads"
          element={
            <RequireRole allowed={can.manageInfra}>
              <Payloads />
            </RequireRole>
          }
        />
        <Route
          path="servidores"
          element={
            <RequireRole allowed={can.manageInfra}>
              <Servers />
            </RequireRole>
          }
        />
        <Route
          path="planos"
          element={
            <RequireRole allowed={can.managePlans}>
              <Plans />
            </RequireRole>
          }
        />
        <Route
          path="vendas"
          element={
            <RequireRole allowed={can.viewOrders}>
              <Orders />
            </RequireRole>
          }
        />
        <Route
          path="versao-app"
          element={
            <RequireRole allowed={can.managePlans}>
              <AppVersion />
            </RequireRole>
          }
        />

        <Route path="conta" element={<Account />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
