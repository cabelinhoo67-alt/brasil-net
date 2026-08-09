#!/usr/bin/env bash
#
# Instalador do agente na VPS (Debian 11+ / Ubuntu 20.04+).
#
#   curl -fsSL .../install.sh | bash
#   ou: bash install.sh
#
set -euo pipefail

INSTALL_DIR="/opt/tunnel-agent"
GROUP="${TUNNEL_GROUP:-tunnel}"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
fail()  { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "rode como root (sudo bash install.sh)"

# ---------------------------------------------------------------- dependencias
info "verificando dependencias"

if ! command -v node >/dev/null 2>&1; then
  info "instalando Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 20 ] || fail "Node 20+ necessario (encontrado: $(node -v))"

# ---------------------------------------------------------------------- grupo
if ! getent group "$GROUP" >/dev/null; then
  info "criando grupo $GROUP"
  groupadd --system "$GROUP"
else
  info "grupo $GROUP ja existe"
fi

# ------------------------------------------------------------------ pam_limits
# Sem isto o maxlogins por usuario nao e aplicado pelo sshd.
if ! grep -qE '^\s*session\s+required\s+pam_limits\.so' /etc/pam.d/sshd; then
  info "habilitando pam_limits em /etc/pam.d/sshd"
  cp /etc/pam.d/sshd "/etc/pam.d/sshd.bak.$(date +%s)"
  echo 'session    required     pam_limits.so' >> /etc/pam.d/sshd
  RESTART_SSH=1
else
  info "pam_limits ja ativo"
fi

# ---------------------------------------------------------------------- sshd
SSHD_CONF="/etc/ssh/sshd_config.d/99-tunnel.conf"
if [ ! -f "$SSHD_CONF" ]; then
  info "escrevendo $SSHD_CONF"
  mkdir -p /etc/ssh/sshd_config.d
  cat > "$SSHD_CONF" <<EOF
# Gerado pelo tunnel-agent — ajuste conforme sua politica.

# Os clientes autenticam com usuario e senha vindos do painel.
PasswordAuthentication yes
UsePAM yes

# Encaminhamento de portas e o que o tunel usa (canal direct-tcpip).
AllowTcpForwarding yes

# Nada alem do tunel: sem shell, sem X11, sem agente, sem SFTP.
PermitTTY no
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no

# Derruba sessao morta e libera o slot de maxlogins.
ClientAliveInterval 30
ClientAliveCountMax 3

# Muitos clientes conectando ao mesmo tempo nao podem ser tratados como ataque.
MaxStartups 100:30:600
MaxSessions 20
EOF
  RESTART_SSH=1
else
  info "$SSHD_CONF ja existe, mantendo"
fi

if sshd -t 2>/dev/null; then
  if [ "${RESTART_SSH:-0}" = "1" ]; then
    info "recarregando sshd"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
  fi
else
  warn "sshd -t reprovou a configuracao; NAO recarreguei o servico"
  warn "revise $SSHD_CONF antes de continuar"
fi

# ------------------------------------------------------------------- arquivos
info "instalando em $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -r "$SCRIPT_DIR/src" "$SCRIPT_DIR/package.json" "$INSTALL_DIR/"

if [ ! -f "$INSTALL_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  warn "edite $INSTALL_DIR/.env e preencha API_URL e AGENT_TOKEN"
fi

cd "$INSTALL_DIR"
npm install --omit=dev --no-audit --no-fund

# -------------------------------------------------------------------- systemd
info "registrando o servico"
cp "$SCRIPT_DIR/systemd/tunnel-agent.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable tunnel-agent

cat <<EOF

  Instalado.

  1. Edite as credenciais:
       nano $INSTALL_DIR/.env

  2. Teste sem alterar nada:
       cd $INSTALL_DIR && DRY_RUN=true node src/index.js

  3. Suba o servico:
       systemctl start tunnel-agent
       journalctl -u tunnel-agent -f

EOF
