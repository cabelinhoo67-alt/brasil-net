# Motor de túnel

O `MockTunnelService` foi removido. No lugar há duas implementações reais da
mesma interface `TunnelService`, escolhidas automaticamente pelo `mode` do payload:

| `mode` do payload | Motor | Precisa de passo extra de build? |
|---|---|---|
| `V2RAY` | `V2RayTunnelService` (flutter_v2ray) | **Não** |
| `SSH_DIRECT`, `SSH_PAYLOAD`, `SSH_SSL` | `SshTunnelService` (dartssh2) | **Sim** — a lib tun2socks |

---

## Como o túnel SSH funciona

```
apps do celular
      │
      ▼
  interface TUN  ← criada pela TunnelVpnService (Kotlin)
      │  pacotes IP crus
      ▼
   tun2socks     ← pilha TCP/IP em espaço de usuário (lib nativa)
      │  SOCKS5
      ▼
127.0.0.1:PORTA  ← Socks5Server, escrito em Dart
      │  canal direct-tcpip
      ▼
  sessão SSH     ← dartssh2: payload + SNI + auth
      │
      ▼
     VPS  →  internet
```

Cada etapa vive em um arquivo:

| Arquivo | Papel |
|---|---|
| [ssh_tunnel_service.dart](../mobile/lib/services/tunnel/ssh_tunnel_service.dart) | orquestra TCP → payload → TLS → SSH → SOCKS → VPN |
| [payload_parser.dart](../mobile/lib/services/tunnel/payload_parser.dart) | troca `[host_port]`, `[crlf]`, `[split]`… pelos valores reais |
| [raw_ssh_socket.dart](../mobile/lib/services/tunnel/raw_ssh_socket.dart) | adapta `RawSocket` para o `SSHSocket` do dartssh2 |
| [socks5_server.dart](../mobile/lib/services/tunnel/socks5_server.dart) | SOCKS5 (RFC 1928) → canais SSH |
| [vpn_bridge.dart](../mobile/lib/services/tunnel/vpn_bridge.dart) | MethodChannel com o Kotlin |
| [TunnelVpnService.kt](../mobile/android/app/src/main/kotlin/br/com/tunnelsystem/app/tunnel/TunnelVpnService.kt) | cria a TUN, notificação, ciclo de vida |
| [Tun2Socks.kt](../mobile/android/app/src/main/kotlin/br/com/tunnelsystem/app/tunnel/Tun2Socks.kt) | JNI com a lib nativa |
| [VpnChannel.kt](../mobile/android/app/src/main/kotlin/br/com/tunnelsystem/app/tunnel/VpnChannel.kt) | permissão de VPN e start/stop |

### Detalhes que costumam quebrar (e já estão resolvidos aqui)

**Loop de roteamento.** A conexão SSH que sustenta a VPN não pode passar pela
própria VPN. Resolvido com `addDisallowedApplication(packageName)` na
`VpnService.Builder` — o app inteiro fica fora do túnel, então o socket SSH sai direto.

**Banner SSH junto da resposta do proxy.** Depois do `CONNECT`, o servidor
costuma mandar `HTTP/1.1 200` e o `SSH-2.0-...` no mesmo segmento TCP. Os bytes
extras são preservados e reinjetados no stream (`leftover` em `RawSSHSocket`) —
sem isso o handshake falha com "banner ausente".

**TLS depois do payload.** Só o `RawSocket` permite ler a resposta do proxy e
depois entregar a assinatura para `RawSecureSocket.secure(subscription:)`. Com
`Socket` comum, ouvir o stream inviabiliza o upgrade para TLS. O SNI vai no
parâmetro `host` do `secure()`.

**Certificado auto-assinado.** `onBadCertificate: (_) => true`. A
confidencialidade real vem do SSH por dentro; o TLS aqui serve para o SNI.

---

## A biblioteca tun2socks — já incluída

Converter pacotes IP crus em conexões SOCKS5 exige uma pilha TCP/IP completa em
espaço de usuário. Usamos o
[hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) 2.17.0 (MIT),
compilado do fonte com o NDK.

As `.so` estão **versionadas** no repositório:

```
mobile/android/app/src/main/jniLibs/arm64-v8a/libhev-socks5-tunnel.so     336 KB
mobile/android/app/src/main/jniLibs/armeabi-v7a/libhev-socks5-tunnel.so   229 KB
```

O Gradle empacota `jniLibs/` sem configuração adicional, então o CI gera o APK
sem precisar do NDK.

### Reproduzindo os binários

Binário versionado só se justifica se der para regenerá-lo. O script faz isso:

```bash
ANDROID_NDK_HOME=/caminho/do/ndk bash mobile/android/build-tun2socks.sh
```

Ele clona a tag, compila para as duas ABIs, **verifica que a `.so` referencia
`hev/htproxy/TProxyService`** e instala em `jniLibs/`.

### O contrato JNI é rígido

A biblioteca não usa a convenção `Java_pacote_Classe_metodo`. Ela chama
`RegisterNatives` no `JNI_OnLoad` procurando uma classe de nome fixo — definida
por `PKGNAME`/`CLSNAME` em `hev-jni.c`:

```c
#define PKGNAME hev/htproxy
#define CLSNAME TProxyService
```

