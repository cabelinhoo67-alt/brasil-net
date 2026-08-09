# Referência da API

Base: `http://localhost:3333`

Três escopos de autenticação, propositalmente separados:

| Escopo | Header | Quem usa |
|---|---|---|
| `panel` | `Authorization: Bearer <token>` | painel web (admin, master, revendedor) |
| `app` | `Authorization: Bearer <token>` | aplicativo Flutter (cliente final) |
| interno | `x-internal-key: <INTERNAL_API_KEY>` | bot do WhatsApp |

Um token de painel **não** abre rotas do app e vice-versa (`WRONG_SCOPE`).

## Formato de erro

```json
{ "error": true, "code": "INSUFFICIENT_CREDITS", "message": "Creditos insuficientes..." }
```

Códigos que o app trata de forma especial: `EXPIRED`, `USER_DISABLED`,
`CONNECTION_LIMIT`, `SESSION_CLOSED`, `BAD_CREDENTIALS`.

---

## Autenticação do painel

### `POST /api/auth/login`

```json
{ "username": "revenda1", "password": "revenda123" }
```

```json
{
  "token": "eyJhbGciOi...",
  "user": { "id": "uuid", "username": "revenda1", "role": "RESELLER", "credits": 50 }
}
```

Cliente final recebe `403 PANEL_DENIED` — ele entra apenas pelo app.

### `GET /api/auth/me`
### `PATCH /api/auth/password` — `{ currentPassword, newPassword }`

---

## Usuários (rede em cascata)

Todas exigem escopo `panel`. Cada nível só enxerga a própria descendência.

### `GET /api/users`

Query: `page`, `perPage`, `role`, `parentId`, `search`, `status` (`active` | `expired`).

```json
{
  "items": [
    {
      "id": "uuid", "username": "cliente01", "role": "CLIENT",
      "expiresAt": "2026-09-07T12:00:00.000Z", "daysLeft": 30, "expired": false,
      "connectionLimit": 1, "plan": { "name": "Mensal 1 conexao" }
    }
  ],
  "meta": { "page": 1, "perPage": 20, "total": 1, "totalPages": 1 }
}
```

### `POST /api/users`

Cliente final (debita o `creditCost` do plano):

```json
{ "username": "cliente01", "password": "senha123", "role": "CLIENT", "planId": "uuid" }
```

Ou sem plano, cobrando 1 crédito por dia:

```json
{ "username": "cliente01", "password": "senha123", "role": "CLIENT", "days": 30, "connectionLimit": 2 }
```

Revendedor (o `initialCredits` sai do saldo de quem cria):

```json
{ "username": "revenda2", "password": "senha123", "role": "RESELLER", "initialCredits": 20 }
```

Regras: `ADMIN` cria MASTER/RESELLER/CLIENT · `MASTER` cria RESELLER/CLIENT ·
`RESELLER` cria só CLIENT. Violação retorna `403 ROLE_NOT_ALLOWED`.

### `POST /api/users/:id/renew` — `{ planId }` ou `{ days }`

Se ainda não expirou, os dias são **somados** ao saldo restante. Se já expirou, contam a
partir de agora. Desbloqueia a conta automaticamente.

### `PATCH /api/users/:id`

`fullName`, `whatsapp`, `note`, `password`, `connectionLimit`, `isActive`, `isBlocked`.
Trocar a senha ou bloquear **derruba as sessões ativas** na hora.

### `DELETE /api/users/:id`

Recusa se o usuário tiver rede abaixo (`409 HAS_CHILDREN`). O saldo não usado volta para o upline.

### `GET /api/users/:id/sessions` · `DELETE /api/users/:id/sessions`

Lista ou derruba as conexões ativas do cliente.

---

## Créditos

### `POST /api/credits/transfer` — `{ toUserId, amount, description? }`

Move saldo para um downline. Quando o ADMIN transfere, emite crédito novo (`kind: ADD`)
em vez de debitar o próprio saldo.

### `POST /api/credits/withdraw` — `{ fromUserId, amount }`
### `GET /api/credits/history` — extrato paginado
### `GET /api/credits/balance`

---

## Planos, servidores, operadoras e payloads

| Rota | Quem acessa |
|---|---|
| `GET /api/plans` | qualquer nível do painel |
| `POST/PATCH/DELETE /api/plans/:id` | ADMIN |
| `GET/POST/PATCH /api/servers` | ADMIN, MASTER |
| `GET/POST/PATCH /api/payloads/operators` | ADMIN, MASTER |
| `GET/POST/PATCH/DELETE /api/payloads` | ADMIN, MASTER |
| `POST /api/payloads/:id/duplicate` | ADMIN, MASTER — clona para outra operadora |

Corpo de um payload:

```json
{
  "name": "Vivo - SSH/SSL",
  "operatorId": "uuid",
  "serverId": "uuid",
  "mode": "SSH_SSL",
  "content": "CONNECT [host_port] [protocol][crlf]Host: [host][crlf][crlf]",
  "sni": "www.vivo.com.br",
  "isActive": true,
  "sortOrder": 1
}
```

`mode`: `SSH_DIRECT` · `SSH_PAYLOAD` · `SSH_SSL` · `V2RAY` · `SLOWDNS` · `UDP`.

---

## API do aplicativo

### `POST /api/app/login`

```json
{
  "username": "teste",
  "password": "teste123",
  "deviceId": "id-estavel-do-aparelho",
  "deviceName": "Samsung SM-A155M",
  "appVersion": "1.0.0",
  "sim": { "operatorName": "Claro BR", "mccMnc": "72405" }
}
```

