import makeWASocket, {
  DisconnectReason,
  fetchLatestBaileysVersion,
  useMultiFileAuthState,
} from '@whiskeysockets/baileys';
import { Boom } from '@hapi/boom';
import qrcode from 'qrcode-terminal';
import pino from 'pino';

import { config } from './config.js';
import { handleMessage } from './flows/handler.js';
import { alreadyHandled } from './services/state.js';
import { startCallbackServer } from './server.js';

const logger = pino({ level: 'warn' });

let socket = null;
export const getSocket = () => socket;

/** Extrai texto de qualquer um dos formatos de mensagem do WhatsApp. */
function extractText(message) {
  const m = message.message;
  if (!m) return null;
  return (
    m.conversation ||
    m.extendedTextMessage?.text ||
    m.imageMessage?.caption ||
    m.videoMessage?.caption ||
    m.buttonsResponseMessage?.selectedDisplayText ||
    m.listResponseMessage?.title ||
    null
  );
}

async function connect() {
  const { state, saveCreds } = await useMultiFileAuthState(config.sessionPath);
  const { version } = await fetchLatestBaileysVersion();

  socket = makeWASocket({
    version,
    auth: state,
    logger,
    printQRInTerminal: false,
    browser: [config.companyName, 'Chrome', '1.0.0'],
    markOnlineOnConnect: false,
  });

  socket.ev.on('creds.update', saveCreds);

  socket.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      console.log('\nEscaneie o QR Code abaixo no WhatsApp > Aparelhos conectados:\n');
      qrcode.generate(qr, { small: true });
    }

    if (connection === 'open') {
      console.log('[bot] conectado ao WhatsApp.');
    }

    if (connection === 'close') {
      const status = new Boom(lastDisconnect?.error)?.output?.statusCode;
      const loggedOut = status === DisconnectReason.loggedOut;

      console.log(`[bot] conexao encerrada (${status}).`, loggedOut ? 'Sessao invalidada.' : 'Reconectando...');

      if (loggedOut) {
        console.log(`[bot] apague a pasta "${config.sessionPath}" e rode novamente para parear.`);
        process.exit(1);
      }
      setTimeout(connect, 3_000);
    }
  });

  socket.ev.on('messages.upsert', async ({ messages, type }) => {
    if (type !== 'notify') return;

    for (const message of messages) {
      const jid = message.key.remoteJid;

      // Ignora: mensagens proprias, grupos, status e broadcasts.
      if (message.key.fromMe) continue;
      if (!jid || jid.endsWith('@g.us') || jid === 'status@broadcast') continue;
      if (alreadyHandled(message.key.id)) continue;

      const text = extractText(message);
      if (!text) continue;

      console.log(`[msg] ${jid}: ${text}`);

      try {
        await socket.readMessages([message.key]);
        await handleMessage(socket, jid, text);
      } catch (err) {
        console.error('[bot] erro ao tratar mensagem:', err);
        await socket
          .sendMessage(jid, { text: 'Tive um problema aqui. Digite *menu* para tentar de novo.' })
          .catch(() => {});
      }
    }
  });
}

startCallbackServer(getSocket);
connect().catch((err) => {
  console.error('[bot] falha ao iniciar:', err);
  process.exit(1);
});
