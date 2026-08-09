# Tunnel System — App + Painel de Revenda + Bot de Vendas

Sistema completo em cinco módulos independentes que conversam por HTTP:

```
mobile/          Flutter (Android) — SIM Card, payloads por operadora e túnel SSH/V2Ray
backend/         Node.js + Express + Prisma + PostgreSQL — API e revenda em cascata
panel/           React + Vite + Tailwind — painel web com visões por hierarquia
bot-whatsapp/    Baileys + Mercado Pago Pix — venda e entrega automática
vps-agent/       Node.js na VPS — cria e remove os usuários SSH do Linux
```

```
   ┌──────────────┐   login/config/heartbeat   ┌──────────────┐
   │  App Flutter │ ─────────────────────────► │              │
   └──────────────┘                            │   BACKEND    │
                                               │  (porta 3333)│
   ┌──────────────┐   /internal/pix, /orders   │              │
   │  Bot WhatsApp│ ◄────────────────────────► │              │
   │ (porta 3334) │   ◄── callback Pix pago ── │              │
   └──────────────┘                            └──────┬───────┘
          ▲                                           │
          │ QR / mensagens                    webhook │
   ┌──────┴───────┐                            ┌──────▼───────┐
   │   Cliente    │                            │ Mercado Pago │
   └──────────────┘                            └──────────────┘
```

---

## Pré-requisitos

| Ferramenta | Versão | Para quê |
|---|---|---|
| Node.js | 20 LTS ou superior | backend e bot |
| Docker Desktop | atual | PostgreSQL (ou instale o Postgres direto) |
| Flutter SDK | 3.19+ | aplicativo Android |
| Android Studio | atual | SDK, emulador e build |
| Conta Mercado Pago | — | token de acesso para o Pix |

Verifique tudo de uma vez:

```bash
node -v && docker -v && flutter doctor
```

---

## 1. Banco de dados

Na raiz do projeto:

```bash
docker compose up -d
```

Sobe o PostgreSQL em `localhost:5432` e o Adminer em `http://localhost:8081`
(sistema **PostgreSQL**, servidor `postgres`, usuário `tunnel`, senha `tunnel123`, base `tunneldb`).

> O Adminer usa a porta **8081** porque a 8080 já estava ocupada nesta máquina.
> Se 8081 também conflitar, troque em `docker-compose.yml`.

Se preferir um PostgreSQL instalado no Windows, pule este passo e ajuste apenas a
`DATABASE_URL` no `.env` do backend.

---

## 2. Backend

```bash
cd backend
npm install
```

Copie o arquivo de ambiente e edite:

```bash
copy .env.example .env
```

Ajuste no mínimo `JWT_SECRET` e `INTERNAL_API_KEY` (qualquer string longa e aleatória —
a `INTERNAL_API_KEY` precisa ser **idêntica** no `.env` do bot).

Crie as tabelas e popule os dados iniciais:

```bash
npx prisma migrate dev --name init
```

```bash
npm run db:seed
```

Suba a API:

```bash
npm run dev
```

API em `http://localhost:3333`. Teste com `http://localhost:3333/health`.

### Contas criadas pelo seed

| Perfil | Usuário | Senha | Onde usa |
|---|---|---|---|
| Administrador Geral | `admin` | `admin123` | painel (crédito ilimitado) |
| Revendedor | `revenda1` | `revenda123` | painel (50 créditos) |
| Cliente final | `teste` | `teste123` | **aplicativo**, 30 dias |

O seed também cadastra 6 operadoras (Vivo, Claro, TIM, Oi, Algar, Vero) com seus
MCC/MNC, 4 planos e 1 payload de exemplo por operadora.

> Troque a senha do `admin` antes de expor o servidor à internet.

---

## 3. Painel web

```bash
cd panel && npm install
```

```bash
copy .env.example .env
```

```bash
npm run dev
```

Abre em `http://localhost:5173`. Entre com `admin` / `admin123` para a gestão
completa, ou `revenda1` / `revenda123` para ver a interface simplificada do
revendedor.

Detalhes das telas e do que cada nível enxerga: [panel/README.md](panel/README.md).

---

## 4. Bot do WhatsApp

```bash
cd bot-whatsapp
npm install
copy .env.example .env
```

No `.env`, cole em `INTERNAL_API_KEY` **a mesma chave** do backend e ajuste
`COMPANY_NAME`, `SUPPORT_NUMBER` e `APP_DOWNLOAD_URL`.

```bash
npm run dev
```

