#!/bin/bash
# Work Island installer.
#   curl -fsSL https://raw.githubusercontent.com/nickfrance/work-island/main/install.sh | bash
#
# Test-only environment variables:
#   WORK_ISLAND_RELEASE_API  release JSON URL (default: GitHub "latest release" API)
#   WORK_ISLAND_APPS_DIR     install folder (default: /Applications, else ~/Applications)
#   WORK_ISLAND_NO_OPEN=1    do not open the app after installing
#   WORK_ISLAND_NO_KILL=1    do not quit a running Work Island before replacing it
set -euo pipefail

main() {
  local api="${WORK_ISLAND_RELEASE_API:-https://api.github.com/repos/nickfrance/work-island/releases/latest}"
  local app_name="Work Island.app"

  # 1. macOS 15 or newer
  local os_major
  os_major="$(sw_vers -productVersion | cut -d. -f1)"
  if [ "$os_major" -lt 15 ]; then
    echo "Work Island needs macOS 15 or newer (this Mac has $(sw_vers -productVersion))." >&2
    exit 1
  fi

  # 2. Claude Code (same places the app looks); only a warning
  local found_claude=0 candidate
  for candidate in \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/local/claude" \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude"; do
    if [ -x "$candidate" ]; then found_claude=1; break; fi
  done
  if [ "$found_claude" -eq 0 ]; then
    local bundled
    for bundled in "$HOME"/Library/Application\ Support/Claude/claude-code/*/*/claude.app/Contents/MacOS/claude; do
      if [ -x "$bundled" ]; then found_claude=1; break; fi
    done
  fi
  if [ "$found_claude" -eq 0 ]; then
    echo "Claude Code not found. Install it before using Work Island."
  fi

  # 3. Find the release asset and its digest
  tmp=""
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT

  echo "Looking for the latest release..."
  curl -fsSL "$api" -o "$tmp/release.json"

  local i=0 name url="" digest=""
  while name="$(plutil -extract "assets.$i.name" raw -o - - < "$tmp/release.json" 2>/dev/null)"; do
    if [ "$name" = "WorkIsland.zip" ]; then
      url="$(plutil -extract "assets.$i.browser_download_url" raw -o - - < "$tmp/release.json")"
      digest="$(plutil -extract "assets.$i.digest" raw -o - - < "$tmp/release.json" 2>/dev/null || true)"
      break
    fi
    i=$((i + 1))
  done
  if [ -z "$url" ]; then
    echo "The latest release has no WorkIsland.zip." >&2
    exit 1
  fi
  case "$digest" in
    sha256:*) digest="${digest#sha256:}" ;;
    *) echo "The release has no SHA-256 digest for WorkIsland.zip; refusing to install." >&2; exit 1 ;;
  esac

  # 4. Download and verify
  echo "Downloading..."
  curl -fsSL "$url" -o "$tmp/WorkIsland.zip"
  local actual
  actual="$(shasum -a 256 "$tmp/WorkIsland.zip" | awk '{print $1}')"
  if [ "$actual" != "$digest" ]; then
    echo "Checksum mismatch: the download is corrupt or was tampered with. Nothing was installed." >&2
    exit 1
  fi

  # Unpack to a temporary folder before touching the installed app
  mkdir -p "$tmp/unpacked"
  ditto -x -k "$tmp/WorkIsland.zip" "$tmp/unpacked"
  if [ ! -d "$tmp/unpacked/$app_name" ]; then
    echo "The download does not contain $app_name. Nothing was installed." >&2
    exit 1
  fi

  # Install folder: /Applications, or ~/Applications when it is not writable
  local apps_dir="${WORK_ISLAND_APPS_DIR:-/Applications}"
  if [ -z "${WORK_ISLAND_APPS_DIR:-}" ] && [ ! -w "$apps_dir" ]; then
    apps_dir="$HOME/Applications"
    mkdir -p "$apps_dir"
    echo "/Applications is not writable; installing to $apps_dir instead."
  fi
  mkdir -p "$apps_dir"

  # 5. Quit the running app (up to 5 s)
  if [ "${WORK_ISLAND_NO_KILL:-0}" != "1" ]; then
    pkill -TERM -x WorkIsland || true
    local waited=0
    while pgrep -x WorkIsland >/dev/null 2>&1 && [ "$waited" -lt 5 ]; do
      sleep 1
      waited=$((waited + 1))
    done
  fi

  # 6. Replace the app: copy next to the target first, then swap with mv
  local target="$apps_dir/$app_name" staging="$apps_dir/.Work Island.app.new"
  rm -rf "$staging"
  ditto "$tmp/unpacked/$app_name" "$staging"
  rm -rf "$target"
  mv "$staging" "$target"

  # 7. Open
  if [ "${WORK_ISLAND_NO_OPEN:-0}" != "1" ]; then
    open "$target"
  fi

  # 8. Summary
  echo
  echo "Work Island installed at: $target"
  echo "The Claude Code plugin and the login item are set up the first time the app opens."
  echo "Work Island sends anonymous usage metrics (time open, clicks; nothing from your conversations, folders or account); turn them off in Settings."
  echo "To uninstall: curl -fsSL https://raw.githubusercontent.com/nickfrance/work-island/main/uninstall.sh | bash"
}

main "$@"
