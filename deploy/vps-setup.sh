#!/usr/bin/env bash
#
# Deploy completo do backend + painel numa VPS limpa (Debian 11+ / Ubuntu 20.04+).
#
# Rode como root:
#   bash vps-setup.sh
#
# Idempotente: rodar de novo atualiza o codigo e reinicia os servicos sem
# recriar o banco nem perder dados.
#
set -euo pipefail

# --------------------------------------------------------------- parametros
REPO="${REPO:-https://github.com/cabelinhoo67-alt/brasil-net.git}"
APP_DIR="${APP_DIR:-/opt/tunnel-system}"
PUBLIC_IP="${PUBLIC_IP:-$(curl -s -m 10 ifconfig.me || echo '187.77.37.249')}"
API_PORT="${API_PORT:-3333}"
PANEL_PORT="${PANEL_PORT:-8080}"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "rode como root"

info "Deploy em $PUBLIC_IP — API :$API_PORT, painel :$PANEL_PORT"

# ------------------------------------------------------------ dependencias
info "Instalando dependencias do sistema"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git ca-certificates ufw >/dev/null

if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 20 ]; then
  info "Instalando Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
node -v

if ! command -v docker >/dev/null 2>&1; then
  info "Instalando Docker"
  curl -fsSL https://get.docker.com | sh >/dev/null
fi

command -v pm2 >/dev/null 2>&1 || { info "Instalando PM2"; npm install -g pm2 --silent; }

# ------------------------------------------------------------------ codigo
# Tres cenarios, nesta ordem:
#   1. OFFLINE=1 ou codigo ja presente sem .git  -> usa o que esta no disco
#      (util quando o repo for privado ou a VPS nao tiver saida para o GitHub)
#   2. repositorio git ja clonado                -> atualiza
#   3. nada                                      -> clona
if [ "${OFFLINE:-0}" = "1" ] || { [ -f "$APP_DIR/backend/package.json" ] && [ ! -d "$APP_DIR/.git" ]; }; then
  [ -f "$APP_DIR/backend/package.json" ] \
    || fail "OFFLINE=1 mas $APP_DIR/backend/package.json nao existe — envie o codigo primeiro"
  info "Modo offline: usando o codigo ja presente em $APP_DIR"
elif [ -d "$APP_DIR/.git" ]; then
  info "Atualizando codigo em $APP_DIR"
  git -C "$APP_DIR" fetch --all -q
  git -C "$APP_DIR" reset --hard origin/main -q
else
  info "Clonando $REPO"
  rm -rf "$APP_DIR"
  git clone -q "$REPO" "$APP_DIR"
fi
cd "$APP_DIR"

# ------------------------------------------------------------------ .env
# Segredos sao gerados uma unica vez e preservados entre execucoes: regerar
# invalidaria os tokens ativos e o token do agente da VPS.
ENV_FILE="$APP_DIR/backend/.env"

if [ -f "$ENV_FILE" ]; then
  info "Reaproveitando segredos de $ENV_FILE"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  POSTGRES_PASSWORD="$(sed -n 's|.*postgresql://tunnel:\([^@]*\)@.*|\1|p' <<<"$DATABASE_URL")"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
else
  info "Gerando segredos novos"
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  JWT_SECRET="$(openssl rand -hex 48)"
  INTERNAL_API_KEY="$(openssl rand -hex 32)"
  ADMIN_PASSWORD="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"

  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=$API_PORT

DATABASE_URL="postgresql://tunnel:${POSTGRES_PASSWORD}@localhost:5432/tunneldb?schema=public"

JWT_SECRET="${JWT_SECRET}"
JWT_PANEL_EXPIRES=8h
JWT_APP_EXPIRES=7d

INTERNAL_API_KEY="${INTERNAL_API_KEY}"

# Preencha com a credencial de producao do Mercado Pago para ativar o Pix.
MP_ACCESS_TOKEN=""
PIX_EXPIRATION_MINUTES=30

