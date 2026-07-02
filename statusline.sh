#!/usr/bin/env bash
# claude-statusline — a verbose, wide, no-emoji, animated status line for Claude Code.
# https://github.com/HarzerHeribert/claude-statusline
#
# Reads session JSON on stdin (schema: https://code.claude.com/docs/en/statusline)
# and prints two full-width rows, left/right justified to fill the terminal:
#   row 1: identity + git + PR ......................... rate limits (right)
#   row 2: [context bar] ctx tokens .......... cost / lines / durations (right)
#
# ANIMATION (tick-based; requires "refreshInterval" in settings.json):
#   - spinner while the API is actively responding
#   - shimmer: a bright cell sweeps across the filled context bar
#   - wave: a scrolling color gradient across the filled bar
#   - pulse: the filled bar breathes (dim<->bright) each cycle
#   - warn: high context/rate-limit and "changes requested" segments blink
#   - marquee (opt-in): cycles the right rail of row 2 through stats
#   - sep (opt-in): the :: / | separators cycle subtly
# Frames advance off wall-clock time, so no persistent frame state is needed.
# The rendered frame rate is capped at 1s by Claude Code (refreshInterval min = 1);
# these animations make each tick cheap, they can't exceed that 1 fps ceiling.
#
# DECOUPLING (data vs animation):
#   The harness only changes the stdin payload when real data changes. We hash it
#   and cache the parsed values; an unchanged tick skips jq AND git entirely and
#   just re-renders the animation from the frame counter. See CCSL_DECOUPLE.
#
# NOTES:
#   - context_window.used_percentage is input-only (matches /context), authoritative.
#   - cost.total_cost_usd is a CLIENT-SIDE ESTIMATE, not your bill -> shown as "~$".
#     The real budget signal on Pro/Max is rate_limits.* (subscribers only).
#
# CONFIG (env vars, override in settings.json "command" or your shell profile):
#   CCSL_ANIM=1            master switch for all animation (0 disables)
#   CCSL_SPINNER=1         spinner while API busy
#   CCSL_SHIMMER=1         sweeping bright cell in the context bar
#   CCSL_WAVE=1            scrolling gradient in the bar (else plain shimmer)
#   CCSL_PULSE=1           breathing intensity on the context bar
#   CCSL_WARN_ANIM=1       blink high-usage / changes-requested segments
#   CCSL_SEP_ANIM=0        animate :: / | separators (subtle)
#   CCSL_MARQUEE=0         cycle right rail of row 2 (off by default; shows all at once)
#   CCSL_DECOUPLE=1        skip jq/git on unchanged ticks (cache parsed data)
#   CCSL_DATA_TTL=5        max seconds to trust the data snapshot
#   CCSL_GIT_TTL=2         seconds to cache git state between ticks
#   CCSL_REFRESH=10        must match settings.json refreshInterval (for frame timing)
#   CCSL_BAR_MAX=60        max context-bar width in chars
#   CCSL_COLOR=1           colored output (0 = plain)
#   CCSL_COLOR256=auto     256-color ramp for the wave when the terminal supports it
#   CCSL_ASCII=0           1 = use ASCII bar chars (#/-) instead of block glyphs
#   CCSL_NERD=auto         auto|1|0 use Nerd Font glyphs for icons
set -u

input=$(cat)

