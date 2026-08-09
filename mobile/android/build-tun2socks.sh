#!/usr/bin/env bash
#
# Compila a libhev-socks5-tunnel.so (tun2socks) e instala em jniLibs/.
#
# As .so ficam versionadas no repositorio para que o CI e quem clonar consiga
# gerar o APK sem NDK. Este script existe para reproduzir/auditar esses
# binarios — rode sempre que quiser atualizar a versao da biblioteca.
#
#   ANDROID_NDK_HOME=/caminho/do/ndk bash build-tun2socks.sh
#
set -euo pipefail

VERSION="${VERSION:-2.17.0}"
ABIS="${ABIS:-armeabi-v7a arm64-v8a}"
# Casa com o minSdk do app; o padrao do projeto upstream e 29.
PLATFORM="${PLATFORM:-android-26}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JNI_LIBS="$HERE/app/src/main/jniLibs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
[ -n "$NDK" ] || NDK="$(ls -d "${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$NDK" ] && [ -d "$NDK" ] || fail "NDK nao encontrado; defina ANDROID_NDK_HOME"

NDK_BUILD="$NDK/ndk-build"
[ -x "$NDK_BUILD" ] || NDK_BUILD="$NDK/ndk-build.cmd"
info "NDK: $NDK"

info "Baixando hev-socks5-tunnel $VERSION"
git clone -q --branch "$VERSION" --recursive --depth 1 \
  https://github.com/heiher/hev-socks5-tunnel.git "$WORK/src"
cd "$WORK/src"

# No Windows o git costuma gravar symlinks como arquivos-texto com o caminho
# dentro, e o compilador quebra na primeira linha. Em Linux/macOS o laco nao
# encontra nada e segue direto.
info "Resolvendo symlinks (necessario no Windows)"
resolved=0
while read -r f; do
  target_rel="$(tr -d '\n\r' < "$f")"
  case "$target_rel" in
    */*.h|*.h)
      target="$(dirname "$f")/$target_rel"
      if [ -f "$target" ] && [ "$(stat -c%s "$target" 2>/dev/null || echo 0)" -gt 200 ]; then
        cp -f "$target" "$f.tmp" && mv -f "$f.tmp" "$f"
        resolved=$((resolved + 1))
      fi
      ;;
  esac
done < <(find . -name '*.h' -size -200c)
echo "    $resolved resolvidos"

info "Compilando para: $ABIS"
"$NDK_BUILD" \
  NDK_PROJECT_PATH=. \
  APP_BUILD_SCRIPT=Android.mk \
  NDK_APPLICATION_MK=Application.mk \
  APP_ABI="$ABIS" \
  APP_PLATFORM="$PLATFORM" \
  -j"$(nproc 2>/dev/null || echo 4)"

info "Instalando em jniLibs/"
for abi in $ABIS; do
  so="libs/$abi/libhev-socks5-tunnel.so"
  [ -f "$so" ] || fail "nao gerou $so"

  # A lib registra os metodos por RegisterNatives numa classe de nome fixo.
  # Se esse nome mudar entre versoes, TProxyService.kt precisa acompanhar.
  grep -aq "hev/htproxy/TProxyService" "$so" \
    || fail "$abi: a .so nao referencia hev/htproxy/TProxyService"

  mkdir -p "$JNI_LIBS/$abi"
  cp -f "$so" "$JNI_LIBS/$abi/"
  printf '    %-14s %s\n' "$abi" "$(du -h "$JNI_LIBS/$abi/libhev-socks5-tunnel.so" | cut -f1)"
done

info "Pronto. Recompile o APK: flutter build apk --release"
