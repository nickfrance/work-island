#!/usr/bin/env bash
# Roda os testes (`swift test`), repassando os argumentos (ex.: --filter SessionStore).
# Só com as Command Line Tools (sem Xcode) o SwiftPM não acha o módulo Testing sozinho:
# nesse caso apontamos o framework e o rpath da lib de interop. Com Xcode, vale o `swift test` puro.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLT="/Library/Developer/CommandLineTools/Library/Developer"
FLAGS=()
if [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" && -d "$CLT/Frameworks/Testing.framework" ]]; then
  FLAGS=(
    -Xswiftc -F -Xswiftc "$CLT/Frameworks"
    -Xlinker -F -Xlinker "$CLT/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT/usr/lib"
  )
fi

exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
