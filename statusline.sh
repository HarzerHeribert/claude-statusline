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
#   - a bright cell that sweeps across the filled context bar (shimmer)
#   - a marquee that cycles the right rail of row 2 through stats
# Frames advance off wall-clock time, so no persistent frame state is needed.
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
#   CCSL_MARQUEE=0         cycle right rail of row 2 (off by default; shows all at once)
#   CCSL_REFRESH=10        must match settings.json refreshInterval (for frame timing)
#   CCSL_BAR_MAX=60        max context-bar width in chars
#   CCSL_COLOR=1           colored output (0 = plain)
#   CCSL_ASCII=0           1 = use ASCII bar chars (#/-) instead of block glyphs
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
[ "$CCSL_ANIM" = "0" ] && { CCSL_SPINNER=0; CCSL_SHIMMER=0; CCSL_MARQUEE=0; }

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

# --- jq extraction (KEY='val' lines, quoted; jq // treats null as absent) --
if ! command -v jq >/dev/null 2>&1; then
  # graceful fallback: no jq -> just echo the model name we can grep out
  m=$(printf '%s' "$input" | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "${m:-claude} :: (install jq for the full status line)"
  exit 0
fi

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

# --- frame counter (wall-clock / refresh interval) -------------------------
NOW=$(date +%s)
[ "$CCSL_REFRESH" -lt 1 ] 2>/dev/null && CCSL_REFRESH=1
FRAME=$(( NOW / CCSL_REFRESH ))

# --- bar glyphs ------------------------------------------------------------
if [ "$CCSL_ASCII" = "1" ]; then
  G_FULL='#'; G_EMPTY='-'; G_BRIGHT='='
else
  G_FULL='█'; G_EMPTY='░'; G_BRIGHT='▓'
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

CTX_LABEL="200k"; [ "$CTX_SIZE" -ge 1000000 ] && CTX_LABEL="1M"

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
L="${CYAN}${BOLD}${MODEL}${RESET}${GREY}:${CTX_LABEL}${RESET}"
[ -n "$SESSNAME" ]  && L="$L ${DIM}(${SESSNAME})${RESET}"
[ -n "$EFFORT" ]    && L="$L  ${MAGENTA}eff:${EFFORT}${RESET}"
[ -n "$THINKING" ]  && L="$L  ${MAGENTA}think:on${RESET}"
[ "$OUTSTYLE" != "default" ] && L="$L  ${DIM}style:${OUTSTYLE}${RESET}"

if git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  DIR=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
  STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

  L="$L  ${GREY}::${RESET} ${WHITE}${DIR}${RESET} ${GREEN}git:${BRANCH}${RESET}"
  D=""
  [ "$STAGED"    -gt 0 ] && D="$D ${GREEN}+${STAGED}${RESET}"
  [ "$MODIFIED"  -gt 0 ] && D="$D ${YELLOW}~${MODIFIED}${RESET}"
  [ "$UNTRACKED" -gt 0 ] && D="$D ${RED}?${UNTRACKED}${RESET}"
  [ -z "$D" ] && D=" ${GREEN}clean${RESET}"
  L="$L$D"

  if UP=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    AB=$(git rev-list --left-right --count "${UP}...HEAD" 2>/dev/null)
    BEHIND=$(echo "$AB" | cut -f1); AHEAD=$(echo "$AB" | cut -f2)
    [ "${AHEAD:-0}"  -gt 0 ] && L="$L ${CYAN}^${AHEAD}${RESET}"
    [ "${BEHIND:-0}" -gt 0 ] && L="$L ${CYAN}v${BEHIND}${RESET}"
  fi
fi

if [ -n "$PR_NUM" ]; then
  case "$PR_STATE" in
    approved)          PR_TAG="${GREEN}OK${RESET}" ;;
    changes_requested) PR_TAG="${RED}CHANGES${RESET}" ;;
    draft)             PR_TAG="${GREY}DRAFT${RESET}" ;;
    *)                 PR_TAG="${YELLOW}REVIEW${RESET}" ;;
  esac
  L="$L  ${GREY}::${RESET} ${BLUE}PR#${PR_NUM}${RESET} $PR_TAG"
fi

# spinner appended to left when API is busy
[ "$API_BUSY" = "1" ] && L="$L  ${BRIGHT}${SPIN} working${RESET}"

# right side of row 1: rate-limit budget (subscription only)
R=""
if [ "$RL5" != "-1" ]; then
  RL5I=${RL5%.*}; C=$(pcolor "$RL5I")
  seg="${C}5h ${RL5I}%${RESET}"
  [ "$RL5_RESET" -gt 0 ] && seg="$seg ${DIM}$(until_reset "$RL5_RESET")${RESET}"
  R="$seg"
fi
if [ "$RL7" != "-1" ]; then
  RL7I=${RL7%.*}; C=$(pcolor "$RL7I")
  seg="${C}7d ${RL7I}%${RESET}"
  [ "$RL7_RESET" -gt 0 ] && seg="$seg ${DIM}$(until_reset "$RL7_RESET")${RESET}"
  [ -n "$R" ] && R="$R  ${GREY}|${RESET}  "
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

# build bar; shimmer = one bright cell sweeping across the filled region
BAR=""
if [ "$CCSL_SHIMMER" = "1" ] && [ "$FILLED" -gt 1 ]; then
  SPOS=$(( FRAME % FILLED ))
  for ((i=0; i<FILLED; i++)); do
    if [ "$i" -eq "$SPOS" ]; then BAR="${BAR}${BRIGHT}${G_BRIGHT}${RESET}${BC}"
    else BAR="${BAR}${G_FULL}"; fi
  done
else
  printf -v FF "%${FILLED}s" ""; BAR="${FF// /$G_FULL}"
fi
printf -v EE "%${EMPTY}s" ""; BAR="${BAR}${EE// /$G_EMPTY}"

L2="${GREY}ctx${RESET} ${BC}[${BAR}]${RESET} ${BC}${BOLD}${CTX_PCT}%${RESET} ${GREY}$(human "$CTX_IN")/${CTX_LABEL}${RESET}"

# right side of row 2
COST_SEG="${YELLOW}$(printf '~$%.2f' "$COST")${RESET}"
LINES_SEG=""; [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ] && \
  LINES_SEG="${GREEN}+${ADDED}${RESET}${GREY}/${RESET}${RED}-${REMOVED}${RESET}"
DUR_SEG=""
if [ "$DUR_MS" -gt 0 ]; then
  DUR_SEG="${DIM}$(dur "$DUR_MS")${RESET}"
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
  [ -n "$LINES_SEG" ] && R2="$R2  ${GREY}|${RESET}  $LINES_SEG"
  [ -n "$DUR_SEG" ]   && R2="$R2  ${GREY}|${RESET}  $DUR_SEG"
fi

ROW2=$(justify "$L2" "$R2")

printf '%b\n%b\n' "$ROW1" "$ROW2"