```json
{
  "token": "eyJ...",
  "user": { "username": "teste", "daysLeft": 30, "connectionLimit": 1 },
  "operator": { "code": "CLARO", "name": "Claro", "detected": true },
  "payloads": [
    {
      "id": "uuid", "name": "Claro - SSH/SSL", "mode": "SSH_SSL",
      "content": "CONNECT [host_port]...", "sni": "www.claro.com.br",
      "server": { "host": "br01.seudominio.com.br", "sshPort": 22, "sslPort": 443 }
    }
  ]
}
```

`payloads` traz **somente** a operadora detectada. Chip não reconhecido →
`"detected": false` e lista vazia.

Erros: `401 BAD_CREDENTIALS` · `403 EXPIRED` · `403 USER_DISABLED` ·
`403 NOT_A_CLIENT` · `409 CONNECTION_LIMIT`.

### `GET /api/app/config?operatorName=Claro&mccMnc=72405`

Recarrega a configuração sem refazer login (usado ao trocar de chip e no *pull to refresh*).

### `POST /api/app/session/heartbeat`

Chamar a cada 30 segundos.

```json
{ "ok": true, "daysLeft": 29, "activeSessions": 1, "connectionLimit": 1 }
```

Se a conta venceu, foi bloqueada ou a sessão foi derrubada, responde `403`/`409` com
`"disconnect": true` — o app deve encerrar o túnel imediatamente.

### `POST /api/app/session/close` — desconexão limpa, libera o slot na hora
### `GET /api/app/ping` — sem autenticação, usado para medir latência

---

## Pagamentos

### `POST /api/payments/internal/pix` *(header `x-internal-key`)*

```json
{ "whatsapp": "5511999999999@s.whatsapp.net", "planId": "uuid" }
```

```json
{
  "orderId": "uuid",
  "amountCents": 2500,
  "pix": { "copyPaste": "00020126...", "qrBase64": "iVBORw0...", "expiresAt": "..." }
}
```

### `GET /api/payments/internal/plans` — catálogo público do menu do bot
### `GET /api/payments/internal/orders/:id`

Status do pedido. Se ainda estiver `PENDING`, consulta o Mercado Pago sob demanda e
provisiona na hora se já tiver sido aprovado — é o fallback que faz o sistema funcionar
sem webhook público.

### `POST /api/payments/webhook/mercadopago`

Recebe a notificação do gateway. Responde `200` imediatamente e processa em seguida:
valida o pagamento, cria o cliente com a validade do plano e chama o `BOT_CALLBACK_URL`.
Idempotente — pedido já pago é ignorado.

### `GET /api/payments/orders` *(painel, ADMIN/MASTER)*

Histórico de vendas. A senha em claro nunca aparece nesta listagem.

---

## Agente da VPS

Escopo próprio: header `x-agent-token`, gerado por servidor no painel. Cada VPS
só enxerga a própria fila. Detalhes de operação em [vps-agent/README.md](../vps-agent/README.md).

### `POST /api/agent/heartbeat`

```json
{ "version": "1.0.0", "userCount": 42 }
```

```json
{ "ok": true, "serverName": "Servidor BR-01", "pendingTasks": 3 }
```

### `GET /api/agent/tasks?limit=25`

Fila pendente, mais antiga primeiro. As tarefas só saem da fila quando o agente
confirma — se ele morrer no meio, o lote volta inteiro.

```json
{
  "items": [
    {
      "id": "uuid",
      "username": "cli7f3k2",
      "action": "CREATE",
      "passwordHash": "$2a$10$...",
      "expiresAt": "2026-09-08T12:00:00.000Z",
      "connectionLimit": 1,
      "attempts": 0
    }
  ]
}
```

`action`: `CREATE` · `UPDATE` · `LOCK` · `UNLOCK` · `DELETE`.

O que trafega é o **hash bcrypt**, aplicado com `chpasswd --encrypted`. Senha em
claro nunca sai do painel.

### `POST /api/agent/tasks/:id/result`

```json
{ "ok": false, "error": "useradd: cannot open /etc/passwd" }
```

Falha devolve a tarefa para a fila e incrementa `attempts`. Na 5ª ela vira
`FAILED` e sai — a reconciliação a recupera depois.

### `GET /api/agent/sync`

Estado desejado completo, base da reconciliação:

```json
{
  "users": [
    {
      "username": "cli7f3k2",
      "passwordHash": "$2a$10$...",
      "expiresAt": "2026-09-08T12:00:00.000Z",
      "connectionLimit": 1,
      "locked": false
    }
  ]
}
```

### Gestão do token *(painel, ADMIN)*

| Rota | O que faz |
|---|---|
| `POST /api/servers/:id/agent-token` | gera/regenera — o valor aparece **uma vez** |
| `DELETE /api/servers/:id/agent-token` | revoga o acesso do agente |
| `POST /api/servers/:id/retry-failed` | devolve as tarefas `FAILED` para a fila |

`GET /api/servers` passa a trazer `hasAgent`, `agentLastSeen`, `agentVersion`,
`agentUserCount`, `pendingTasks` e `failedTasks`. O token em si nunca aparece em
listagem.

---

## Dashboard

### `GET /api/dashboard`

```json
{ "clients": 42, "activeClients": 38, "expiredClients": 4, "resellers": 3, "onlineNow": 12, "credits": 50 }
```

`credits: null` significa ilimitado (ADMIN).