# --- config with defaults --------------------------------------------------
CCSL_ANIM=${CCSL_ANIM:-1}
CCSL_SPINNER=${CCSL_SPINNER:-1}
CCSL_SHIMMER=${CCSL_SHIMMER:-1}
CCSL_MARQUEE=${CCSL_MARQUEE:-0}
CCSL_REFRESH=${CCSL_REFRESH:-10}
CCSL_BAR_MAX=${CCSL_BAR_MAX:-60}
CCSL_COLOR=${CCSL_COLOR:-1}
CCSL_ASCII=${CCSL_ASCII:-0}
CCSL_NERD=${CCSL_NERD:-auto}   # auto | 1 | 0 : use Nerd Font glyphs for icons
CCSL_GIT_TTL=${CCSL_GIT_TTL:-2}  # seconds to cache git state between ticks
# --- decouple: skip jq/git when the payload hasn't changed -----------------
CCSL_DECOUPLE=${CCSL_DECOUPLE:-1}   # 1 = cache parsed data; unchanged ticks skip jq
CCSL_DATA_TTL=${CCSL_DATA_TTL:-5}   # max seconds to trust the data snapshot
# --- extra animations (all within the 1s cadence, width-invariant) ---------
CCSL_PULSE=${CCSL_PULSE:-1}         # breathing intensity on the context bar
CCSL_WAVE=${CCSL_WAVE:-1}           # scrolling gradient in the bar (else shimmer)
CCSL_WARN_ANIM=${CCSL_WARN_ANIM:-1} # blink high-usage / changes-requested segments
CCSL_SEP_ANIM=${CCSL_SEP_ANIM:-0}   # animate :: / | separators (subtle)
CCSL_COLOR256=${CCSL_COLOR256:-auto} # 256-color ramp for the wave when supported
[ "$CCSL_ANIM" = "0" ] && { CCSL_SPINNER=0; CCSL_SHIMMER=0; CCSL_MARQUEE=0; \
  CCSL_PULSE=0; CCSL_WAVE=0; CCSL_WARN_ANIM=0; CCSL_SEP_ANIM=0; }

# --- terminal width (harness sets COLUMNS; fall back sanely) ----------------
# The status bar can't use the full terminal width: the harness reserves a
# right-hand margin for its own notifications (token counter, MCP errors) and
# the row has built-in side padding. Subtract CCSL_MARGIN so the right rail
# never touches the true edge and get clipped.
CCSL_MARGIN=${CCSL_MARGIN:-6}
COLS=${COLUMNS:-0}
[ "$COLS" -lt 40 ] 2>/dev/null && COLS=120
[ "$COLS" -gt 300 ] 2>/dev/null && COLS=300
COLS=$(( COLS - CCSL_MARGIN ))
[ "$COLS" -lt 40 ] && COLS=40

