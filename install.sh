#!/usr/bin/env bash
# claude-statusline installer.
# Copies statusline.sh into ~/.claude and wires up settings.json.
# Safe to re-run (idempotent). Backs up settings.json before editing.
#
# Usage:
#   ./install.sh                 # install; offer to install a Nerd Font
#   REFRESH=5 ./install.sh       # slower tick (refreshInterval seconds; default 1)
#   ./install.sh --nerd          # install JetBrainsMono Nerd Font (brew) + force icons
#   ./install.sh --no-nerd       # skip font, use ASCII/Unicode fallback
#   ./install.sh --uninstall     # remove the statusLine block (keeps script)
#   ./install.sh --dry-run       # show what would change, do nothing
set -euo pipefail

REFRESH=${REFRESH:-1}
NERD=${NERD:-ask}          # ask | yes | no  (whether to install the Nerd Font)
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
    --nerd) NERD=yes ;;
    --no-nerd) NERD=no ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || warn "jq not found — the status line needs it. Install: brew install jq / apt install jq"

mkdir -p "$CLAUDE_DIR"

# ---- Nerd Font detection + install ----------------------------------------
FONT_CASK="font-jetbrains-mono-nerd-font"
FONT_NAME="JetBrainsMono Nerd Font"

nerd_font_present() {
  if command -v fc-list >/dev/null 2>&1; then
    fc-list 2>/dev/null | grep -qiE 'nerd font|nerdfont'
  else
    ls "$HOME/Library/Fonts"/*[Nn]erd* /Library/Fonts/*[Nn]erd* 2>/dev/null | grep -q .
  fi
}

install_nerd_font() {
  if nerd_font_present; then
    info "a Nerd Font is already installed — good."
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    info "installing $FONT_NAME via Homebrew…"
    if [ "$DRY" = 1 ]; then info "[dry-run] brew install --cask $FONT_CASK"; return 0; fi
    brew install --cask "$FONT_CASK" && return 0
    warn "brew install failed — install a Nerd Font manually from https://nerdfonts.com"
    return 1
  fi
  warn "Homebrew not found. Install a Nerd Font manually:"
  warn "  macOS:  brew install --cask $FONT_CASK"
  warn "  Linux:  see https://github.com/ryanoasis/nerd-fonts#font-installation"
  return 1
}

# decide whether to install the font and whether to force icons on
FORCE_NERD=""     # "" = auto-detect at runtime ; "1"/"0" = force
if [ "$MODE" = install ]; then
  case "$NERD" in
    yes) install_nerd_font && FORCE_NERD=1 || FORCE_NERD=1 ;;   # user asked -> force icons
    no)  FORCE_NERD=0 ;;
    ask)
      if nerd_font_present; then
        info "Nerd Font detected — icons will be used automatically."
      elif [ "$DRY" = 1 ]; then
        info "[dry-run] would offer to install $FONT_NAME"
      elif [ -t 0 ]; then
        printf '\033[36m==>\033[0m Install %s for icon glyphs? [y/N] ' "$FONT_NAME"
        read -r ans
        case "$ans" in [yY]*) install_nerd_font && FORCE_NERD=1 ;; *) info "skipping font; using ASCII/Unicode fallback" ;; esac
      else
        info "no TTY — skipping font prompt (run with --nerd to install). Using auto-detect."
      fi
      ;;
  esac
  if [ -n "$FORCE_NERD" ]; then
    warn "After install, set your terminal profile font to \"$FONT_NAME\" to see the glyphs."
  fi
fi

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
# frame timing lines up with refreshInterval. If the user forced nerd on/off,
# bake CCSL_NERD in too; otherwise leave it to runtime auto-detect.
CMD="CCSL_REFRESH=$REFRESH"
[ -n "$FORCE_NERD" ] && CMD="$CMD CCSL_NERD=$FORCE_NERD"
CMD="$CMD ~/.claude/statusline.sh"
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
