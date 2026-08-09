# Operadoras e configurações

Este documento explica como o filtro por chip funciona na prática e como cadastrar
as configurações de cada operadora.

## Como a operadora é identificada

O `MainActivity.kt` devolve dois campos ao Flutter:

| Campo | Origem | Confiabilidade |
|---|---|---|
| `mccMnc` | `TelephonyManager.simOperator` | **alta** — código numérico padronizado |
| `operatorName` | `TelephonyManager.simOperatorName` | baixa — texto livre, varia por aparelho |

O backend (`src/modules/mobile/operator.resolver.js`) tenta nesta ordem:

1. **MCC/MNC exato** contra o campo `mccMncList` da operadora;
2. código da operadora contido no nome normalizado (`"CLAROBR"` contém `"CLARO"`);
3. nome cadastrado contido no nome do SIM.

A normalização remove acentos, espaços e pontuação e passa tudo para maiúsculas —
por isso `"Vivo S.A."`, `"VIVO"` e `"vivo "` chegam ao mesmo lugar.

Nada casou? `detected: false` e **lista de payloads vazia**. Isso é intencional: sem
identificar o chip, o app não recebe configuração nenhuma.

## MCC/MNC das operadoras brasileiras

O MCC do Brasil é `724`. Os já cadastrados pelo seed:

| Operadora | MCC/MNC |
|---|---|
| Vivo | 72406, 72410, 72411, 72423 |
| Claro | 72405, 72438 |
| TIM | 72402, 72403, 72404, 72454 |
| Oi | 72431, 72416 |
| Algar | 72432, 72433, 72434 |
| Vero / Nextel | 72439 |

### Descobrindo o código de um chip

MVNOs (Correios Celular, Surf Telecom e as revendas que rodam sobre a rede de outra
operadora) têm códigos próprios que não estão nessa lista. Para descobrir:

1. Faça login pelo app com o chip inserido;
2. veja no log do backend qual `mccMnc` chegou;
3. adicione o código ao campo `mccMncList` da operadora correspondente
   (valores separados por vírgula, sem espaços).

```http
PATCH /api/payloads/operators/:id
{ "mccMncList": "72405,72438,72499" }
```

## Cadastrando uma operadora

```http
POST /api/payloads/operators
{
  "code": "CLARO",
  "name": "Claro",
  "mccMncList": "72405,72438",
  "sortOrder": 2
}
```

O `code` é normalizado para maiúsculas e precisa ser único.

## Cadastrando um payload

```http
POST /api/payloads
{
  "name": "Claro - SSH/SSL",
  "operatorId": "uuid-da-claro",
  "serverId": "uuid-do-servidor",
  "mode": "SSH_SSL",
  "content": "CONNECT [host_port] [protocol][crlf]Host: [host][crlf][crlf]",
  "sni": "www.claro.com.br",
  "isActive": true,
  "sortOrder": 1
}
```

### Campos por modo

| Modo | Campos relevantes |
|---|---|
| `SSH_DIRECT` | apenas `serverId` |
| `SSH_PAYLOAD` | `content`, `proxyHost`, `proxyPort` |
| `SSH_SSL` | `content`, `sni` |
| `V2RAY` | `content` (link `vmess://` ou `vless://`) |
| `SLOWDNS` | `dnsHost`, `publicKey` |
| `UDP` | `extraJson` com as portas |

O `extraJson` é um campo livre em JSON para o que não couber nos campos fixos — ele
chega ao app já desserializado, no campo `extra` do payload.

## Ordem de exibição

`sortOrder` crescente. O app pré-seleciona o primeiro item da lista, então coloque a
configuração mais estável em `sortOrder: 1`.

## Ativar e desativar

`isActive: false` some da lista do app imediatamente — não precisa republicar nada.
Use isso para tirar do ar uma config que parou de funcionar sem perder o cadastro.

Payload cujo servidor está com `isActive: false` também é filtrado, mesmo que o
payload em si esteja ativo.

## Clonando entre operadoras

```http
POST /api/payloads/:id/duplicate
{ "operatorId": "uuid-da-outra-operadora" }
```

A cópia nasce **desativada**, com o sufixo "(copia)" no nome. Ajuste o SNI e o
conteúdo antes de ativar.

## Restrição por versão do app

`minAppVersion` está no schema para permitir entregar configs novas só a quem já
atualizou. O filtro ainda não é aplicado na consulta — se você precisar disso, o
lugar de implementar é a função `payloadsForOperator` em
`src/modules/mobile/mobile.routes.js`, comparando com o `appVersion` que o app já envia
no login.
