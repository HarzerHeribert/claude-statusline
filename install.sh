#!/usr/bin/env bash
# claude-statusline installer.
# Copies statusline.sh into ~/.claude and wires up settings.json.
# Safe to re-run (idempotent). Backs up settings.json before editing.
#
# Usage:
#   ./install.sh                 # install with defaults (refreshInterval 10)
#   REFRESH=5 ./install.sh       # faster animation
#   ./install.sh --uninstall     # remove the statusLine block (keeps script)
#   ./install.sh --dry-run       # show what would change, do nothing
set -euo pipefail

REFRESH=${REFRESH:-10}
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$SRC_DIR/statusline.sh"
SCRIPT_DST="$CLAUDE_DIR/statusline.sh"

DRY=0; MODE=install
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || warn "jq not found — the status line needs it. Install: brew install jq / apt install jq"

mkdir -p "$CLAUDE_DIR"

# ---- uninstall ------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
  [ -f "$SETTINGS" ] || { info "no settings.json — nothing to remove"; exit 0; }
  if [ "$DRY" = 1 ]; then info "[dry-run] would remove .statusLine from $SETTINGS"; exit 0; fi
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  tmp=$(mktemp)
  jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  info "removed .statusLine from settings.json (script left at $SCRIPT_DST)"
  exit 0
fi

# ---- install script -------------------------------------------------------
if [ "$DRY" = 1 ]; then
  info "[dry-run] would copy $SCRIPT_SRC -> $SCRIPT_DST"
else
  install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"
  info "installed $SCRIPT_DST (mode 0755)"
fi

# ---- wire settings.json ---------------------------------------------------
# We point "command" at the script and set matching CCSL_REFRESH so animation
# frame timing lines up with refreshInterval.
CMD="CCSL_REFRESH=$REFRESH ~/.claude/statusline.sh"
BLOCK=$(cat <<JSON
{
  "type": "command",
  "command": "$CMD",
  "padding": 0,
  "refreshInterval": $REFRESH
}
JSON
)

if [ "$DRY" = 1 ]; then
  info "[dry-run] would set .statusLine to:"; echo "$BLOCK"; exit 0
fi

if [ ! -f "$SETTINGS" ]; then
  info "creating $SETTINGS"
  jq -n --argjson sl "$BLOCK" '{statusLine: $sl}' > "$SETTINGS"
else
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  info "backed up settings.json -> $(ls -t "$SETTINGS".bak.* | head -1)"
  tmp=$(mktemp)
  jq --argjson sl "$BLOCK" '.statusLine = $sl' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi

info "wired .statusLine (refreshInterval=$REFRESH)"
info "done — the status line appears on your next interaction with Claude Code."
info "test it:  echo '{\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":42}}' | $SCRIPT_DST"