Um QR Code aparece no terminal. No celular: **WhatsApp → Aparelhos conectados →
Conectar aparelho**. A sessão fica salva em `bot-whatsapp/auth_session/` — não
precisa parear de novo a cada reinício, e essa pasta nunca deve ir para o Git.

Use um número dedicado ao bot. O WhatsApp pode banir números que enviam muitas
mensagens automáticas para contatos que nunca iniciaram conversa.

### Configurando o Pix

1. Acesse o [painel de desenvolvedor do Mercado Pago](https://www.mercadopago.com.br/developers/panel),
   crie uma aplicação e copie o **Access Token**.
2. Cole em `MP_ACCESS_TOKEN` no `.env` do **backend** e reinicie a API.
3. Comece com as credenciais de **teste** para validar o fluxo inteiro sem mover dinheiro real.

### Webhook em desenvolvimento

O Mercado Pago precisa alcançar seu PC para avisar do pagamento. Exponha a porta com
[ngrok](https://ngrok.com/):

```bash
ngrok http 3333
```

Cadastre a URL gerada no painel do Mercado Pago (Webhooks → tópico *Pagamentos*):

```
https://SEU-ID.ngrok-free.app/api/payments/webhook/mercadopago
```

**Sem ngrok também funciona:** o bot faz *polling* do pedido a cada 20 segundos como
fallback, então a entrega acontece de qualquer forma — só com alguns segundos a mais
de atraso.

---

## 5. Aplicativo Flutter

A pasta `mobile/` traz o código-fonte (`lib/`), o `pubspec.yaml` e os dois arquivos
Android que importam. Gere o esqueleto de plataforma uma única vez:

```bash
cd mobile
flutter create --org br.com.tunnelsystem --platforms=android .
```

Esse comando **não sobrescreve** `lib/` nem o `pubspec.yaml`. Ele cria `android/`,
`build.gradle` etc. Depois disso, confirme que os dois arquivos abaixo continuam
sendo os que já estão no repositório (se o `flutter create` os tiver substituído,
restaure-os pelo Git):

- `android/app/src/main/AndroidManifest.xml` — permissão `READ_PHONE_STATE`
- `android/app/src/main/kotlin/br/com/tunnelsystem/app/MainActivity.kt` — leitura do SIM

Instale as dependências e rode:

```bash
flutter pub get
```

```bash
flutter run --dart-define=API_URL=http://10.0.2.2:3333
```

### Qual `API_URL` usar

| Cenário | Valor |
|---|---|
| Emulador Android no mesmo PC | `http://10.0.2.2:3333` |
| Celular físico no mesmo Wi-Fi | `http://SEU_IP_LOCAL:3333` (ex.: `http://192.168.0.15:3333`) |
| Produção | `https://api.seudominio.com.br` |

Descubra seu IP local com `ipconfig` (procure *Endereço IPv4*). Libere a porta 3333 no
Firewall do Windows se o celular não conectar.

> **A detecção de operadora não funciona no emulador.** O Android emulado devolve
> "Android" / MCC-MNC `310260` (T-Mobile US). Para testar o filtro por chip de verdade,
> use um aparelho físico com o chip inserido. Alternativa para testar a UI: cadastre no
> painel uma operadora com o MCC/MNC `310260`.

Ao abrir, o app pede a permissão de telefone. Negando, ele funciona mas não consegue
identificar a operadora — e a lista de payloads fica vazia, por regra.

### Motor de túnel

O app conecta de verdade: `dartssh2` para SSH (com payload e SNI) e
`flutter_v2ray` para links vmess/vless. O roteamento de todo o tráfego do celular
usa a `VpnService` nativa escrita em Kotlin.

Payloads `V2RAY` funcionam direto após o `flutter pub get`. Payloads SSH exigem
adicionar a biblioteca tun2socks ao build — o passo a passo está em
[docs/TUNNEL.md](docs/TUNNEL.md), junto com um modo de teste que valida
SSH + payload + SNI sem precisar da VPN.

---

## 6. Agente da VPS

Só é necessário para túnel **SSH** — payloads V2Ray não usam contas do Linux.

Na VPS, como root:

```bash
git clone <seu-repo> /tmp/tunnel && cd /tmp/tunnel/vps-agent && sudo bash install.sh
```

Gere o token no painel (**Servidores → Gerar token do agente**), cole em
`/opt/tunnel-agent/.env` e teste sem alterar nada:

```bash
cd /opt/tunnel-agent && DRY_RUN=true node src/index.js
```

Se o log estiver limpo:

```bash
systemctl start tunnel-agent
```

O card do servidor no painel passa a mostrar "agente online". Guia completo,
incluindo as travas de segurança: [vps-agent/README.md](vps-agent/README.md).

---

## Build automático (GitHub Actions)

Dois workflows em [.github/workflows](.github/workflows):

**[android-apk.yml](.github/workflows/android-apk.yml)** — gera o APK a cada push
em `mobile/`, ou sob demanda em *Actions → Build APK → Run workflow*. O APK sai
como artefato do job, com o número do build no nome.

O repositório versiona só `lib/`, o `pubspec.yaml` e os dois arquivos Android que
são nossos (manifesto e código Kotlin). O scaffolding do Gradle é gerado pelo
`flutter create` dentro do CI e os nossos arquivos são restaurados do git logo
depois — assim nenhum binário (incluindo o `gradle-wrapper.jar`) vai para o repo.

Configure a URL da API em *Settings → Secrets and variables → Actions → Variables*:

| Variável | Exemplo |
|---|---|
| `API_URL` | `https://api.seudominio.com.br` |

Sem ela, o build usa `http://10.0.2.2:3333` (emulador local).

**Assinatura de release** é opcional. Sem os secrets abaixo o Flutter assina com a
chave de debug — o APK instala normalmente, mas não serve para a Play Store:

| Secret | O que é |
|---|---|
| `KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` |
| `STORE_PASSWORD` | senha do keystore |
| `KEY_ALIAS` | alias da chave |
| `KEY_PASSWORD` | senha da chave |

**[ci.yml](.github/workflows/ci.yml)** — valida o schema do Prisma, checa a
sintaxe do backend, do bot e do agente, e builda o painel.

> A primeira execução do *Build APK* é o **primeiro teste real do código Flutter**,
> que nunca foi compilado (ver ressalvas mais abaixo). Espere ajustes na primeira
> rodada, principalmente na versão do `flutter_v2ray`.

---

## Ordem de inicialização no dia a dia

Quatro terminais, nesta ordem:

```bash
docker compose up -d
```

```bash
cd backend && npm run dev
```

```bash
cd panel && npm run dev
```

```bash
cd bot-whatsapp && npm run dev
```

E o app com `flutter run` quando for testar o mobile.

---

## Como o sistema funciona

### Revenda em cascata

```
ADMIN (crédito ilimitado)
  └── MASTER  ── compra créditos do admin
        └── RESELLER ── recebe créditos do master
              └── CLIENT ── consome créditos ao ser criado
```

Cada nível só cria os níveis abaixo dele e só enxerga a própria descendência —
a checagem é feita por uma CTE recursiva em `backend/src/utils/hierarchy.js`, então
funciona com qualquer profundidade de rede.

Criar ou renovar um cliente **debita** o `creditCost` do plano do saldo de quem criou,
dentro de uma transação: nunca sobra crédito duplicado nem some saldo pela metade.
Excluir um revendedor devolve o saldo não usado para o upline.

### Filtro por operadora

1. O `MainActivity.kt` lê `simOperator` (MCC+MNC) e `simOperatorName` do `TelephonyManager`.
2. O app envia os dois no login e no refresh de configuração.
3. O backend resolve a operadora em `operator.resolver.js`: **primeiro pelo MCC/MNC**
   (confiável), depois pelo nome como fallback — porque MVNOs e roaming distorcem
   o `carrierName` ("Claro BR", "TIM BRASIL", "VIVO S.A.").
4. A consulta de payloads é feita `WHERE operatorId = <detectada>`. Sem operadora
   reconhecida, a lista volta **vazia** — o app nunca recebe config de outro chip.

### Controle de conexões simultâneas

O app manda um *heartbeat* a cada 30 segundos. O backend conta as sessões abertas do
usuário e recusa a criação de uma nova acima do `connectionLimit`. Reconectar do mesmo
`deviceId` reaproveita o slot em vez de consumir outro.

Sessão sem heartbeat por `SESSION_TIMEOUT_SECONDS` (padrão: 120s) é encerrada por uma
rotina que roda a cada minuto — sem isso, um app fechado à força travaria o cliente.

O heartbeat também é o canal de desligamento remoto: se o revendedor bloquear a conta
ou o plano vencer, a resposta vem com `disconnect: true` e o app derruba o túnel sozinho.

### Interfaces do painel por hierarquia

O menu e as rotas são montados a partir do papel de quem está logado. O
**revendedor** vê apenas Painel, Clientes, Créditos e Conta — o dashboard dele
destaca o saldo e a própria carteira de clientes, sem nada de infraestrutura. O
**admin/master** vê números da rede inteira, revendedores, operadoras, payloads,
servidores, planos e as vendas do WhatsApp. A tabela completa está em
[panel/README.md](panel/README.md).

### Túnel no aplicativo

O `mode` do payload decide o motor: `V2RAY` usa o `flutter_v2ray` (VpnService e
tun2socks já embutidos); `SSH_*` usa o `dartssh2` com payload e SNI aplicados na
mão, um servidor SOCKS5 em Dart e a `VpnService` em Kotlin roteando o aparelho.
Arquitetura e build nativo em [docs/TUNNEL.md](docs/TUNNEL.md).

### Contas SSH na VPS

O painel guarda o cliente no banco; quem cria a conta do Linux é o
[vps-agent](vps-agent/README.md), que roda **na VPS**. O backend enfileira a
intenção (padrão outbox) e o agente puxa — nenhuma credencial de root fica no
backend, e a fila espera a VPS voltar se ela cair.

O que trafega é o **hash bcrypt**, aplicado com `chpasswd --encrypted`: a mesma
senha vale no app e no SSH, e a senha em claro nunca sai do painel. Validade vira
`chage --expiredate` (o sshd recusa sozinho depois da data) e o limite de conexões
vira `maxlogins` no `pam_limits`.

O agente só toca em contas do grupo `tunnel`, com lista negra e validação de nome
— um bug no backend não vira `userdel root`. A cada 15 minutos ele reconcilia o
estado completo, o que conserta VPS reinstalada ou agente parado por dias.

### Venda automática pelo WhatsApp

```
Cliente manda "oi"
   → bot mostra o menu
   → cliente escolhe o plano
   → backend cria a Order e chama o Mercado Pago
   → bot envia o código Pix "copia e cola" em mensagem separada
   → cliente paga
   → webhook confirma → backend cria o login com a validade do plano
   → backend chama o bot → credenciais chegam no chat
```

O provisionamento é **idempotente**: webhook duplicado (o Mercado Pago reenvia por horas)
não gera dois usuários. E o webhook responde `200` imediatamente, processando depois —
uma falha no envio da mensagem não faz o gateway repetir a notificação para sempre.

---

## Estrutura de arquivos

```
tunnel-system/
├── docker-compose.yml
├── README.md
├── docs/
│   ├── API.md                    referência de todos os endpoints
│   ├── PAYLOADS.md               como cadastrar configs por operadora
│   ├── TUNNEL.md                 motor de túnel: arquitetura e build nativo
│   └── DEPLOY.md                 subir em VPS com Nginx + SSL
│
├── backend/
│   ├── prisma/
│   │   ├── schema.prisma         modelo de dados completo
│   │   └── seed.js               admin, operadoras, planos, payloads
│   └── src/
│       ├── server.js             bootstrap + faxina de sessões
│       ├── app.js                rotas e dashboard
│       ├── config/env.js         validação do .env com Zod
│       ├── middlewares/          auth (painel/app/interna) e erros
│       ├── utils/hierarchy.js    regras da cascata (CTE recursiva)
│       └── modules/
│           ├── auth/             login do painel
│           ├── users/            CRUD da rede + créditos + renovação
│           ├── credits/          transferência, recolhimento, extrato
│           ├── payloads/         operadoras e configurações
│           ├── servers/          servidores de túnel
│           ├── plans/            planos e preços
│           ├── mobile/           API do app (login, config, sessão, ping)
│           └── payments/         Pix, webhook e provisionamento
│
├── bot-whatsapp/
│   └── src/
│       ├── index.js              conexão Baileys + roteamento
│       ├── server.js             callback do backend (Pix pago)
│       ├── flows/                menu, mensagens e máquina de estados
│       └── services/             cliente da API e estado da conversa
│
├── vps-agent/                    roda NA VPS, não no backend
│   ├── install.sh                Node, grupo, pam_limits, sshd, systemd
│   ├── systemd/tunnel-agent.service
│   └── src/
│       ├── index.js              laço principal e execução das tarefas
│       ├── system.js             useradd/usermod/userdel + trava de segurança
│       ├── reconcile.js          convergência com o estado desejado
│       └── api.js                cliente da fila
│
├── panel/
│   └── src/
│       ├── App.jsx           rotas com guarda por papel
│       ├── lib/roles.js      permissões da interface
│       ├── context/          sessão e notificações
│       ├── components/       layout por hierarquia, modais, UI kit
│       └── pages/            login, dashboards, clientes, créditos, infra
│
└── mobile/
    ├── pubspec.yaml
    ├── android/app/src/main/
    │   ├── AndroidManifest.xml
    │   └── kotlin/.../
    │       ├── MainActivity.kt          TelephonyManager + registro dos canais
    │       └── tunnel/
    │           ├── TunnelVpnService.kt  interface TUN e ciclo de vida
    │           ├── VpnChannel.kt        permissão de VPN, start/stop
    │           └── Tun2Socks.kt         JNI com a lib nativa
    └── lib/
        ├── main.dart
        ├── core/                 config, HTTP, storage seguro, tema
        ├── models/               SimInfo, Operator, Payload, AppUser
        ├── services/
        │   ├── sim_service.dart      leitura do chip
        │   ├── app_state.dart        estado global
        │   └── tunnel/
        │       ├── ssh_tunnel_service.dart   SSH + payload + SNI
        │       ├── v2ray_tunnel_service.dart V2Ray/Xray
        │       ├── socks5_server.dart        SOCKS5 → canais SSH
        │       ├── payload_parser.dart       placeholders do payload
        │       ├── raw_ssh_socket.dart       RawSocket → SSHSocket
        │       ├── vpn_bridge.dart           canal com o Kotlin
        │       └── tunnel_factory.dart       escolhe o motor pelo mode
        ├── screens/              splash, login, home
        └── widgets/              card de conexão, item de payload
```

---

## O que já foi validado nesta máquina

O backend foi instalado, migrado, populado e exercitado de ponta a ponta contra o
PostgreSQL do `docker-compose`. Confirmado funcionando:

| Verificação | Resultado |
|---|---|
| Migração + seed | tabelas criadas, 6 operadoras, 4 planos, 3 contas |
| Login do painel (revendedor) | token emitido |
| Criar cliente com plano | 30 dias aplicados, saldo 50 → 49 |
| Renovar +30 dias | saldo 49 → 19, validade acumulada para 60 dias |
| Crédito insuficiente | `409 INSUFFICIENT_CREDITS`, nada é criado |
| Cascata: RESELLER criando MASTER | `403 ROLE_NOT_ALLOWED` |
| Cliente final no login do painel | `403 PANEL_DENIED` |
| Token do app em rota do painel | `403 WRONG_SCOPE` |
| **Chip Claro (72405)** | detecta `CLARO`, devolve só o payload da Claro |
| **Chip Vivo (72406)** | detecta `VIVO`, devolve só o payload da Vivo |
| **Nome sujo "TIM BRASIL" sem MCC** | fallback por nome resolve para `TIM` |
| **Chip estrangeiro (310260)** | `detected: false`, lista de payloads **vazia** |
| Limite de conexões | 2º aparelho recebe `409 CONNECTION_LIMIT` |
| Bloqueio remoto pelo painel | heartbeat seguinte responde desconexão |
| Chave interna do bot | ausente/errada → `403 BAD_INTERNAL_KEY` |
| Catálogo do bot | planos privados e sem preço não aparecem |
| Pix sem token do MP | `MP_NOT_CONFIGURED` (erro limpo, não quebra) |
| **Provisionamento pós-Pix** | usuário + senha criados com a validade do plano |
| **Webhook duplicado** | idempotente — 1 usuário, não 2 |
| **Credenciais geradas no app** | login OK, payloads filtrados pelo chip |

O **agente da VPS** teve o contrato inteiro exercitado contra a API real (a
execução dos comandos do Linux não, ver ressalvas):

| Verificação | Resultado |
|---|---|
| Token do agente ausente / inválido | `403 NO_AGENT_TOKEN` / `403 BAD_AGENT_TOKEN` |
| Criar cliente no painel | enfileira `CREATE` com hash, validade e limite |
| Bloquear / desbloquear | enfileira `LOCK` e `UNLOCK`, **na ordem** |
| Renovar | enfileira `UPDATE` com a validade nova |
| 3 renovações seguidas | coalescem em **1** `UPDATE` com a data final |
| Excluir cliente | enfileira `DELETE` (sobrevive à remoção do usuário) |
| Confirmação da tarefa | sai da fila |
| Falha reportada | volta para a fila com `attempts` incrementado |
| Heartbeat | painel mostra "agente online", versão e nº de contas |
| `GET /sync` | estado desejado completo, com hash e flag de bloqueio |

Um bug real apareceu nesse teste e foi corrigido: a renovação apagava tarefas de
`LOCK`/`UNLOCK` pendentes, então um cliente desbloqueado e renovado no mesmo
intervalo ficaria travado na VPS até a reconciliação seguinte. Agora a
coalescência só junta ação com ação igual.

O **painel web** também foi instalado, buildado e aberto no navegador contra a API
real:

| Verificação | Resultado |
|---|---|
| `npm run build` | 58 módulos, sem erro |
| Login `revenda1` | menu com **apenas** Painel, Clientes, Créditos, Conta |
| Dashboard do revendedor | saldo 50 em destaque, 1 cliente, lista de recentes |
| Login `admin` | menu completo + pílula "Crédito ilimitado" |
| Dashboard do admin | contadores da rede, últimos cadastros, vendas |
| Operadoras | 6 cards com MCC/MNC e contagem de payloads |
| Payloads | 6 itens com badge da operadora e conteúdo renderizado |
| Planos + modal de edição | preços e dados carregados da API |
| Servidores | status do agente, contas na VPS, fila e geração de token |

### O que **não** foi verificado

- **A geração real do Pix** e o **pareamento do WhatsApp** — dependem de
  credenciais externas (token do Mercado Pago e um número real).
- **Todo o aplicativo Flutter, incluindo o motor de túnel.** Não há Flutter SDK
  nesta máquina, então o código Dart e Kotlin **não foi compilado nem executado**.
  Rode `flutter pub get && flutter analyze` antes de confiar nele; os pontos que
  merecem atenção no primeiro teste estão listados no fim de
  [docs/TUNNEL.md](docs/TUNNEL.md).
- **A execução dos comandos do Linux pelo agente** (`useradd`, `chpasswd`,
  `chage`, `pam_limits`). Esta máquina é Windows — o contrato HTTP do agente foi
  todo exercitado, mas `system.js` nunca rodou contra um `/etc/passwd` de
  verdade. Use `DRY_RUN=true` na primeira execução na VPS: ele registra tudo que
  faria sem tocar no sistema.

Os dados de teste foram removidos ao final — o banco está no estado limpo do seed.
O `backend/.env` já foi criado a partir do `.env.example`, então você pode pular esse
passo (mas **troque** `JWT_SECRET` e `INTERNAL_API_KEY` antes de usar para valer).

Os containers do Docker ficaram rodando. Para parar:

```bash
docker compose down
```

---

## O que ainda falta para virar produto

Estes pontos precisam de decisão ou trabalho seu:

1. **Compilar e testar o app.** O código do túnel está completo mas nunca rodou —
   ver a ressalva acima. Comece pelo modo de diagnóstico descrito em
   [docs/TUNNEL.md](docs/TUNNEL.md), que valida SSH + payload + SNI sem VPN.

2. **Biblioteca tun2socks.** Necessária só para os payloads SSH (os V2Ray já
   funcionam). São duas opções, ambas documentadas: compilar junto pelo NDK ou
   copiar as `.so` prontas para `jniLibs/`.

3. **Instalar o agente na VPS.** O código está pronto e o contrato testado, mas
   ele nunca rodou num Linux de verdade. Comece com `DRY_RUN=true` — ver
   [vps-agent/README.md](vps-agent/README.md).

4. **Backup do banco.** `pg_dump` agendado antes de qualquer uso comercial.

---

## Problemas comuns

**`Can't reach database server at localhost:5432`** — o Docker não subiu. Rode
`docker compose ps` e confira se o container está *healthy*.

**`P1001` ou `P3009` no Prisma** — a `DATABASE_URL` do `.env` não bate com o
docker-compose. Confira usuário, senha e nome do banco.

**App não conecta na API** — quase sempre é `API_URL`. Emulador usa `10.0.2.2`,
celular físico usa o IP da máquina. Teste abrindo `http://SEU_IP:3333/health` no
navegador do próprio celular: se não abrir, é o Firewall do Windows.

**Operadora sempre "Não detectada"** — permissão de telefone negada, emulador em vez de
aparelho físico, ou o MCC/MNC do chip não está cadastrado. Veja qual código chegou nos
logs do backend e adicione-o ao campo `mccMncList` da operadora.

**Bot pede QR toda vez** — a pasta `auth_session/` está sendo apagada ou a sessão foi
desconectada pelo WhatsApp. Confirme o `SESSION_PATH` no `.env`.

**Pix gerado mas credenciais não chegam** — sem webhook público, a entrega depende do
polling do bot (até ~20s). Confira no log do backend se apareceu `[webhook] pedido ... pago`.