Por isso existe [`hev/htproxy/TProxyService.kt`](../mobile/android/app/src/main/kotlin/hev/htproxy/TProxyService.kt),
fora do nosso pacote. **Renomear essa classe ou movê-la de pacote faz o
`System.loadLibrary` falhar inteiro**, não só o método.

As assinaturas também são fixas, e todas devolvem `boolean` — não `void`:

| Método | Assinatura JNI |
|---|---|
| `TProxyStartService` | `(Ljava/lang/String;I)Z` |
| `TProxyStopService` | `()Z` |
| `TProxyIsRunning` | `()Z` |
| `TProxyGetStats` | `()[J` |

Conferidas contra os símbolos da `.so` compilada.

### Compilando no Windows

O `git` do Windows grava os symlinks do projeto como arquivos-texto contendo o
caminho de destino — o compilador quebra na primeira linha com
`expected identifier or '('`. São 31 headers nessa situação. O
`build-tun2socks.sh` materializa cada um antes de compilar; em Linux e macOS
esse passo não encontra nada e é ignorado.

### Se a lib não estiver presente

O app **não finge que conectou**. `Tun2Socks.available` fica `false`, o
`VpnChannel` responde `NO_TUN2SOCKS` e a tela mostra o erro. Falhar
visivelmente é melhor que um túnel fantasma.

---

## Testando sem VPN primeiro

Antes de mexer com a lib nativa, dá para validar SSH + payload + SNI + SOCKS
isoladamente. Em [tunnel_factory.dart](../mobile/lib/services/tunnel/tunnel_factory.dart):

```dart
static final _ssh = SshTunnelService(routeDeviceTraffic: false);
```

Com isso o app conecta no SSH e sobe o SOCKS5 local, sem tocar em VpnService.
A tela mostra "Conectado" e o log traz a porta:

```
[tunnel] TCP br01.seudominio.com.br:443
[tunnel] injetando payload (1 pacote(s))
[tunnel] proxy respondeu: HTTP/1.1 200 Connection established
[tunnel] TLS com SNI "www.claro.com.br"
[tunnel] SSH autenticado
[tunnel] modo diagnostico: SOCKS5 em 127.0.0.1:41xxx
```

Se chegou até "SSH autenticado", o túnel está de pé — o que falta é só o
roteamento do sistema.

---

## O caminho V2Ray (sem trabalho nativo)

Cadastre o payload no painel com `mode = V2RAY` e cole o link completo no campo
de conteúdo:

```
vless://uuid@servidor.com:443?type=ws&security=tls&sni=www.claro.com.br&path=%2Fws#BR-01
```

O `flutter_v2ray` já traz VpnService e tun2socks embutidos — `flutter pub get` e
pronto, o celular inteiro passa pelo túnel. Se sua operação puder usar V2Ray/Xray
em vez de SSH, este é o caminho mais curto para ter algo funcionando hoje.

---

## Autenticação

O túnel SSH autentica com **o mesmo usuário e senha** do login do app. O
`AppState` guarda a senha em memória durante a sessão justamente para isso
(`_password`) e a persiste no `flutter_secure_storage` quando "manter conectado"
está ligado.

Se o seu servidor usar chave em vez de senha, troque em `ssh_tunnel_service.dart`:

```dart
SSHClient(socket, username: username, identities: SSHKeyPair.fromPem(pem))
```

---

## Estado desta implementação

O código foi escrito completo, mas **não foi compilado nem executado** — não há
Flutter SDK na máquina onde ele foi gerado. Rode antes de confiar:

```bash
cd mobile && flutter pub get && flutter analyze
```

### O que já foi conferido contra o código-fonte dos pacotes

O primeiro build no CI falhou por versão inexistente (`flutter_v2ray ^1.0.20`).
Aproveitei para baixar os dois pacotes e conferir a API real, membro por membro:

| Usado no código | Existe? |
|---|---|
| `FlutterV2ray({onStatusChanged})`, `initializeV2Ray`, `requestPermission` | sim |
| `startV2Ray({remark, config, proxyOnly})`, `stopV2Ray` | sim |
| `FlutterV2ray.parseFromURL(url)` → `.remark`, `.getFullConfiguration()` | sim |
| `V2RayStatus.state` (String, default `DISCONNECTED`) | sim |
| `SSHClient(socket, username:, onPasswordRequest:)` | sim |
| `client.authenticated`, `client.done`, `client.ping()`, `client.close()` | sim |
| `client.forwardLocal(host, port)` → `.stream`, `.sink` | sim |
| `SSHSocket`: `stream`, `sink`, `done`, `close()`, `destroy()` | sim |

Essa conferência achou um erro de compilação: `SSHSocket` também declara
`flush()`, e como `RawSSHSocket` usa `implements` (não `extends`), o método
precisava existir mesmo tendo corpo padrão na interface. Corrigido.

Versões travadas nas que foram conferidas: `dartssh2: ^2.22.0` e
`flutter_v2ray: ^1.0.10` (a última publicada).

### O que continua sem verificação

1. **Compilação de verdade.** A conferência acima é leitura de código-fonte, não
   `flutter analyze`. O build do CI é quem dá a palavra final.
2. **Payload + TLS na mesma conexão** é o caminho menos comum; se o proxy mandar
   bytes extras antes do TLS, o app avisa com mensagem específica em vez de
   travar — mas isso nunca rodou contra um servidor real.
3. **Comportamento em rede móvel real** — payload aceito pelo proxy, SNI que
   passa, estabilidade do keepalive. Só testando com chip.
