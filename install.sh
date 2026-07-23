#!/usr/bin/env bash
# claude-statusline installer.
# Copies statusline.sh into ~/.claude and wires up settings.json.
# Cross-platform: Linux (all major distros), macOS, Windows (Git Bash / WSL).
# Safe to re-run (idempotent). Backs up settings.json before editing.
#
# One-line install (no clone needed — downloads statusline.sh for you):
#   curl -fsSL https://raw.githubusercontent.com/HarzerHeribert/claude-statusline/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --no-nerd   # pass flags after --
#   curl -fsSL .../install.sh | REFRESH=5 bash          # pass env vars
#
# Local usage (from a clone):
#   ./install.sh                 # install; offer to install a Nerd Font
#   REFRESH=5 ./install.sh       # slower tick (refreshInterval seconds; default 1)
#   ./install.sh --nerd          # install JetBrainsMono Nerd Font + force icons
#   ./install.sh --no-nerd       # skip font, use ASCII/Unicode fallback
#   ./install.sh --uninstall     # remove the statusLine block (keeps script)
#   ./install.sh --dry-run       # show what would change, do nothing
#
# Env:
#   REFRESH=1                    # refreshInterval seconds (default 1)
#   NERD=ask|yes|no              # whether to install the Nerd Font
#   CLAUDE_CONFIG_DIR=~/.claude  # config dir override
#   CCSL_RAW_BASE=<url>          # base URL to fetch statusline.sh from (bootstrap)
set -euo pipefail

REFRESH=${REFRESH:-1}
NERD=${NERD:-ask}          # ask | yes | no  (whether to install the Nerd Font)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
RAW_BASE="${CCSL_RAW_BASE:-https://raw.githubusercontent.com/HarzerHeribert/claude-statusline/main}"

