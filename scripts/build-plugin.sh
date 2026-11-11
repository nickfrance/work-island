#!/usr/bin/env bash
# Compila o ilha-hook universal (arm64 + x86_64) em release e o copia para plugin/bin/ (pasta ignorada pelo git).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for arch in arm64 x86_64; do
  swift build -c release --product ilha-hook --arch "$arch"
done

mkdir -p "$ROOT/plugin/bin"
lipo -create \
  "$(swift build -c release --product ilha-hook --arch arm64 --show-bin-path)/ilha-hook" \
  "$(swift build -c release --product ilha-hook --arch x86_64 --show-bin-path)/ilha-hook" \
  -output "$ROOT/plugin/bin/ilha-hook"
chmod +x "$ROOT/plugin/bin/ilha-hook"

echo "ilha-hook universal copiado para $ROOT/plugin/bin/ilha-hook"
