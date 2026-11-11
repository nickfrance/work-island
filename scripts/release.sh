#!/usr/bin/env bash
# Monta e publica uma versão da Work Island.
#
#   scripts/release.sh <versão> [--dry-run] [--notes-file <arquivo>]
#
# 1. grava a versão em plugin/.claude-plugin/plugin.json (app e plugin sempre iguais); sem
#    --dry-run, se precisou gravar, para pedindo o commit, e recusa árvore com mudanças não commitadas;
# 2. VERSION=<versão> METRICS_URL="$WORK_ISLAND_METRICS_URL" scripts/bundle-app.sh;
# 3. zipa build/Work Island.app em dist/WorkIsland.zip e imprime o SHA-256;
# 4. sem --dry-run: gh release create v<versão> dist/WorkIsland.zip --repo nickfrance/work-island.
#
# Sem WORK_ISLAND_METRICS_URL, pergunta se segue sem métricas (a versão não envia nada).
# O --dry-run nunca chama o gh e aceita árvore suja. Sem --notes-file, as notas são geradas em
# dist/notes-v<versão>.md.
#
# Antes do passo 4, o export (scripts/export-public.sh) tem de estar no repositório público, com
# push feito: o `gh release create` cria a tag v<versão> no main de lá.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="nickfrance/work-island"
PLUGIN_JSON="$ROOT/plugin/.claude-plugin/plugin.json"
APP="$ROOT/build/Work Island.app"
DIST="$ROOT/dist"
ZIP="$DIST/WorkIsland.zip"

usage() {
  echo "uso: scripts/release.sh <versão> [--dry-run] [--notes-file <arquivo>]" >&2
  exit 2
}

VERSION=""
DRY_RUN=0
NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --notes-file)
      [ $# -ge 2 ] || usage
      NOTES_FILE="$2"
      shift
      ;;
    -*) usage ;;
    *)
      [ -z "$VERSION" ] || usage
      VERSION="$1"
      ;;
  esac
  shift
done
[ -n "$VERSION" ] || usage

# Só x.y.z (sem "v"): é o que o app compara com a release do GitHub.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "versão inválida: $VERSION (use x.y.z, sem v)" >&2
  exit 2
fi
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then
  echo "arquivo de notas não encontrado: $NOTES_FILE" >&2
  exit 2
fi

# 1. Versão do plugin igual à do app (o app reinstala o plugin quando ela muda).
current="$(plutil -extract version raw -o - "$PLUGIN_JSON")"
if [ "$current" != "$VERSION" ]; then
  sed -i '' -E "s/(\"version\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"/\1\"$VERSION\"/" "$PLUGIN_JSON"
  if [ "$(plutil -extract version raw -o - "$PLUGIN_JSON")" != "$VERSION" ]; then
    echo "não consegui gravar a versão em $PLUGIN_JSON" >&2
    exit 1
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    echo "plugin.json: $current → $VERSION. Commite plugin/.claude-plugin/plugin.json e rode de novo." >&2
    exit 1
  fi
  echo "plugin.json: $current → $VERSION (lembre de commitar)"
fi
# A versão publicada é a do que está commitado: nada de mudança solta no zip.
if [ "$DRY_RUN" -eq 0 ] && [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
  echo "há mudanças não commitadas; commite (ou guarde) antes de publicar:" >&2
  git -C "$ROOT" status --short --untracked-files=no >&2
  exit 1
fi

# Endereço do receptor de métricas: só as versões publicadas o levam.
METRICS_URL="${WORK_ISLAND_METRICS_URL:-}"
if [ -z "$METRICS_URL" ]; then
  echo "WORK_ISLAND_METRICS_URL não está definida: esta versão não vai enviar métricas."
  answer=""
  read -r -p "Seguir sem métricas? [s/N] " answer || true
  case "$answer" in
    s|S|sim|y|Y|yes) ;;
    *) echo "Cancelado." >&2; exit 1 ;;
  esac
fi

# 2. App universal, com a versão e o endereço das métricas no Info.plist.
VERSION="$VERSION" METRICS_URL="$METRICS_URL" "$ROOT/scripts/bundle-app.sh"

plist="$APP/Contents/Info.plist"
if [ "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" != "$VERSION" ]; then
  echo "o Info.plist não tem a versão $VERSION" >&2
  exit 1
fi
if [ "$(plutil -extract WorkIslandMetricsURL raw -o - "$plist" 2>/dev/null || true)" != "$METRICS_URL" ]; then
  echo "o Info.plist não tem o endereço das métricas esperado" >&2
  exit 1
fi
archs="$(lipo -archs "$APP/Contents/MacOS/WorkIsland")"
if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
  echo "o app não é universal (arquiteturas: $archs)" >&2
  exit 1
fi

# 3. Zip com o .app na raiz (é o que o install.sh e a atualização pela ilha esperam).
mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo
echo "dist/WorkIsland.zip ($(du -h "$ZIP" | awk '{print $1}'))"
echo "SHA-256: $SHA"
if [ -n "$METRICS_URL" ]; then
  echo "Métricas: ligadas ($METRICS_URL)"
else
  echo "Métricas: sem receptor (esta versão não envia nada)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "--dry-run: nada publicado. Sem ele, rodaria:"
  echo "  gh release create v$VERSION dist/WorkIsland.zip --repo $REPO --notes-file <notas>"
  exit 0
fi

# 4. Publicação.
if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE="$DIST/notes-v$VERSION.md"
  cat > "$NOTES_FILE" <<NOTES
Work Island $VERSION

Install or update:

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash
\`\`\`

SHA-256 of WorkIsland.zip: \`$SHA\`
NOTES
  echo "Notas geradas em $NOTES_FILE"
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "o gh (GitHub CLI) não está instalado; o zip ficou em dist/." >&2
  exit 1
fi

answer=""
read -r -p "Publicar v$VERSION em github.com/$REPO? [s/N] " answer || true
case "$answer" in
  s|S|sim|y|Y|yes) ;;
  *) echo "Não publicado. O zip ficou em dist/." >&2; exit 1 ;;
esac

# O export já tem de estar no GitHub (push feito): a tag v$VERSION é criada no main de lá.
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Work Island $VERSION" --notes-file "$NOTES_FILE"
echo "Publicada: https://github.com/$REPO/releases/tag/v$VERSION"