if ! command -v jq >/dev/null 2>&1; then
  # graceful fallback: no jq -> just echo the model name we can grep out
  m=$(printf '%s' "$input" | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "${m:-claude} :: (install jq for the full status line)"
  exit 0
fi

# --- frame counter (needed here for the data-cache TTL) --------------------
NOW=$(date +%s)
[ "$CCSL_REFRESH" -lt 1 ] 2>/dev/null && CCSL_REFRESH=1
FRAME=$(( NOW / CCSL_REFRESH ))

# ==========================================================================
# PHASE A -- DATA  (jq + git; skipped entirely on an unchanged tick)
# ==========================================================================
# The harness only changes the JSON payload when real data changes. So we hash
# stdin and, if it matches the last snapshot (and the snapshot is fresh), we
# source the cached KEY=VAL vars and skip jq AND git. A pure-animation tick then
# costs a cksum + a source -- no subprocess parsing at all. The rendered frame
# rate is still capped at 1s by the harness; this just makes each tick cheap.

# Cheap session id for the cache key, without jq (grep the raw payload).
SESSID=$(printf '%s' "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$SESSID" ] && SESSID=nosess
DATA_CACHE="${TMPDIR:-/tmp}/ccsl-data-${SESSID}"

# Hash the payload (fast, non-crypto is fine — we only need change detection).
HASH=$(printf '%s' "$input" | cksum | tr -d ' ')

data_fresh=0
if [ "$CCSL_DECOUPLE" = "1" ] && [ -f "$DATA_CACHE" ]; then
  MT=$(stat -f %m "$DATA_CACHE" 2>/dev/null || stat -c %Y "$DATA_CACHE" 2>/dev/null || echo 0)
  AGE=$(( NOW - MT ))
  # first line of the snapshot is "# <hash>"; compare without sourcing.
  CACHED_HASH=$(head -1 "$DATA_CACHE" 2>/dev/null)
  if [ "$CACHED_HASH" = "# $HASH" ] && [ "$AGE" -lt "$CCSL_DATA_TTL" ]; then
    data_fresh=1
  fi
fi

if [ "$data_fresh" = "1" ]; then
  # unchanged tick: reuse everything, no jq, no git.
  . "$DATA_CACHE" 2>/dev/null
  # guard against a partial/corrupt snapshot: if any required var is unset,
  # discard and fall through to a fresh parse (${x+s} is safe under set -u).
  for k in MODEL CTX_PCT CTX_SIZE COST DUR_MS API_MS RL5 RL7 GIT_OK; do
    eval "[ -n \"\${$k+s}\" ]" || { data_fresh=0; break; }
  done
fi
if [ "$data_fresh" != "1" ]; then
  # changed tick (or cache disabled/stale): parse the payload with jq.
  eval "$(printf '%s' "$input" | jq -r '
    def q: @sh;
    "MODEL="     + ((.model.display_name // "?") | q),
    "EFFORT="    + ((.effort.level // "") | q),
    "THINKING="  + ((if .thinking.enabled then "1" else "" end) | q),
    "CTX_PCT="   + ((.context_window.used_percentage // 0 | floor) | tostring | q),
    "CTX_IN="    + ((.context_window.total_input_tokens // 0) | tostring | q),
    "CTX_SIZE="  + ((.context_window.context_window_size // 200000) | tostring | q),
    "COST="      + ((.cost.total_cost_usd // 0) | tostring | q),
    "DUR_MS="    + ((.cost.total_duration_ms // 0) | tostring | q),
    "API_MS="    + ((.cost.total_api_duration_ms // 0) | tostring | q),
    "ADDED="     + ((.cost.total_lines_added // 0) | tostring | q),
    "REMOVED="   + ((.cost.total_lines_removed // 0) | tostring | q),
    "RL5="       + ((.rate_limits.five_hour.used_percentage // -1) | tostring | q),
    "RL5_RESET=" + ((.rate_limits.five_hour.resets_at // 0) | tostring | q),
    "RL7="       + ((.rate_limits.seven_day.used_percentage // -1) | tostring | q),
    "RL7_RESET=" + ((.rate_limits.seven_day.resets_at // 0) | tostring | q),
    "PR_NUM="    + ((.pr.number // "") | tostring | q),
    "PR_STATE="  + ((.pr.review_state // "") | q),
    "OUTSTYLE="  + ((.output_style.name // "default") | q),
    "SESSNAME="  + ((.session_name // "") | q),
    "SESSID="    + ((.session_id // "nosess") | q)
  ')"

  # git state (also cached on its own shorter TTL; folded into the snapshot).
  GIT_OK=0; BRANCH=""; DIR=""; STAGED=0; MODIFIED=0; UNTRACKED=0; AHEAD=0; BEHIND=0
  if git rev-parse --git-dir >/dev/null 2>&1; then
    GIT_OK=1
    GTOP=$(git rev-parse --show-toplevel 2>/dev/null)
    GKEY=$(printf '%s' "${SESSID}:${GTOP}" | cksum | cut -d' ' -f1)
    GCACHE="${TMPDIR:-/tmp}/ccsl-git-${GKEY}"
    GAGE=999
    if [ -f "$GCACHE" ]; then
      GMT=$(stat -f %m "$GCACHE" 2>/dev/null || stat -c %Y "$GCACHE" 2>/dev/null || echo 0)
      GAGE=$(( NOW - GMT ))
    fi
    if [ "$GAGE" -ge "$CCSL_GIT_TTL" ]; then
      BRANCH=$(git branch --show-current 2>/dev/null)
      DIR=$(basename "$GTOP")
      STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
      MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
      UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
      if UP=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
        AB=$(git rev-list --left-right --count "${UP}...HEAD" 2>/dev/null)
        BEHIND=$(echo "$AB" | cut -f1); AHEAD=$(echo "$AB" | cut -f2)
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$BRANCH" "$DIR" "$STAGED" "$MODIFIED" "$UNTRACKED" "${AHEAD:-0}" "${BEHIND:-0}" \
        > "$GCACHE" 2>/dev/null
    else
      IFS=$'\t' read -r BRANCH DIR STAGED MODIFIED UNTRACKED AHEAD BEHIND < "$GCACHE"
    fi
  fi

  # write the snapshot: "# <hash>" header + every KEY='val' we need next tick.
  if [ "$CCSL_DECOUPLE" = "1" ]; then
    {
      printf '# %s\n' "$HASH"
      for k in MODEL EFFORT THINKING CTX_PCT CTX_IN CTX_SIZE COST DUR_MS API_MS \
               ADDED REMOVED RL5 RL5_RESET RL7 RL7_RESET PR_NUM PR_STATE OUTSTYLE \
               SESSNAME SESSID GIT_OK BRANCH DIR STAGED MODIFIED UNTRACKED AHEAD BEHIND; do
        printf '%s=%q\n' "$k" "${!k}"
      done
    } > "$DATA_CACHE" 2>/dev/null
  fi
fi

# --- colors ----------------------------------------------------------------
if [ "$CCSL_COLOR" = "1" ]; then
  DIM='\033[2m'; BOLD='\033[1m'
  CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
  MAGENTA='\033[35m'; BLUE='\033[34m'; GREY='\033[90m'; WHITE='\033[97m'
  BRIGHT='\033[92m'; RESET='\033[0m'
else
  DIM=''; BOLD=''; CYAN=''; GREEN=''; YELLOW=''; RED=''
  MAGENTA=''; BLUE=''; GREY=''; WHITE=''; BRIGHT=''; RESET=''
fi

# --- bar glyphs ------------------------------------------------------------
if [ "$CCSL_ASCII" = "1" ]; then
  G_FULL='#'; G_EMPTY='-'; G_BRIGHT='='
else
  G_FULL='█'; G_EMPTY='░'; G_BRIGHT='▓'
fi

# --- wave palette (scrolling gradient across the filled bar) ----------------
# Resolve CCSL_COLOR256=auto from $TERM; build a small ramp either way. The wave
# only changes SGR color per cell, never the glyph, so bar width stays constant.
WAVE_PALETTE=()
if [ "$CCSL_COLOR" = "1" ] && [ "$CCSL_ASCII" != "1" ]; then
  use256=0
  case "$CCSL_COLOR256" in
    1) use256=1 ;;
    0) use256=0 ;;
    *) case "${TERM:-}" in *256color*|*-direct) use256=1 ;; esac ;;
  esac
  if [ "$use256" = "1" ]; then
    # green -> cyan -> green ramp in the 256-color cube (fg codes 38;5;N)
    for n in 34 40 46 45 44 44 45 46 40 34; do WAVE_PALETTE+=("\033[38;5;${n}m"); done
  else
    # 16-color fallback: cycle green / bright-green / cyan
    WAVE_PALETTE+=("\033[32m" "\033[92m" "\033[36m" "\033[92m")
  fi
fi

# --- helpers ---------------------------------------------------------------
human() {  # 84210 -> 84k ; 1200000 -> 1.2M
  local n=$1
  if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
  elif [ "$n" -ge 1000 ];    then printf '%dk' $((n/1000))
  else printf '%d' "$n"; fi
}
dur() {  # ms -> 1h04m / 12m / 45s
  local s=$(( $1 / 1000 )) h m
  h=$((s/3600)); m=$(( (s%3600)/60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}
until_reset() { local d=$(( $1 - NOW )); [ "$d" -le 0 ] && { printf 'now'; return; }; dur $(( d*1000 )); }
pcolor() {
  if   [ "$1" -ge 90 ]; then printf '%b' "$RED"
  elif [ "$1" -ge 70 ]; then printf '%b' "$YELLOW"
  else printf '%b' "$GREEN"; fi
}
plen() { local s; s=$(printf '%b' "$1" | sed $'s/\033\\[[0-9;]*m//g'); printf '%d' "${#s}"; }
justify() {  # left ... right, padded to COLS
  local left="$1" right="$2" ll rl gap pad
  ll=$(plen "$left"); rl=$(plen "$right")
  gap=$(( COLS - ll - rl )); [ "$gap" -lt 1 ] && gap=1
  printf -v pad "%${gap}s" ""
  printf '%b%s%b' "$left" "$pad" "$right"
}

# --- animation helpers (all width-invariant: color/glyph-of-equal-width only) --
# separator: cycles a 2-char separator through fixed-width frames when enabled.
SEP2="::"; BAR1="|"
if [ "$CCSL_SEP_ANIM" = "1" ] && [ "$CCSL_ASCII" != "1" ]; then
  SEP2_FRAMES=('::' '·:' '··' ':·'); SEP2="${SEP2_FRAMES[$(( FRAME % 4 ))]}"
  BAR1_FRAMES=('|' '¦' ':' '¦');     BAR1="${BAR1_FRAMES[$(( FRAME % 4 ))]}"
fi
# blink: wrap a segment so it pulses (bright<->normal) on alternating frames when
# CCSL_WARN_ANIM is on. Color-only, so printable width never changes.
blink() {  # $1 = text (already colored)
  if [ "$CCSL_WARN_ANIM" = "1" ] && [ "$CCSL_COLOR" = "1" ] && [ $(( FRAME % 2 )) -eq 0 ]; then
    printf '%b' "\033[1m\033[5m$1$RESET"
  else
    printf '%b' "$1"
  fi
}

CTX_LABEL="200k"; [ "$CTX_SIZE" -ge 1000000 ] && CTX_LABEL="1M"

# --- Nerd Font glyphs ------------------------------------------------------
# CCSL_NERD=auto detects an installed Nerd Font (cached ~1 day). =1 forces on,
# =0 forces the ASCII/Unicode fallback. ASCII mode always wins (no glyphs).
nerd_installed() {
  local c="${TMPDIR:-/tmp}/ccsl-nerd.detect"
  if [ -f "$c" ] && [ "$(( NOW - $(cat "$c.ts" 2>/dev/null || echo 0) ))" -lt 86400 ]; then
    [ "$(cat "$c" 2>/dev/null)" = "1" ]; return
  fi
  local found=0
  if command -v fc-list >/dev/null 2>&1; then
    fc-list 2>/dev/null | grep -qiE 'nerd font|nerdfont' && found=1
  else
    # macOS: no fc-list by default -> look for a *Nerd Font*.ttf in font dirs
    ls "$HOME/Library/Fonts"/*[Nn]erd* /Library/Fonts/*[Nn]erd* \
       /System/Library/Fonts/*[Nn]erd* 2>/dev/null | grep -q . && found=1
  fi
  printf '%s' "$found" > "$c" 2>/dev/null; printf '%s' "$NOW" > "$c.ts" 2>/dev/null
  [ "$found" = "1" ]
}
USE_NERD=0
if [ "$CCSL_ASCII" != "1" ]; then
  case "$CCSL_NERD" in
    1) USE_NERD=1 ;;
    0) USE_NERD=0 ;;
    *) nerd_installed && USE_NERD=1 ;;
  esac
fi

if [ "$USE_NERD" = "1" ]; then
  # Nerd Font (JetBrainsMono NF etc.) — private-use-area glyphs, 1 col each.
  I_MODEL=$''      # robot / ai
  I_EFFORT=$''     # bolt
  I_THINK=$''      # lightbulb
  I_DIR=$''        # folder
  I_GIT=$''        # branch
  I_AHEAD=$''      # arrow-up
  I_BEHIND=$''     # arrow-down
  I_CLEAN=$''      # check
  I_PR=$''         # git-pull-request (octicon)
  I_CTX=$''        # database / stack
  I_COST=$''       # money
  I_TIME=$''       # clock
  I_LINES=$''      # pencil
  I_LIMIT=$''      # tint / gauge
else
  # ASCII / Unicode fallback — readable everywhere, no special font needed.
  I_MODEL=''; I_EFFORT='eff:'; I_THINK='think'; I_DIR=''
  I_GIT='git:'; I_AHEAD=$'↑'; I_BEHIND=$'↓'; I_CLEAN='clean'
  I_PR='PR'; I_CTX='ctx'; I_COST=''; I_TIME=''; I_LINES=''; I_LIMIT=''
  [ "$CCSL_ASCII" = "1" ] && { I_AHEAD='^'; I_BEHIND='v'; }
fi

# --- API-busy detection (cache last api_ms per session) --------------------
API_BUSY=0
if [ "$CCSL_SPINNER" = "1" ]; then
  CACHE="${TMPDIR:-/tmp}/ccsl-${SESSID}.api"
  LAST=0; [ -f "$CACHE" ] && LAST=$(cat "$CACHE" 2>/dev/null || echo 0)
  printf '%s' "$API_MS" > "$CACHE" 2>/dev/null
  [ "$API_MS" -gt "$LAST" ] 2>/dev/null && API_BUSY=1
fi
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
[ "$CCSL_ASCII" = "1" ] && SPIN_FRAMES=('|' '/' '-' '\')
SPIN="${SPIN_FRAMES[$(( FRAME % ${#SPIN_FRAMES[@]} ))]}"

# ==========================================================================
# ROW 1  --  left: identity+git+pr   |   right: rate limits
# ==========================================================================
# model: "<icon> Name:1M"  (icon only in nerd mode; else just the name)
MPFX=""; [ -n "$I_MODEL" ] && MPFX="${I_MODEL} "
L="${CYAN}${BOLD}${MPFX}${MODEL}${RESET}${GREY}:${CTX_LABEL}${RESET}"
[ -n "$SESSNAME" ]  && L="$L ${DIM}(${SESSNAME})${RESET}"
# effort: nerd -> " high" ; fallback -> "eff:high"
[ -n "$EFFORT" ]    && L="$L  ${MAGENTA}${I_EFFORT}${EFFORT}${RESET}"
# thinking: nerd -> just the bulb ; fallback -> "think:on"
if [ -n "$THINKING" ]; then
  if [ "$USE_NERD" = "1" ]; then L="$L  ${MAGENTA}${I_THINK}${RESET}"
  else L="$L  ${MAGENTA}${I_THINK}:on${RESET}"; fi
fi
[ "$OUTSTYLE" != "default" ] && L="$L  ${DIM}style:${OUTSTYLE}${RESET}"

if [ "${GIT_OK:-0}" = "1" ]; then
  # git data was gathered in Phase A (and cached); here we only render it.
  # dir: folder icon (nerd) or plain name ; git: branch icon or "git:"
  DPFX=""; [ -n "$I_DIR" ] && DPFX="${I_DIR} "
  L="$L  ${GREY}${SEP2}${RESET} ${WHITE}${DPFX}${DIR}${RESET} ${GREEN}${I_GIT}${BRANCH}${RESET}"
  D=""
  [ "$STAGED"    -gt 0 ] && D="$D ${GREEN}+${STAGED}${RESET}"
  [ "$MODIFIED"  -gt 0 ] && D="$D ${YELLOW}~${MODIFIED}${RESET}"
  [ "$UNTRACKED" -gt 0 ] && D="$D ${RED}?${UNTRACKED}${RESET}"
  # clean marker: nerd -> check glyph ; fallback -> "clean"
  [ -z "$D" ] && D=" ${GREEN}${I_CLEAN}${RESET}"
  L="$L$D"

  [ "${AHEAD:-0}"  -gt 0 ] && L="$L ${CYAN}${I_AHEAD}${AHEAD}${RESET}"
  [ "${BEHIND:-0}" -gt 0 ] && L="$L ${CYAN}${I_BEHIND}${BEHIND}${RESET}"
fi

if [ -n "$PR_NUM" ]; then
  case "$PR_STATE" in
    approved)          PR_TAG="${GREEN}OK${RESET}" ;;
    changes_requested) PR_TAG=$(blink "${RED}CHANGES${RESET}") ;;
    draft)             PR_TAG="${GREY}DRAFT${RESET}" ;;
    *)                 PR_TAG="${YELLOW}REVIEW${RESET}" ;;
  esac
  # PR: nerd -> pull-request glyph ; fallback -> "PR#"
  if [ "$USE_NERD" = "1" ]; then PRLBL="${I_PR} ${PR_NUM}"; else PRLBL="${I_PR}#${PR_NUM}"; fi
  L="$L  ${GREY}${SEP2}${RESET} ${BLUE}${PRLBL}${RESET} $PR_TAG"
fi

# spinner appended to left when API is busy
[ "$API_BUSY" = "1" ] && L="$L  ${BRIGHT}${SPIN} working${RESET}"

# right side of row 1: rate-limit budget (subscription only)
R=""
if [ "$RL5" != "-1" ]; then
  RL5I=${RL5%.*}; C=$(pcolor "$RL5I")
  LPFX=""; [ -n "$I_LIMIT" ] && LPFX="${I_LIMIT} "
  seg="${C}${LPFX}5h ${RL5I}%${RESET}"
  [ "$RL5I" -ge 90 ] && seg=$(blink "${C}${LPFX}5h ${RL5I}%${RESET}")
  [ "$RL5_RESET" -gt 0 ] && seg="$seg ${DIM}$(until_reset "$RL5_RESET")${RESET}"
  R="$seg"
fi
if [ "$RL7" != "-1" ]; then
  RL7I=${RL7%.*}; C=$(pcolor "$RL7I")
  seg="${C}7d ${RL7I}%${RESET}"
  [ "$RL7I" -ge 90 ] && seg=$(blink "${C}7d ${RL7I}%${RESET}")
  [ "$RL7_RESET" -gt 0 ] && seg="$seg ${DIM}$(until_reset "$RL7_RESET")${RESET}"
  [ -n "$R" ] && R="$R  ${GREY}${BAR1}${RESET}  "
  R="$R$seg"
fi
[ -z "$R" ] && R="${DIM}no rate-limit data (API auth)${RESET}"

ROW1=$(justify "$L" "$R")

# ==========================================================================
# ROW 2  --  left: context bar (with shimmer)  |  right: cost/lines/durations
# ==========================================================================
BAR_W=$(( COLS * 4 / 10 ))
[ "$BAR_W" -lt 16 ] && BAR_W=16
[ "$BAR_W" -gt "$CCSL_BAR_MAX" ] && BAR_W=$CCSL_BAR_MAX
FILLED=$(( CTX_PCT * BAR_W / 100 )); [ "$FILLED" -gt "$BAR_W" ] && FILLED=$BAR_W
[ "$FILLED" -lt 0 ] && FILLED=0
EMPTY=$(( BAR_W - FILLED ))
BC=$(pcolor "$CTX_PCT")

# Build the filled region. Three composable animations, all color-only so the
# printable width is exactly FILLED+EMPTY every frame:
#   - PULSE: a breathing intensity applied to the whole filled run (SGR 2/none/1)
#   - WAVE : a scrolling gradient, each cell colored by (i+FRAME) % palette
#   - SHIMMER: one bright cell swept across (overlays wave/pulse)
# pulse phase -> intensity prefix (dim, normal, bright, normal)
PULSE_SGR=""
if [ "$CCSL_PULSE" = "1" ] && [ "$CCSL_COLOR" = "1" ]; then
  case $(( FRAME % 4 )) in 0) PULSE_SGR='\033[2m';; 2) PULSE_SGR='\033[1m';; *) PULSE_SGR='';; esac
fi
have_wave=0
[ "$CCSL_WAVE" = "1" ] && [ "${#WAVE_PALETTE[@]}" -gt 0 ] && [ "$FILLED" -gt 0 ] && have_wave=1
SPOS=-1
[ "$CCSL_SHIMMER" = "1" ] && [ "$FILLED" -gt 1 ] && SPOS=$(( FRAME % FILLED ))

BAR=""
if [ "$have_wave" = "1" ] || [ "$SPOS" -ge 0 ] || [ -n "$PULSE_SGR" ]; then
  np=${#WAVE_PALETTE[@]}
  for ((i=0; i<FILLED; i++)); do
    if [ "$i" -eq "$SPOS" ]; then
      BAR="${BAR}${BRIGHT}${G_BRIGHT}${RESET}"
    elif [ "$have_wave" = "1" ]; then
      BAR="${BAR}${WAVE_PALETTE[$(( (i + FRAME) % np ))]}${PULSE_SGR}${G_FULL}${RESET}"
    else
      BAR="${BAR}${BC}${PULSE_SGR}${G_FULL}${RESET}"
    fi
  done
else
  printf -v FF "%${FILLED}s" ""; BAR="${BC}${FF// /$G_FULL}${RESET}"
fi
printf -v EE "%${EMPTY}s" ""; BAR="${BAR}${GREY}${EE// /$G_EMPTY}${RESET}"

# ctx label: nerd -> stack glyph ; fallback -> "ctx"
CTXLBL="ctx"; [ -n "$I_CTX" ] && CTXLBL="$I_CTX"
# percentage blinks when context is critically high
PCT_SEG="${BC}${BOLD}${CTX_PCT}%${RESET}"
[ "$CTX_PCT" -ge 90 ] && PCT_SEG=$(blink "${BC}${BOLD}${CTX_PCT}%${RESET}")
L2="${GREY}${CTXLBL}${RESET} ${BC}[${RESET}${BAR}${BC}]${RESET} ${PCT_SEG} ${GREY}$(human "$CTX_IN")/${CTX_LABEL}${RESET}"

# right side of row 2 (icons prefixed in nerd mode)
CPFX=""; [ -n "$I_COST" ] && CPFX="${I_COST} "
COST_SEG="${YELLOW}${CPFX}$(printf '~$%.2f' "$COST")${RESET}"
LINES_SEG=""
if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
  XPFX=""; [ -n "$I_LINES" ] && XPFX="${I_LINES} "
  LINES_SEG="${XPFX}${GREEN}+${ADDED}${RESET}${GREY}/${RESET}${RED}-${REMOVED}${RESET}"
fi
DUR_SEG=""
if [ "$DUR_MS" -gt 0 ]; then
  TPFX=""; [ -n "$I_TIME" ] && TPFX="${I_TIME} "
  DUR_SEG="${DIM}${TPFX}$(dur "$DUR_MS")${RESET}"
  [ "$API_MS" -gt 0 ] && DUR_SEG="$DUR_SEG ${DIM}(api $(dur "$API_MS"))${RESET}"
fi
TOK_SEG="${GREY}$(human "$CTX_IN") tok${RESET}"

if [ "$CCSL_MARQUEE" = "1" ]; then
  # cycle through the segments, one per tick
  SEGS=("$COST_SEG"); [ -n "$LINES_SEG" ] && SEGS+=("$LINES_SEG")
  [ -n "$DUR_SEG" ] && SEGS+=("$DUR_SEG"); SEGS+=("$TOK_SEG")
  R2="${SEGS[$(( FRAME % ${#SEGS[@]} ))]}"
else
  R2="$COST_SEG"
  [ -n "$LINES_SEG" ] && R2="$R2  ${GREY}${BAR1}${RESET}  $LINES_SEG"
  [ -n "$DUR_SEG" ]   && R2="$R2  ${GREY}${BAR1}${RESET}  $DUR_SEG"
fi

ROW2=$(justify "$L2" "$R2")

printf '%b\n%b\n' "$ROW1" "$ROW2"
