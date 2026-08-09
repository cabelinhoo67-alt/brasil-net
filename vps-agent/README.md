# Agente da VPS

Sincroniza os usuários do Linux com o painel. Quando um cliente é criado,
renovado, bloqueado ou removido — pelo painel ou pelo bot do WhatsApp — a conta
SSH correspondente aparece, muda ou some da VPS sozinha.

> **Onde ele roda:** na VPS, não no backend. É lá que os usuários do sistema
> existem, e `useradd` precisa de root local. O backend nunca abre conexão com a
> VPS — quem puxa o trabalho é o agente.

---

## Como funciona

```
  painel / bot                backend                        VPS
       │                         │                            │
       │  cria cliente           │                            │
       ├────────────────────────►│                            │
       │                    enfileira                         │
       │                  ProvisionTask                       │
       │                         │◄───── GET /api/agent/tasks ─┤
       │                         │                            │
       │                         │────── CREATE agentetest ───►│  useradd
       │                         │                            │  chpasswd -e
       │                         │                            │  chage -E
       │                         │◄───── POST .../result ok ───┤  maxlogins
```

**Padrão outbox.** O backend grava a intenção numa fila e segue a vida. Se a VPS
estiver desligada, a fila espera; quando ela volta, é drenada na ordem. Nenhuma
credencial de root fica guardada no backend.

**Reconciliação.** A cada 15 minutos (e uma vez na subida) o agente busca o
estado desejado completo em `/api/agent/sync` e corrige a diferença. É isso que
salva o sistema quando a VPS é reinstalada, quando o agente ficou dias parado ou
quando alguém mexeu na mão.

**Senha em claro nunca sai do painel.** O que trafega é o hash bcrypt, aplicado
direto no `/etc/shadow` com `chpasswd --encrypted`. O mesmo hash que autentica no
app autentica no SSH.

---

## Instalação

Na VPS, como root:

```bash
git clone <seu-repo> /tmp/tunnel && cd /tmp/tunnel/vps-agent
```

```bash
sudo bash install.sh
```

O instalador:

- instala Node.js 20 se não houver;
- cria o grupo `tunnel` (a marca das contas gerenciadas);
- habilita `pam_limits.so` em `/etc/pam.d/sshd` — sem isso o limite de conexões
  não é aplicado pelo sshd;
- escreve `/etc/ssh/sshd_config.d/99-tunnel.conf` com a configuração do túnel;
- copia tudo para `/opt/tunnel-agent` e registra o serviço systemd.

**Ele valida com `sshd -t` antes de recarregar o SSH.** Se a configuração for
reprovada, o serviço não é recarregado e você recebe um aviso — não dá para se
trancar para fora da VPS por causa dele.

### Token

No painel: **Servidores → (o servidor) → Gerar token do agente**. O valor
aparece uma única vez. Cole em `/opt/tunnel-agent/.env`:

```
API_URL=https://api.seudominio.com.br
AGENT_TOKEN="<o token>"
```

### Testar antes de valer

```bash
cd /opt/tunnel-agent && DRY_RUN=true node src/index.js
```

Nesse modo o agente conversa com o backend e registra tudo que **faria**, sem
tocar em `/etc/passwd`. Confira o log e só então:

```bash
systemctl start tunnel-agent && journalctl -u tunnel-agent -f
```

No painel, o card do servidor passa a mostrar **agente online**, a versão e
quantas contas existem na VPS.

---

## Segurança

O agente roda como root — então o que ele aceita fazer é deliberadamente estreito.

**Só toca em contas do grupo `tunnel`.** Antes de qualquer `usermod`, `userdel`
ou troca de senha, ele confere que a conta pertence ao grupo. Uma conta criada à
mão, um usuário de sistema ou o `root` são recusados com erro explícito.

**Lista negra fixa.** `root`, `www-data`, `postgres`, `sshd` e outros dois dezenas
de nomes são rejeitados antes de qualquer checagem, mesmo que por algum motivo
apareçam no grupo.

**UID < 1000 é ignorado.** Contas de sistema nunca entram na lista de gerenciadas.

**Nome validado por regex.** `^[a-z_][a-z0-9_-]{2,31}$` — nada de `../`, espaços
ou caracteres que possam virar argumento.