# When run from a clone/local checkout, $0 points at this file and statusline.sh
# sits beside it. When piped (curl | bash), $0 is "bash"/"-" and there's no
# source dir — we detect that and download statusline.sh from RAW_BASE instead.
SELF="${BASH_SOURCE[0]:-$0}"
SRC_DIR=""            # set only when a real local checkout is found
SCRIPT_SRC=""         # set to the local statusline.sh, else downloaded later
# A real checkout has statusline.sh sitting next to this file. Process-substitution
# (bash <(curl …)) and pipes give $SELF as /dev/fd/* or "bash"/"-", where no sibling
# exists — in those cases we fall through to downloading statusline.sh from RAW_BASE.
case "$SELF" in
  /dev/fd/*|/proc/self/fd/*|bash|-|"") : ;;   # piped / substituted: no checkout
  *)
    if [ -f "$SELF" ]; then
      _sd="$(cd "$(dirname "$SELF")" && pwd)"
      if [ -f "$_sd/statusline.sh" ]; then SRC_DIR="$_sd"; SCRIPT_SRC="$_sd/statusline.sh"; fi
    fi ;;
esac
SCRIPT_DST="$CLAUDE_DIR/statusline.sh"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/install.sh" ]; then
    grep '^#' "$SRC_DIR/install.sh" | sed 's/^# \{0,1\}//'
  else
    printf '%s\n' \
      "claude-statusline installer" \
      "  --nerd | --no-nerd   install / skip the Nerd Font" \
      "  --uninstall          remove the statusLine block" \
      "  --dry-run            show what would change, do nothing" \
      "  -h | --help          this help" \
      "Env: REFRESH, NERD=ask|yes|no, CLAUDE_CONFIG_DIR, CCSL_RAW_BASE"
  fi
}

DRY=0; MODE=install
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --uninstall) MODE=uninstall ;;
    --nerd) NERD=yes ;;
    --no-nerd) NERD=no ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# ---- platform detection ---------------------------------------------------
# OS ∈ macos | linux | windows.  WSL counts as linux (it has fontconfig and a
# native package manager). PKG is the first available Linux package manager.
detect_os() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    Linux)
      OS=linux
      # WSL still reports Linux from uname; keep it as linux (correct behavior).
      ;;
    *) OS=linux ;;   # unknown unix -> treat as linux (safest fallback)
  esac
}
detect_pkg() {
  PKG=""; PKG_CMD=""
  case "$OS" in
    macos) managers=(brew port) ;;
    windows) managers=(choco choco.exe winget winget.exe scoop scoop.cmd pacman) ;;
    *) managers=(apt-get dnf yum pacman zypper apk brew) ;;
  esac
  for p in "${managers[@]}"; do
    if command -v "$p" >/dev/null 2>&1; then
      PKG_CMD="$p"
      case "$p" in
        choco.exe) PKG=choco ;;
        winget.exe) PKG=winget ;;
        scoop.cmd) PKG=scoop ;;
        *) PKG="$p" ;;
      esac
      break
    fi
  done
}
# Map a command we need to the package name/id used by the detected manager.
pkg_for_tool() {  # $1 = command name
  case "$PKG:$1" in
    winget:jq) echo "jqlang.jq" ;;
    winget:git) echo "Git.Git" ;;
    winget:curl) echo "cURL.cURL" ;;
    winget:*) echo "" ;;
    *:fc-cache|*:fc-list) echo "fontconfig" ;;
    *:*) echo "$1" ;;
  esac
}
# Suggest the correct install command for the detected package manager.
pkg_install_hint() {  # $1 = command name
  local pkg; pkg=$(pkg_for_tool "$1")
  [ -z "$pkg" ] && { echo "install $1 from $(tool_url "$1")"; return; }
  case "$PKG" in
    apt-get) echo "sudo apt-get install -y $pkg" ;;
    dnf)     echo "sudo dnf install -y $pkg" ;;
    yum)     echo "sudo yum install -y $pkg" ;;
    pacman)  echo "sudo pacman -S --noconfirm $pkg" ;;
    zypper)  echo "sudo zypper --non-interactive install $pkg" ;;
    apk)     echo "sudo apk add $pkg" ;;
    brew)    echo "brew install $pkg" ;;
    port)    echo "sudo port install $pkg" ;;
    choco)   echo "choco install -y $pkg" ;;
    winget)  echo "winget install --accept-package-agreements --accept-source-agreements -e --id $pkg" ;;
    scoop)   echo "scoop install $pkg" ;;
    *)       echo "install $pkg with your package manager" ;;
  esac
}
# Official download pages when no supported package manager is available.
tool_url() {  # $1 = command name
  case "$1" in
    jq) echo "https://jqlang.github.io/jq/download/" ;;
    git) echo "https://git-scm.com/downloads" ;;
    curl) echo "https://curl.se/download.html" ;;
    wget) echo "https://www.gnu.org/software/wget/" ;;
    unzip) echo "https://infozip.sourceforge.net/UnZip.html" ;;
    fc-cache|fc-list) echo "https://www.freedesktop.org/wiki/Software/fontconfig/" ;;
    *) echo "https://github.com/HarzerHeribert/claude-statusline" ;;
  esac
}
# Run a privileged command: as-is if root, via sudo if available, else print it.
as_root() {  # "$@" = command to run
  if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else warn "need root to run: $*"; warn "re-run as root or with sudo"; return 1; fi
}
APT_UPDATED=0
pkg_update_once() {
  if [ "$PKG" = apt-get ] && [ "$APT_UPDATED" = 0 ]; then
    as_root apt-get update && APT_UPDATED=1
  fi
}
install_pkg() {  # $1 = command name, installed as mapped package
  local tool="$1" pkg
  pkg=$(pkg_for_tool "$tool")
  [ -n "$pkg" ] || { warn "no package mapping for $tool with $PKG; download: $(tool_url "$tool")"; return 1; }
  info "installing $tool via $PKG…"
  [ "$DRY" = 1 ] && { info "[dry-run] $(pkg_install_hint "$tool")"; return 0; }
  case "$PKG" in
    apt-get) pkg_update_once && as_root apt-get install -y "$pkg" ;;
    dnf)     as_root dnf install -y "$pkg" ;;
    yum)     as_root yum install -y "$pkg" ;;
    pacman)  as_root pacman -S --noconfirm "$pkg" ;;
    zypper)  as_root zypper --non-interactive install "$pkg" ;;
    apk)     as_root apk add "$pkg" ;;
    brew)    brew install "$pkg" ;;
    port)    as_root port install "$pkg" ;;
    choco)   "$PKG_CMD" install -y "$pkg" ;;
    winget)  "$PKG_CMD" install --accept-package-agreements --accept-source-agreements -e --id "$pkg" ;;
    scoop)   "$PKG_CMD" install "$pkg" ;;
    *)       return 1 ;;
  esac
}
ensure_tool() {  # $1 = command name
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 && return 0
  if [ -n "$PKG" ]; then
    install_pkg "$tool" && { command -v "$tool" >/dev/null 2>&1 || [ "$DRY" = 1 ]; } && return 0
    warn "$tool is still unavailable after package-manager install. Open a new shell or install manually: $(tool_url "$tool")"
  else
    warn "no supported package manager detected for missing $tool. Download/install it from: $(tool_url "$tool")"
  fi
  return 1
}
ensure_downloader() {
  { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } && return 0
  ensure_tool curl || ensure_tool wget
}
ensure_minimal_prereqs() {
  local fail=0
  ensure_tool jq || fail=1
  ensure_tool git || fail=1
  # A downloader is only a hard prerequisite when there is no local statusline.sh
  # to copy (curl|bash / process substitution), or when the user asks for fonts.
  if [ -z "$SCRIPT_SRC" ] || [ ! -f "$SCRIPT_SRC" ] || [ "$NERD" = yes ]; then
    ensure_downloader || fail=1
  fi
  [ "$DRY" = 1 ] && return 0
  [ "$fail" = 0 ] || die "missing prerequisites above; install them and re-run"
}
# Download a URL to a path. Prefers curl, falls back to wget. Returns nonzero on failure.
download() {  # $1 = url, $2 = dest path
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else return 127; fi
}

detect_os
detect_pkg

if [ "$MODE" = install ]; then
  ensure_minimal_prereqs
elif [ -f "$SETTINGS" ]; then
  ensure_tool jq || { [ "$DRY" = 1 ] || die "jq is required to edit $SETTINGS"; }
fi

mkdir -p "$CLAUDE_DIR"

# ---- Nerd Font detection + install ----------------------------------------
FONT_CASK="font-jetbrains-mono-nerd-font"
FONT_NAME="JetBrainsMono Nerd Font"
# Direct zip of the JetBrainsMono Nerd Font from the ryanoasis/nerd-fonts release.
FONT_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"

nerd_font_present() {
  if command -v fc-list >/dev/null 2>&1; then
    fc-list 2>/dev/null | grep -qiE 'nerd font|nerdfont'
  else
    # macOS font dirs, plus Windows font dirs when on Git Bash / MSYS.
    ls "$HOME/Library/Fonts"/*[Nn]erd* /Library/Fonts/*[Nn]erd* \
       "${WINDIR:-/c/Windows}/Fonts"/*[Nn]erd* \
       "${LOCALAPPDATA:-}/Microsoft/Windows/Fonts"/*[Nn]erd* 2>/dev/null \
       | grep -q .
  fi
}

# Download + unzip the Nerd Font zip into a temp dir. Echoes the temp dir on
# success (caller installs the .ttf files); returns nonzero on any failure.
fetch_font_zip() {
  ensure_downloader || { warn "install curl or wget, or download the font manually: https://nerdfonts.com"; return 1; }
  ensure_tool unzip || { warn "install unzip, or download the font manually: https://nerdfonts.com"; return 1; }
  local tmp; tmp=$(mktemp -d)
  if [ "$DRY" = 1 ]; then info "[dry-run] download $FONT_ZIP_URL and unzip into a temp dir"; echo "$tmp"; return 0; fi
  download "$FONT_ZIP_URL" "$tmp/font.zip" || { warn "font download failed (need curl or wget)"; rm -rf "$tmp"; return 1; }
  unzip -qo "$tmp/font.zip" -d "$tmp" || { warn "unzip failed"; rm -rf "$tmp"; return 1; }
  echo "$tmp"
}

install_nerd_font_linux() {
  # Prefer a distro package where a real Nerd Font package exists, else manual.
  case "$PKG" in
    pacman)
      info "installing $FONT_NAME via pacman…"
      [ "$DRY" = 1 ] && { info "[dry-run] $(pkg_install_hint ttf-jetbrains-mono-nerd)"; return 0; }
      as_root pacman -S --noconfirm ttf-jetbrains-mono-nerd && return 0
      warn "pacman install failed — falling back to manual download" ;;
  esac
  # Manual: drop .ttf into ~/.local/share/fonts and refresh the font cache.
  info "installing $FONT_NAME into ~/.local/share/fonts…"
  local dir="$HOME/.local/share/fonts" tmp
  tmp=$(fetch_font_zip) || return 1
  if [ "$DRY" = 1 ]; then info "[dry-run] copy *.ttf -> $dir && fc-cache -f"; rm -rf "$tmp"; return 0; fi
  mkdir -p "$dir"
  cp "$tmp"/*.ttf "$dir"/ 2>/dev/null || cp "$tmp"/**/*.ttf "$dir"/ 2>/dev/null
  rm -rf "$tmp"
  if command -v fc-cache >/dev/null 2>&1 || ensure_tool fc-cache; then
    fc-cache -f "$dir" >/dev/null 2>&1 || warn "fc-cache failed; the font may appear after restarting your terminal"
  fi
  info "font installed. Select \"$FONT_NAME\" in your terminal profile to see glyphs."
  return 0
}

