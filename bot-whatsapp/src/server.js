import express from 'express';
import { config } from './config.js';
import * as msg from './flows/messages.js';
import { clearState } from './services/state.js';
import { stopWatching } from './flows/handler.js';

/**
 * Servidor HTTP interno: recebe do backend o aviso de "Pix confirmado"
 * e entrega as credenciais no chat do cliente.
 */
export function startCallbackServer(getSocket) {
  const app = express();
  app.use(express.json());

  app.get('/health', (_req, res) => res.json({ ok: true, connected: Boolean(getSocket()) }));

  app.post('/internal/order-paid', async (req, res) => {
    if (req.headers['x-internal-key'] !== config.internalKey) {
      return res.status(403).json({ error: 'chave interna invalida' });
    }

    const { whatsapp, credentials, plan, orderId } = req.body || {};
    if (!whatsapp || !credentials) {
      return res.status(400).json({ error: 'payload incompleto' });
    }

    const sock = getSocket();
    if (!sock) return res.status(503).json({ error: 'bot desconectado do WhatsApp' });

    try {
      const jid = whatsapp.includes('@') ? whatsapp : `${whatsapp.replace(/\D/g, '')}@s.whatsapp.net`;
      await sock.sendMessage(jid, { text: msg.credentials({ credentials, plan }) });

      if (orderId) stopWatching(orderId);
      clearState(jid);

      console.log(`[callback] credenciais entregues para ${jid} (pedido ${orderId})`);
      res.json({ delivered: true });
    } catch (err) {
      console.error('[callback] falha ao enviar mensagem:', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  app.listen(config.port, () => {
    console.log(`[bot] callback HTTP em http://localhost:${config.port}`);
  });
}
