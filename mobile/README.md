# Tunnel System — App Móvel

Aplicativo Android (Flutter) de túnel SSH/V2Ray com VPN integrada, rotação agressiva de payloads e fallback via WebSocket.

## Características

- **Túnel SSH direto** sobre TCP com payloads HTTP personalizáveis (CONNECT, GET, POST) e rotação agressiva de SNI/domínio por operadora.
- **Fallback SSH sobre WebSocket** (`wss://brasilnetpro.click/tun`) quando o TCP direto é bloqueado — transporta as mesmas sessões dartssh2 através do `ws-bridge` no servidor.
- **Modo V2Ray** (via plugin `flutter_v2ray`) com perfis de configuração.
- **VPN integrada** — `VpnService` (Kotlin) cria a interface TUN e encaminha o tráfego para o proxy SOCKS5 do túnel via `hev-socks5-tunnel` (tun2socks).
- **Login offline/bootstrap** — cache de configuração em `SharedPreferences` permite conectar o túnel primeiro e autenticar depois, com servidor de bootstrap fixo quando não há cache.
- **Reconexão automática** — `NetworkWatcher` detecta perda de rede e o serviço agenda reconexão com backoff exponencial (2s → 30s, até 8 tentativas) sem recriar a interface TUN (`rebind()`).
- **Detecção de portal cativo** — inspeção do primeiro pacote HTTP; redirecionamentos da operadora silenciam a estratégia atual e avançam para a próxima.
- **Proxy SOCKS5 para a própria API do app** — as chamadas HTTP da aplicação atravessam o túnel (`useSocksProxy`) já que o app é desviado do próprio VPN.

## Estrutura

```
lib/
  main.dart                    # Inicialização
  core/
    api_client.dart            # HTTP com redirects bloqueados + suporte a proxy SOCKS5
  services/
    app_state.dart             # Estado global, login, bootstrap offline
    config_cache.dart          # Cache de configuração (SharedPreferences)
    tunnel/
      tunnel_service.dart      # Abstração do serviço de túnel
      ssh_tunnel_service.dart  # Túnel SSH (TCP + fallback WebSocket)
      connect_strategy.dart    # Modos de transporte, perfis por operadora, cadeia de estratégias
      payload_parser.dart      # Substituição de placeholders dos payloads
      ws_ssh_socket.dart       # SSHSocket sobre WebSocketChannel
      v2ray_tunnel_service.dart# Túnel V2Ray
      vpn_bridge.dart          # Ponte para o VpnService (Kotlin)
  ui/                          # Telas (login, home, consentimento de localização, etc.)
android/app/src/main/kotlin/br/com/tunnelsystem/app/
  MainActivity.kt
  tunnel/
    TunnelVpnService.kt        # VpnService: TUN, tun2socks, START_STICKY
    VpnChannel.kt              # MethodChannel/EventChannel
    Tun2Socks.kt               # Wrapper do hev-socks5-tunnel
    NetworkWatcher.kt          # Detecção de perda/reestabelecimento de rede
```

## Build

```bash
flutter pub get
flutter build apk --release
# APK universal gerado em releases/tunnel-app-<version>-universal.apk
```

## Configuração do servidor

O endpoint de WebSocket (`wss://brasilnetpro.click/tun`) depende do `ws-bridge` e do Nginx instalados no VPS — ver [`docs/DEPLOY.md`](../docs/DEPLOY.md).
