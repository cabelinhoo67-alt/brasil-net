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

## Adicionando a biblioteca tun2socks

Esta é a única peça que o projeto não escreve. Converter pacotes IP crus em
conexões SOCKS5 exige uma pilha TCP/IP completa em espaço de usuário — usar uma
pronta e testada é o certo.

Usamos o [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) (MIT).
O `Tun2Socks.kt` já espera exatamente a assinatura JNI dele.

### Opção A — compilar junto (recomendado)

```bash
cd mobile/android/app/src/main
mkdir -p jni && cd jni
git clone --recursive https://github.com/heiher/hev-socks5-tunnel
```

No `mobile/android/app/build.gradle`:

```gradle
android {
    defaultConfig {
        externalNativeBuild {
            ndkBuild {
                abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86_64'
            }
        }
    }

    externalNativeBuild {
        ndkBuild {
            path 'src/main/jni/hev-socks5-tunnel/Android.mk'
        }
    }
}
```

Depois:

```bash
flutter build apk --release
```

O `Android.mk` do projeto gera `libhev-socks5-tunnel.so` para cada ABI, e o
`System.loadLibrary("hev-socks5-tunnel")` do `Tun2Socks.kt` encontra a lib
automaticamente. Requer o **NDK** instalado pelo Android Studio.

### Opção B — .so pré-compilada

Se preferir não compilar, pegue as `.so` de um release do projeto e coloque em:

```
mobile/android/app/src/main/jniLibs/arm64-v8a/libhev-socks5-tunnel.so
mobile/android/app/src/main/jniLibs/armeabi-v7a/libhev-socks5-tunnel.so
```

O Gradle empacota `jniLibs/` sem configuração adicional.

### Se a lib não estiver presente

O app **não finge que conectou**. `Tun2Socks.available` fica `false`, o
`VpnChannel` responde `NO_TUN2SOCKS` e a tela mostra o erro. Isso é intencional:
falhar visivelmente é melhor que um túnel fantasma.

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

Pontos que merecem atenção no primeiro teste real:

1. **API do flutter_v2ray** varia entre versões. Se `parseFromURL` ou
   `startV2Ray` não baterem, ajuste conforme a versão que o `pub get` trouxer.
2. **`SSHForwardChannel`** — confirme que `.stream` e `.sink` existem na versão
   do dartssh2 instalada.
3. **Payload + TLS na mesma conexão** é o caminho menos comum; se o proxy mandar
   bytes extras antes do TLS, o app avisa com mensagem específica em vez de
   travar.
