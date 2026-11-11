#!/usr/bin/env bash
# Compila o IlhaApp universal em release e monta build/Work Island.app (pasta ignorada pelo git).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Versão do app = a do plugin (plugin.json), para os dois nunca divergirem; VERSION=… só no release.sh.
VERSION="${VERSION:-$(plutil -extract version raw -o - "$ROOT/plugin/.claude-plugin/plugin.json")}"
METRICS_URL="${METRICS_URL:-}"
# Escapa o endereço para o XML do Info.plist.
METRICS_URL_XML="${METRICS_URL//&/&amp;}"; METRICS_URL_XML="${METRICS_URL_XML//</&lt;}"; METRICS_URL_XML="${METRICS_URL_XML//>/&gt;}"

# App universal (arm64 + x86_64): uma compilação por arquitetura, juntas com lipo.
for arch in arm64 x86_64; do
  swift build -c release --product IlhaApp --arch "$arch"
done

APP="$ROOT/build/Work Island.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create \
  "$(swift build -c release --product IlhaApp --arch arm64 --show-bin-path)/IlhaApp" \
  "$(swift build -c release --product IlhaApp --arch x86_64 --show-bin-path)/IlhaApp" \
  -output "$APP/Contents/MacOS/WorkIsland"
chmod +x "$APP/Contents/MacOS/WorkIsland"

# O plugin (com o ilha-hook universal) vai dentro do app, em Contents/Resources/plugin/.
"$ROOT/scripts/build-plugin.sh"
mkdir -p "$APP/Contents/Resources"
cp -R "$ROOT/plugin" "$APP/Contents/Resources/plugin"

# Textos da interface (pt-BR e en): os .lproj ficam fora do alvo SwiftPM e entram aqui,
# antes da assinatura, que sela também Contents/Resources.
for lproj in "$ROOT"/Sources/IlhaApp/Resources/*.lproj; do
  for table in "$lproj"/*; do plutil -lint "$table" >/dev/null; done
  cp -R "$lproj" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>pt-BR</string>
	<key>CFBundleExecutable</key>
	<string>WorkIsland</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>pt-BR</string>
		<string>en</string>
	</array>
	<key>CFBundleIdentifier</key>
	<string>io.github.nickfrance.workisland</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Work Island</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>WorkIslandMetricsURL</key>
	<string>$METRICS_URL_XML</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Assinatura ad hoc do pacote inteiro (sela o Info.plist); não precisa de conta de desenvolvedor.
codesign --force --sign - "$APP"

echo "Work Island.app montado em $APP"
