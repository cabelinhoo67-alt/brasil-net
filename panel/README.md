# Painel web

React + Vite + Tailwind CSS 4. Tema escuro "Amaterasu": preto profundo com
brasa vermelha.

## Rodar

```bash
cd panel && npm install
```

```bash
copy .env.example .env
```

```bash
npm run dev
```

Abre em `http://localhost:5173`. A API precisa estar rodando na porta 3333
(`VITE_API_URL` no `.env` muda isso).

Build de produção:

```bash
npm run build
```

Sai em `dist/` — sirva com Nginx, Vercel, Netlify ou qualquer host estático.

## Interfaces por nível

O menu e as rotas são montados a partir do papel do usuário logado
([roles.js](src/lib/roles.js), [Layout.jsx](src/components/Layout.jsx)):

| Área | Admin | Master | Revendedor |
|---|:---:|:---:|:---:|
| Painel (dashboard) | ✅ global | ✅ global | ✅ **simplificado** |
| Clientes | ✅ | ✅ | ✅ só os dele |
| Revendedores | ✅ | ✅ | ❌ |
| Créditos | ✅ emite | ✅ transfere | ✅ só extrato e saldo |
| Operadoras / Payloads / Servidores | ✅ | ✅ | ❌ |
| Planos | ✅ | ❌ | ❌ |
| Vendas (Pix) | ✅ | ✅ | ❌ |

O **revendedor** vê um dashboard próprio: saldo em destaque, contagem dos
próprios clientes, ativos, vencidos e a lista dos cadastros recentes. Nada de
infraestrutura.

O **admin/master** vê números consolidados da rede inteira, últimos cadastros e
as vendas automáticas do WhatsApp.

> A checagem de papel na interface é conveniência de UX, não segurança. Um
> revendedor que digitar `/planos` na barra de endereço é redirecionado — e
> mesmo que forçasse a chamada, o backend responde 403.

## Estrutura

```
src/
├── main.jsx            providers (router, toast, auth)
├── App.jsx             rotas + guarda por papel
├── lib/
│   ├── api.js          cliente HTTP, token, tratamento de 401
│   ├── roles.js        permissões da interface
│   └── format.js       datas, moeda, situação do cliente
├── context/
│   ├── AuthContext.jsx sessão, revalidação do token, refresh de saldo
│   └── ToastContext.jsx
├── hooks/useApi.js     fetch com loading/erro/reload e descarte fora de ordem
├── components/
│   ├── Layout.jsx      sidebar por papel, gaveta no celular, pílula de saldo
│   ├── UserFormModal.jsx    criação com cálculo de custo em créditos
│   ├── UserDetailModal.jsx  renovar, bloquear, trocar senha, derrubar sessões
│   └── ui/             Button, Field, Modal, DataTable, Badge, Pagination…
└── pages/              Login, Dashboard, UsersPage, Credits, Operators,
                        Payloads, Servers, Plans, Orders, Account
```

## Detalhes de implementação

**Tabelas viram cartões no celular.** O `DataTable` renderiza `<table>` acima de
`md` e uma lista de cartões abaixo — sem scroll horizontal em tela pequena.

**Custo em créditos aparece antes de salvar.** O modal de criação calcula o custo
do plano escolhido e desabilita o botão quando falta saldo, em vez de deixar o
usuário levar um 409.

**Senha aparece uma vez só.** Depois de criar um acesso, um modal mostra
usuário/senha com botão de copiar. O backend nunca devolve a senha de novo.

**Token expirado derruba a sessão.** Qualquer 401 dispara o logout pelo
`subscribeUnauthorized` — não fica tela quebrada com dados velhos.

**Tema.** As cores vivem em `@theme` no [index.css](src/index.css): `void-*`
(pretos), `ember-*` (vermelhos), mais os utilitários `card`, `card-ember` e
`ember-text`. Trocar a identidade é mexer só nessas variáveis.
