# Ponte WebSocket -> SSH (fallback `wss://` do app móvel)

Última estratégia de conexão do app: SSH encapsulado dentro de um WebSocket
(`wss://<dominio>/tun`). Para a operadora, o tráfego é HTTPS comum até o
upgrade de protocolo — o fallback mais difícil de bloquear sem quebrar a
navegação HTTPS do aparelho.

```
app móvel                        VPS
  dartssh2                         Nginx (TLS real, certificado do domínio)
  WebSocketSSHSocket               |  location /tun (upgrade)
      │  wss://brasilnetpro.click/tun
      ▼                            ▼
   frames binários  ─────────►  ws-bridge (127.0.0.1:7301)
                                   │  TCP
                                   ▼
                                sshd (127.0.0.1:22)
```

O protocolo SSH não sabe que está dentro de um WebSocket — para ele é só um
socket qualquer. Cada frame binário recebido é escrito no socket TCP do sshd,
e vice-versa.

---

## Instalação (automática)

O `../install.sh` do agente já instala a ponte: cria o usuário `tunnel-ws`,
copia os arquivos para `/opt/tunnel-ws-bridge`, roda `npm install` e registra
o serviço `ws-bridge`. Depois do install.sh, só falta:

```bash
sudo systemctl start ws-bridge
journalctl -u tunnel-ws-bridge -f
```

## Instalação (manual)

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin tunnel-ws
sudo mkdir -p /opt/tunnel-ws-bridge
sudo cp -r src package.json /opt/tunnel-ws-bridge/
sudo cp .env.example /opt/tunnel-ws-bridge/.env
sudo chown -R tunnel-ws:tunnel-ws /opt/tunnel-ws-bridge
cd /opt/tunnel-ws-bridge && sudo -u tunnel-ws npm install --omit=dev
sudo cp ../systemd/ws-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ws-bridge
```

## Nginx (obrigatório — o bridge não faz TLS)

O bridge escuta **apenas** em `127.0.0.1:7301` e não fala TLS. Quem termina o
HTTPS e repassa o upgrade é o Nginx, no **mesmo server block do domínio**
(no app o URL é `wss://brasilnetpro.click/tun`, o domínio da API):

```nginx
location /tun {
    proxy_pass http://127.0.0.1:7301;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
}
```

Valide e recarregue:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

## Teste rápido

Da VPS ou de qualquer máquina:

```bash
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://brasilnetpro.click/tun
```

Resposta esperada: `HTTP/1.1 101 Switching Protocols`. `404`/`502` significa
que o `location` ou o serviço não estão configurados — o sintoma no app é o
fallback pendurar até o timeout de 20s da estratégia.

## Configuração

| Variável | Padrão | Para quê |
|---|---|---|
| `WS_BRIDGE_PORT` | `7301` | porta local do bridge (usada pelo `proxy_pass`) |
| `SSH_HOST` | `127.0.0.1` | host do sshd de destino |
| `SSH_PORT` | `22` | porta do sshd de destino |

## Segurança

- Escuta só em loopback — o firewall não precisa abrir porta nova.
- Qualquer path diferente de `/tun` é destruído **antes** do handshake WS
  (`server.on('upgrade')` no `index.js`).
- Só aceita frames binários; frames de texto são descartados.
- O usuário `tunnel-ws` não tem shell nem home, e o systemd unit endurece o
  resto (`NoNewPrivileges`, `ProtectSystem=strict`, famílias de socket
  limitadas a AF_UNIX/AF_INET/AF_INET6).