**Sem shell.** Comandos são executados com `spawn(cmd, [args])`, nunca por string
interpretada. Não existe caminho de injeção via nome de usuário.

**Contas sem terminal.** O shell é `/usr/sbin/nologin`: encaminhamento de portas
funciona (é o que o túnel usa), sessão interativa não.

---

## O que cada ação faz no sistema

| Ação | Comandos |
|---|---|
| `CREATE` | `useradd --gid tunnel --shell nologin --create-home` + senha + validade + limite |
| `UPDATE` | `chpasswd --encrypted`, `chage --expiredate`, arquivo de `maxlogins`, `pkill -u` |
| `LOCK` | `usermod --lock` + `pkill -KILL -u` |
| `UNLOCK` | `usermod --unlock` |
| `DELETE` | `pkill -KILL -u` + `userdel --remove` + remove o arquivo de limites |

**Validade** vira `chage --expiredate YYYY-MM-DD`. O próprio sshd recusa o login
depois da data — o cliente para de conectar mesmo que o backend esteja fora do ar.

**Limite de conexões** vira `/etc/security/limits.d/99-tunnel-<user>.conf` com
`<user> - maxlogins N`. É o cinto de segurança do controle que o backend já faz
por heartbeat: mesmo que alguém burle o app, o sshd recusa a sessão excedente.

---

## Configuração

| Variável | Padrão | Para quê |
|---|---|---|
| `API_URL` | `http://localhost:3333` | backend (use HTTPS em produção) |
| `AGENT_TOKEN` | — | gerado no painel |
| `TUNNEL_GROUP` | `tunnel` | grupo das contas gerenciadas |
| `TUNNEL_SHELL` | `/usr/sbin/nologin` | shell das contas |
| `POLL_INTERVAL_MS` | `10000` | frequência de busca na fila |
| `SYNC_INTERVAL_MS` | `900000` | reconciliação completa |
| `BATCH_SIZE` | `25` | tarefas por lote |
| `DRY_RUN` | `false` | simula sem alterar nada |
| `LOG_LEVEL` | `info` | `debug` mostra os ciclos ociosos |

---

## Operação

```bash
systemctl status tunnel-agent
```

```bash
journalctl -u tunnel-agent -f
```

Contas gerenciadas no momento:

```bash
getent group tunnel
```

Estado de uma conta específica:

```bash
chage -l nomedousuario
```

Sessões abertas de um cliente:

```bash
ps -u nomedousuario
```

### Tarefas que falharam

Depois de 5 tentativas a tarefa vira `FAILED` e sai da fila. O painel mostra a
contagem no card do servidor e um botão **Reenfileirar falhas**. A reconciliação
também corrige sozinha na próxima passada — o botão só antecipa.

---

## Problemas comuns

**`agente online` não aparece no painel** — token errado ou backend inacessível.
O log mostra `token do agente recusado pelo backend`. Regenere no painel e
atualize o `.env`.

**Cliente conecta no app mas o SSH recusa** — a conta ainda não chegou na VPS.
Veja `getent group tunnel | grep usuario`. Se não estiver lá, confira a fila:
`journalctl -u tunnel-agent | grep usuario`.

**`chpasswd: cannot update password file`** — o agente não está como root, ou o
`/etc/shadow` está com atributo imutável (`chattr -i /etc/shadow`).

**Hash rejeitado / senha não confere** — a `libcrypt` da distro precisa aceitar
bcrypt (`$2a$`/`$2b$`). Debian 11+, Ubuntu 20.04+ e derivados aceitam. Verifique:

```bash
python3 -c "import crypt; print(crypt.crypt('teste', '\$2b\$10\$abcdefghijklmnopqrstuv'))"
```

Se voltar `None` ou um hash começando com outro prefixo, a `libcrypt` não suporta
bcrypt. Nesse caso, troque o `hashPassword` do backend para `sha512-crypt` ou
adote autenticação por chave.

**Limite de conexões não é respeitado** — `pam_limits.so` não está ativo:

```bash
grep pam_limits /etc/pam.d/sshd
```

O agente avisa isso no log ao subir.

**Cliente vencido continua conectando** — sessão que já estava aberta não cai
sozinha. O `ClientAliveInterval 30` do `99-tunnel.conf` derruba em até 90s;
para cortar na hora, bloqueie o cliente no painel (o `LOCK` faz `pkill`).
