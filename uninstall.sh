#!/bin/bash
# Work Island uninstaller.
#   curl -fsSL https://raw.githubusercontent.com/nickfrance/work-island/main/uninstall.sh | bash
#
# Test-only environment variables:
#   WORK_ISLAND_APPS_DIR=<dir>         where the app is (default: /Applications, then ~/Applications)
#   WORK_ISLAND_SKIP_APP_UNINSTALL=1   skip the app's own --uninstall and keep the data folder
#   WORK_ISLAND_NO_KILL=1              do not quit a running Work Island
set -euo pipefail

main() {
  local app_name="Work Island.app" removed=()
  local dirs=()
  if [ -n "${WORK_ISLAND_APPS_DIR:-}" ]; then
    dirs=("$WORK_ISLAND_APPS_DIR")
  else
    dirs=("/Applications" "$HOME/Applications")
  fi

  # 1. The app removes its own login item and Claude Code plugin (30 s limit)
  local dir
  if [ "${WORK_ISLAND_SKIP_APP_UNINSTALL:-0}" != "1" ]; then
    local exe found_app=0
    for dir in "${dirs[@]}"; do
      exe="$dir/$app_name/Contents/MacOS/WorkIsland"
      if [ -x "$exe" ]; then
        "$exe" --uninstall >/dev/null 2>&1 &
        local pid=$! waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
          sleep 1
          waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
        wait "$pid" 2>/dev/null || true
        removed+=("login item and Claude Code plugin")
        found_app=1
        break
      fi
    done
    # App already gone: remove the Claude Code plugin directly (errors ignored)
    if [ "$found_app" -eq 0 ]; then
      local claude="" candidate
      for candidate in \
        "$HOME/.local/bin/claude" \
        "$HOME/.claude/local/claude" \
        "/opt/homebrew/bin/claude" \
        "/usr/local/bin/claude"; do
        if [ -x "$candidate" ]; then claude="$candidate"; break; fi
      done
      if [ -z "$claude" ]; then
        for candidate in "$HOME"/Library/Application\ Support/Claude/claude-code/*/*/claude.app/Contents/MacOS/claude; do
          if [ -x "$candidate" ]; then claude="$candidate"; break; fi
        done
      fi
      if [ -n "$claude" ]; then
        "$claude" plugin uninstall work-island >/dev/null 2>&1 || true
        "$claude" plugin marketplace remove work-island >/dev/null 2>&1 || true
        removed+=("Claude Code plugin")
      fi
    fi
  fi

  # 2. Quit the running app (up to 5 s) before deleting it and its data
  if [ "${WORK_ISLAND_NO_KILL:-0}" != "1" ]; then
    pkill -TERM -x WorkIsland || true
    local waited_kill=0
    while pgrep -x WorkIsland >/dev/null 2>&1 && [ "$waited_kill" -lt 5 ]; do
      sleep 1
      waited_kill=$((waited_kill + 1))
    done
  fi

  # 3. Delete the app
  for dir in "${dirs[@]}"; do
    if [ -e "$dir/$app_name" ]; then
      rm -rf "$dir/$app_name"
      removed+=("$dir/$app_name")
    fi
  done

  # 4. Delete its data
  if [ "${WORK_ISLAND_SKIP_APP_UNINSTALL:-0}" != "1" ]; then
    local data="$HOME/Library/Application Support/Work Island"
    if [ -e "$data" ]; then
      rm -rf "$data"
      removed+=("$data")
    fi
  fi

  # 5. Report
  if [ "${#removed[@]}" -eq 0 ]; then
    echo "Nothing to remove: Work Island is not installed."
  else
    echo "Removed:"
    local item
    for item in "${removed[@]}"; do echo "  - $item"; done
  fi
}

main "$@"
