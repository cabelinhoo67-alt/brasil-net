import { createServer } from 'node:http';
import { connect as connectTcp } from 'node:net';
import { WebSocketServer } from 'ws';

/**
 * Ponte WebSocket <-> TCP para o sshd local.
 *
 * Fica atras do Nginx, que ja termina TLS com o certificado real do dominio
 * e repassa o upgrade de protocolo para ca (location /tun). Do ponto de vista
 * da operadora, o trafego e HTTPS comum ate o momento do upgrade — o payload
 * mais dificil de bloquear sem quebrar navegacao HTTPS normal do aparelho.
 *
 * Cada frame binario recebido do WebSocket vira bytes crus escritos no socket
 * TCP do sshd, e vice-versa. O protocolo SSH em si nao sabe que esta rodando
 * dentro de um WebSocket — para ele e so um socket qualquer.
 */

const PORT = Number(process.env.WS_BRIDGE_PORT || 7301);
const SSH_HOST = process.env.SSH_HOST || '127.0.0.1';
const SSH_PORT = Number(process.env.SSH_PORT || 22);

const server = createServer((req, res) => {
  // Nao serve HTTP normal — so responde ao handshake de upgrade.
  res.writeHead(404).end();
});

const wss = new WebSocketServer({ server, path: '/tun' });

wss.on('connection', (ws, req) => {
  const remote = req.socket.remoteAddress;
  log(`nova conexao de ${remote}`);

  const tcp = connectTcp(SSH_PORT, SSH_HOST);
  tcp.setNoDelay(true);

  let closed = false;
  const shutdown = (reason) => {
    if (closed) return;
    closed = true;
    log(`encerrando (${reason})`);
    try {
      tcp.destroy();
    } catch {
      /* ja fechado */
    }
    try {
      ws.close();
    } catch {
      /* ja fechado */
    }
  };

  // WebSocket -> TCP (sshd)
  ws.on('message', (data, isBinary) => {
    if (!isBinary) return; // texto nunca deveria chegar; ignora sem quebrar
    if (tcp.writable) tcp.write(data);
  });
  ws.on('close', () => shutdown('websocket fechado'));
  ws.on('error', (err) => shutdown(`erro no websocket: ${err.message}`));

  // TCP (sshd) -> WebSocket
  tcp.on('connect', () => log('conectado ao sshd local'));
  tcp.on('data', (chunk) => {
    if (ws.readyState === ws.OPEN) ws.send(chunk, { binary: true });
  });
  tcp.on('close', () => shutdown('sshd encerrou'));
  tcp.on('error', (err) => shutdown(`erro no tcp: ${err.message}`));
});

server.on('upgrade', (req, socket) => {
  // Qualquer path diferente de /tun e recusado antes mesmo do handshake WS —
  // reduz a superficie exposta a scanners.
  if (!req.url?.startsWith('/tun')) {
    socket.destroy();
  }
});

function log(message) {
  console.log(`${new Date().toISOString()} [ws-bridge] ${message}`);
}

server.listen(PORT, '127.0.0.1', () => {
  log(`escutando em 127.0.0.1:${PORT}, repassando para ${SSH_HOST}:${SSH_PORT}`);
});

process.on('SIGTERM', () => {
  log('SIGTERM recebido, encerrando');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
});