install_nerd_font_macos() {
  if command -v brew >/dev/null 2>&1; then
    info "installing $FONT_NAME via Homebrew…"
    [ "$DRY" = 1 ] && { info "[dry-run] brew install --cask $FONT_CASK"; return 0; }
    brew install --cask "$FONT_CASK" && return 0
    warn "brew install failed — falling back to manual download"
  fi
  # Manual: copy .ttf into ~/Library/Fonts (no fc-cache needed on macOS).
  local dir="$HOME/Library/Fonts" tmp
  tmp=$(fetch_font_zip) || { warn "install manually: brew install --cask $FONT_CASK"; return 1; }
  if [ "$DRY" = 1 ]; then info "[dry-run] copy *.ttf -> $dir"; rm -rf "$tmp"; return 0; fi
  mkdir -p "$dir"; cp "$tmp"/*.ttf "$dir"/ 2>/dev/null; rm -rf "$tmp"
  info "font installed. Select \"$FONT_NAME\" in your terminal profile."
  return 0
}

install_nerd_font_windows() {
  # Best-effort from Git Bash / MSYS: drop .ttf into the per-user font dir.
  local dir="${LOCALAPPDATA:-}/Microsoft/Windows/Fonts" tmp
  tmp=$(fetch_font_zip) || return 1
  if [ "$DRY" = 1 ]; then info "[dry-run] copy *.ttf -> $dir (per-user fonts)"; rm -rf "$tmp"; return 0; fi
  if [ -n "${LOCALAPPDATA:-}" ]; then
    mkdir -p "$dir"; cp "$tmp"/*.ttf "$dir"/ 2>/dev/null
    info "copied fonts into $dir"
    warn "Windows may require registering the font: right-click each .ttf > Install,"
    warn "or run in PowerShell as admin. Then select \"$FONT_NAME\" in your terminal."
  else
    warn "LOCALAPPDATA unset — extracted fonts to: $tmp"
    warn "Install them manually (right-click each .ttf > Install)."
  fi
  return 0
}

install_nerd_font() {
  if nerd_font_present; then
    info "a Nerd Font is already installed — good."
    return 0
  fi
  case "$OS" in
    macos)   install_nerd_font_macos ;;
    windows) install_nerd_font_windows ;;
    *)       install_nerd_font_linux ;;
  esac
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
  if [ "$FORCE_NERD" = 1 ]; then
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

# ---- resolve statusline.sh source (download when piped, no local checkout) --
BOOT_TMP=""
if [ -z "$SCRIPT_SRC" ] || [ ! -f "$SCRIPT_SRC" ]; then
  if [ "$DRY" = 1 ]; then
    info "[dry-run] would download statusline.sh from $RAW_BASE/statusline.sh"
    SCRIPT_SRC="<downloaded>"
  else
    info "no local statusline.sh — downloading from $RAW_BASE"
    BOOT_TMP=$(mktemp)
    download "$RAW_BASE/statusline.sh" "$BOOT_TMP" \
      || die "could not download statusline.sh (need curl or wget, and network access)"
    [ -s "$BOOT_TMP" ] || die "downloaded statusline.sh is empty — check $RAW_BASE"
    SCRIPT_SRC="$BOOT_TMP"
  fi
fi
trap '[ -n "${BOOT_TMP:-}" ] && rm -f "$BOOT_TMP"' EXIT

# ---- install script -------------------------------------------------------
if [ "$DRY" = 1 ]; then
  info "[dry-run] would copy $SCRIPT_SRC -> $SCRIPT_DST"
else
  # `install` isn't everywhere (some minimal Windows shells); fall back to cp+chmod.
  if command -v install >/dev/null 2>&1; then
    install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"
  else
    cp "$SCRIPT_SRC" "$SCRIPT_DST" && chmod 0755 "$SCRIPT_DST"
  fi
  info "installed $SCRIPT_DST (mode 0755)"
fi

# ---- wire settings.json ---------------------------------------------------
# The script needs no frame-rate hint: motion advances off an invocation
# counter, so it self-adjusts to whatever rate Claude Code actually re-renders
# at. If the user forced nerd on/off, bake CCSL_NERD in; otherwise leave it to
# runtime auto-detect.
CMD=""
[ -n "$FORCE_NERD" ] && CMD="CCSL_NERD=$FORCE_NERD "
CMD="$CMD~/.claude/statusline.sh"
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
