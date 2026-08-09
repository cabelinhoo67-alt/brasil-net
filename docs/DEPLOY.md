# Deploy em VPS

Guia enxuto para colocar o backend e o bot em produção (Ubuntu 22.04+).

## 1. Dependências

```bash
sudo apt update && sudo apt install -y curl git nginx
```

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs
```

```bash
sudo npm install -g pm2
```

PostgreSQL — via Docker (mais simples de manter):

```bash
curl -fsSL https://get.docker.com | sudo sh
```

## 2. Código e ambiente

```bash
git clone <seu-repo> /opt/tunnel && cd /opt/tunnel
```

```bash
docker compose up -d postgres
```

```bash
cd backend && npm ci && cp .env.example .env
```

No `.env` de produção, obrigatoriamente:

- `NODE_ENV=production`
- `JWT_SECRET` e `INTERNAL_API_KEY` gerados aleatoriamente:
  ```bash
  node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"
  ```
- `MP_ACCESS_TOKEN` com a credencial **de produção**
- `BOT_CALLBACK_URL=http://localhost:3334/internal/order-paid`

```bash
npx prisma migrate deploy && npm run db:seed
```

Use `migrate deploy` (não `migrate dev`) em produção: ele aplica migrações existentes
sem tentar gerar novas nem resetar dados.

## 3. Processos

```bash
cd /opt/tunnel/backend && pm2 start src/server.js --name tunnel-api
```

```bash
cd /opt/tunnel/bot-whatsapp && npm ci && pm2 start src/index.js --name tunnel-bot
```

```bash
pm2 save && pm2 startup
```

O pareamento do WhatsApp exige ver o QR uma vez:

```bash
pm2 logs tunnel-bot
```

## 4. Nginx + SSL

```nginx
server {
    server_name api.seudominio.com.br;

    location / {
        proxy_pass http://127.0.0.1:3333;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

O backend já usa `trust proxy`, então o `req.ip` registrado nas sessões é o IP real do
cliente, não o do Nginx.

```bash
sudo ln -s /etc/nginx/sites-available/tunnel /etc/nginx/sites-enabled/ && sudo nginx -t && sudo systemctl reload nginx
```

```bash
sudo apt install -y certbot python3-certbot-nginx && sudo certbot --nginx -d api.seudominio.com.br
```

## 5. Webhook do Mercado Pago

No painel do Mercado Pago, tópico *Pagamentos*:

```
https://api.seudominio.com.br/api/payments/webhook/mercadopago
```

Teste com uma compra real de valor baixo e acompanhe:

```bash
pm2 logs tunnel-api
```

Deve aparecer `[webhook] pedido <uuid> pago -> usuario <login> criado`.

## 6. Firewall

```bash
sudo ufw allow OpenSSH && sudo ufw allow 'Nginx Full' && sudo ufw enable
```

A porta 5432 **não** deve ficar exposta. Se o Postgres estiver no Docker no mesmo
host, publique-o apenas em `127.0.0.1:5432:5432` no `docker-compose.yml`.

## 7. Build do APK

No seu PC:

```bash
cd mobile && flutter build apk --release --dart-define=API_URL=https://api.seudominio.com.br
```

Saída em `build/app/outputs/flutter-apk/app-release.apk`.

Para publicar na Play Store, gere um keystore e configure `android/key.properties` —
sem assinatura própria o APK só serve para distribuição direta.

## 8. Backup

```bash
docker exec tunnel-postgres pg_dump -U tunnel tunneldb > /opt/backups/tunneldb-$(date +%F).sql
```

Coloque no cron diário. Guarde também a pasta `bot-whatsapp/auth_session/`: perdê-la
significa parear o WhatsApp de novo.

```cron
0 3 * * * docker exec tunnel-postgres pg_dump -U tunnel tunneldb > /opt/backups/tunneldb-$(date +\%F).sql
```

## Checklist antes de abrir para clientes

- [ ] senha do `admin` trocada
- [ ] `JWT_SECRET` e `INTERNAL_API_KEY` aleatórios (não os do `.env.example`)
- [ ] HTTPS ativo e webhook respondendo
- [ ] backup automático rodando e **restaurado uma vez** para teste
- [ ] `NODE_ENV=production` (esconde stack traces nas respostas de erro)
- [ ] porta do Postgres fechada para a internet
