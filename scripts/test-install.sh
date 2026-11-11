#!/bin/bash
# Testa install.sh e uninstall.sh contra uma release falsa local (latest.json + zip, URLs file://).
# Nunca toca em /Applications, na pasta de dados real, no item de início nem no plugin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_SRC="$ROOT/build/Work Island.app"
if [ ! -d "$APP_SRC" ]; then
  "$ROOT/scripts/bundle-app.sh"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APPS="$TMP/apps"
mkdir -p "$APPS" "$TMP/release"
ZIP="$TMP/release/WorkIsland.zip"
ditto -c -k --keepParent "$APP_SRC" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
EXPECTED_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_SRC/Contents/Info.plist")"

write_release() { # $1 = digest
  cat > "$TMP/latest.json" <<JSON
{"tag_name":"v$EXPECTED_VERSION","assets":[
  {"name":"notes.txt","browser_download_url":"file://$TMP/release/notes.txt","digest":"sha256:0000"},
  {"name":"WorkIsland.zip","browser_download_url":"file://$ZIP","digest":"$1"}
]}
JSON
}

# Ambiente de teste: nada de abrir, matar o app em execução nem mexer no plugin/dados reais.
export WORK_ISLAND_RELEASE_API="file://$TMP/latest.json"
export WORK_ISLAND_APPS_DIR="$APPS"
export WORK_ISLAND_NO_OPEN=1
export WORK_ISLAND_NO_KILL=1
export WORK_ISLAND_SKIP_APP_UNINSTALL=1

fail() { echo "FAIL: $*" >&2; exit 1; }

INSTALLED="$APPS/Work Island.app"

# 1. instala com digest correto
write_release "sha256:$SHA"
/bin/bash "$ROOT/install.sh" >"$TMP/out1.txt" 2>&1 || { cat "$TMP/out1.txt" >&2; fail "install.sh falhou com release válida"; }
[ -d "$INSTALLED" ] || fail "app não foi instalado em $APPS"
GOT="$(plutil -extract CFBundleShortVersionString raw -o - "$INSTALLED/Contents/Info.plist")"
[ "$GOT" = "$EXPECTED_VERSION" ] || fail "versão $GOT, esperada $EXPECTED_VERSION"
[ -x "$INSTALLED/Contents/MacOS/WorkIsland" ] || fail "executável ausente"

# 2. digest errado: falha e o app anterior fica intacto
touch "$INSTALLED/.marcador"
write_release "sha256:$(printf '0%.0s' {1..64})"
if /bin/bash "$ROOT/install.sh" >"$TMP/out2.txt" 2>&1; then fail "install.sh deveria falhar com digest errado"; fi
[ -f "$INSTALLED/.marcador" ] || fail "app anterior foi alterado apesar do digest errado"
[ -x "$INSTALLED/Contents/MacOS/WorkIsland" ] || fail "app anterior foi danificado"

# 3. desinstala
/bin/bash "$ROOT/uninstall.sh" >"$TMP/out3.txt" 2>&1 || { cat "$TMP/out3.txt" >&2; fail "uninstall.sh falhou"; }
[ ! -e "$INSTALLED" ] || fail "app ainda existe depois de desinstalar"

echo OK