BOT_CALLBACK_URL="http://localhost:3334/internal/order-paid"
SESSION_TIMEOUT_SECONDS=120

ADMIN_USERNAME=admin
ADMIN_PASSWORD="${ADMIN_PASSWORD}"
EOF
  chmod 600 "$ENV_FILE"
fi

# ------------------------------------------------------------------- banco
info "Subindo o PostgreSQL"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose \
  -f "$APP_DIR/deploy/docker-compose.prod.yml" up -d

printf 'aguardando o banco'
for _ in $(seq 1 30); do
  if docker exec tunnel-postgres pg_isready -U tunnel -d tunneldb >/dev/null 2>&1; then
    echo " ok"; break
  fi
  printf '.'; sleep 2
done
docker exec tunnel-postgres pg_isready -U tunnel -d tunneldb >/dev/null 2>&1 \
  || fail "o PostgreSQL nao subiu; veja: docker logs tunnel-postgres"

# ----------------------------------------------------------------- backend
info "Instalando o backend"
cd "$APP_DIR/backend"
npm ci --omit=dev --no-audit --no-fund --silent
npx prisma generate >/dev/null

info "Aplicando migracoes"
npx prisma migrate deploy

# O seed e idempotente (upsert): nao duplica nem sobrescreve o que ja existe.
info "Populando dados iniciais"
node prisma/seed.js || warn "seed falhou — pode ja estar populado"

# ------------------------------------------------------------------ painel
info "Compilando o painel (API em http://$PUBLIC_IP:$API_PORT)"
cd "$APP_DIR/panel"
npm ci --no-audit --no-fund --silent
VITE_API_URL="http://$PUBLIC_IP:$API_PORT" npm run build

# ------------------------------------------------------------------- pm2
info "Registrando os servicos no PM2"
cd "$APP_DIR"
pm2 delete tunnel-api tunnel-panel >/dev/null 2>&1 || true
pm2 start "$APP_DIR/backend/src/server.js" --name tunnel-api --cwd "$APP_DIR/backend"
pm2 serve "$APP_DIR/panel/dist" "$PANEL_PORT" --name tunnel-panel --spa
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true

# -------------------------------------------------------------------- ufw
# A regra do SSH vem ANTES do enable. Habilitar o ufw sem ela derruba a sua
# propria sessao e tranca voce para fora da VPS.
info "Configurando o firewall"
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw allow "${API_PORT}/tcp" >/dev/null
ufw allow "${PANEL_PORT}/tcp" >/dev/null
ufw --force enable >/dev/null
ufw status numbered | head -12

# -------------------------------------------------------------- validacao
info "Validando"
sleep 3
if curl -fsS -m 10 "http://localhost:$API_PORT/health" >/dev/null; then
  echo "  API local respondendo"
else
  pm2 logs tunnel-api --lines 30 --nostream
  fail "a API nao respondeu localmente"
fi

curl -fsS -m 10 "http://localhost:$PANEL_PORT" >/dev/null \
  && echo "  painel respondendo" || warn "painel nao respondeu na porta $PANEL_PORT"

cat <<EOF

────────────────────────────────────────────────────────────
 Deploy concluido

   API      http://$PUBLIC_IP:$API_PORT/health
   Painel   http://$PUBLIC_IP:$PANEL_PORT

$(if [ -n "${ADMIN_PASSWORD:-}" ]; then
echo "   Admin    admin / $ADMIN_PASSWORD"
echo "            (anote: so aparece nesta primeira execucao)"
else
echo "   Admin    credenciais preservadas de $ENV_FILE"
fi)

 Comandos uteis:
   pm2 status
   pm2 logs tunnel-api
   pm2 restart tunnel-api

 Se as portas nao abrirem de fora, o bloqueio esta no painel do
 provedor da VPS (firewall externo), nao no ufw.
────────────────────────────────────────────────────────────
EOF
