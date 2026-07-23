#!/usr/bin/env bash
# claude-statusline — a quiet, no-emoji, budget-aware status line for Claude Code.
# https://github.com/HarzerHeribert/claude-statusline
#
# Reads session JSON on stdin (schema: https://code.claude.com/docs/en/statusline)
# and prints two rows, left/right justified to fill the terminal:
#   row 1: identity + repo ............................ rate-limit budget (right)
#   row 2: context gauge .............................. work done (right)
#
# DESIGN — quiet by default
# The status line is on screen permanently, so every character has to earn its
# place. Two rules keep it thin:
#   1. A segment appears only when it's ACTIONABLE. Clean tree -> no "clean"
#      badge. Approved PR -> a tick, not a word. Default effort -> nothing. The
#      seven-day limit hides until it (or the five-hour one) is actually warm.
#   2. Nothing can push out something more important. Every segment carries a
#      priority; the layout engine measures the row and drops the least
#      important segments until it fits (see `fit`). Free-text fields the model
#      or the repo control -- session names ("Refactoring the Wombat Emporium"),
#      long project dirs, long branch names -- are BOTH truncated to a budget
#      AND given low priority, so they can never crowd out context or limits.
#
# WHAT'S UNIQUE HERE
#   - Sub-cell context bar: eighth-block glyphs give the fill 8x the resolution
#     of a normal block bar, so 1% moves are visible in a 24-cell gauge.
#   - Runway projection: the script samples context and rate-limit usage over
#     time and extrapolates. "compact ~22m" / "5h out ~1h10m" answers the only
#     question the raw percentages don't: will I make it to the reset?
#   - Motion only while the model is working (see below).
#
# ANIMATION — measured, not guessed
# The periodic refresh is hard-capped at 1 fps: `refreshInterval` is validated
# as `number().min(1)` and then clamped again at runtime with `Math.max(1, G) *
# 1000`. Asking for 0.2 gets you 1.000s. Verified by probe: 133 of 156 observed
# gaps sat in the 0.9-1.1s bucket.
# BUT event-driven re-renders (debounced at 300ms) fire on top of the timer
# whenever session state changes -- i.e. while the model is actively working.
# The same probe caught 20 gaps under 0.8s, the fastest at exactly 0.300s.
# So: ~1 fps idle (motion would read as broken rendering), ~2-3 fps busy (motion
# reads as motion). The bar therefore sweeps ONLY while the API is busy and is
# byte-identical when idle. The sweep advances off an invocation counter, not a
# clock, so it runs at whatever the real re-render rate happens to be.
#
# DECOUPLING (data vs animation)
#   The harness only changes the stdin payload when real data changes. We hash it
#   and cache the parsed values; an unchanged tick skips jq AND git entirely and
#   just re-renders. See CCSL_DECOUPLE.
#
# NOTES:
#   - context_window.used_percentage is input-only (matches /context), authoritative.
#     It is NOT the same 100% the harness's context alerts use: those fire against
#     the usable budget (window - output reservation - compaction margin), i.e. the
#     auto-compact threshold (~92%). So a 73% bar can coexist with a "context low"
#     alert. We mark that threshold on the bar (CCSL_COMPACT_PCT) so the danger line
#     the alert triggers on is visible without rescaling the familiar percentage.
#   - cost.total_cost_usd is a CLIENT-SIDE ESTIMATE, not your bill -> shown as "~$".
#     The real budget signal on Pro/Max is rate_limits.*, so when those exist the
#     cost estimate is demoted to the lowest priority and drops first.
#
# CONFIG (env vars, override in settings.json "command" or your shell profile):
#   CCSL_ROWS=2            2 = identity row + context row; 1 = context row only
#   CCSL_QUIET=1           hide non-actionable segments (0 = show everything)
#   CCSL_RUNWAY=1          burn-rate projections (compact ETA, rate-limit ETA)
#   CCSL_ANIM=1            master switch for all animation (0 disables)
#   CCSL_MOTION=busy       busy = sweep the bar while the API works; off = never
#   CCSL_SPINNER=1         spinner while API busy
#   CCSL_SHINE=1           static same-hue gloss at the fill edge (never moves)
#   CCSL_WARN_ANIM=1       blink high-usage / changes-requested segments
#   CCSL_DECOUPLE=1        skip jq/git on unchanged ticks (cache parsed data)
#   CCSL_DATA_TTL=5        max seconds to trust the data snapshot
#   CCSL_GIT_TTL=2         seconds to cache git state between ticks
#   CCSL_BAR_MAX=44        max context-bar width in chars
#   CCSL_COMPACT_PCT=92    window % where the harness auto-compacts (marker pos)
#   CCSL_COLOR=1           colored output (0 = plain)
#   CCSL_COLOR256=auto     256-color ramp when the terminal supports it
#   CCSL_ASCII=0           1 = use ASCII bar chars (#/-) instead of block glyphs
#   CCSL_NERD=auto         auto|1|0 use Nerd Font glyphs for icons
#   CCSL_MARGIN=6          columns reserved at the right edge (anti-clip)
set -u

input=$(cat)

# --- config with defaults --------------------------------------------------
CCSL_ROWS=${CCSL_ROWS:-2}
CCSL_QUIET=${CCSL_QUIET:-1}
CCSL_RUNWAY=${CCSL_RUNWAY:-1}
CCSL_ANIM=${CCSL_ANIM:-1}
CCSL_MOTION=${CCSL_MOTION:-busy}
CCSL_SPINNER=${CCSL_SPINNER:-1}
CCSL_SHINE=${CCSL_SHINE:-1}
CCSL_WARN_ANIM=${CCSL_WARN_ANIM:-1}
CCSL_BAR_MAX=${CCSL_BAR_MAX:-44}
CCSL_COMPACT_PCT=${CCSL_COMPACT_PCT:-92}
CCSL_COLOR=${CCSL_COLOR:-1}
CCSL_COLOR256=${CCSL_COLOR256:-auto}
CCSL_ASCII=${CCSL_ASCII:-0}
CCSL_NERD=${CCSL_NERD:-auto}
CCSL_GIT_TTL=${CCSL_GIT_TTL:-2}
CCSL_DECOUPLE=${CCSL_DECOUPLE:-1}
CCSL_DATA_TTL=${CCSL_DATA_TTL:-5}
[ "$CCSL_ANIM" = "0" ] && { CCSL_SPINNER=0; CCSL_WARN_ANIM=0; CCSL_MOTION=off; }

# --- terminal width (harness sets COLUMNS; fall back sanely) ----------------
# The status bar can't use the full terminal width: the harness reserves a
# right-hand margin for its own notifications (token counter, MCP errors) and
# the row has built-in side padding. Subtract CCSL_MARGIN so the right rail
# never touches the true edge and gets clipped.
CCSL_MARGIN=${CCSL_MARGIN:-6}
COLS=${COLUMNS:-0}
[ "$COLS" -lt 40 ] 2>/dev/null && COLS=120
[ "$COLS" -gt 300 ] 2>/dev/null && COLS=300
COLS=$(( COLS - CCSL_MARGIN ))
[ "$COLS" -lt 40 ] && COLS=40

if ! command -v jq >/dev/null 2>&1; then
  # graceful fallback: no jq -> just echo the model name we can grep out
  m=$(printf '%s' "$input" | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "${m:-claude} (install jq for the full status line)"
  exit 0
fi

# Wall clock without forking a `date`. printf's %(...)T needs bash 4.2; the
# fallback keeps this working on the bash 3.2 that ships with macOS.
if ! printf -v NOW '%(%s)T' -1 2>/dev/null; then NOW=$(date +%s); fi

# ==========================================================================
# PHASE A -- DATA  (jq + git + trend; skipped entirely on an unchanged tick)
# ==========================================================================
# The harness only changes the JSON payload when real data changes. So we hash
# stdin and, if it matches the last snapshot (and the snapshot is fresh), we
# source the cached KEY=VAL vars and skip jq AND git. A pure-render tick then
# costs a cksum + a source -- no subprocess parsing at all.

# Cheap session id for the cache key, without jq and without forking grep.
SESSID=nosess
[[ $input =~ \"session_id\":\"([^\"]*)\" ]] && SESSID=${BASH_REMATCH[1]}
[ -z "$SESSID" ] && SESSID=nosess
DATA_CACHE="${TMPDIR:-/tmp}/ccsl-data-${SESSID}"

# Hash the payload (fast, non-crypto is fine — we only need change detection).
HASH=$(printf '%s' "$input" | cksum | tr -d ' ')

data_fresh=0
if [ "$CCSL_DECOUPLE" = "1" ] && [ -f "$DATA_CACHE" ]; then
  # The snapshot's first line is "# <hash> <written-at>". Carrying the write
  # time inside the file means the freshness check is one builtin `read` --
  # no `head` fork and no `stat` fork.
  if read -r _h CACHED_HASH CACHED_AT < "$DATA_CACHE" 2>/dev/null; then
    case "$CACHED_AT" in ''|*[!0-9]*) CACHED_AT=0 ;; esac
    if [ "$CACHED_HASH" = "$HASH" ] && [ $(( NOW - CACHED_AT )) -lt "$CCSL_DATA_TTL" ]; then
      data_fresh=1
    fi
  fi
fi

if [ "$data_fresh" = "1" ]; then
  . "$DATA_CACHE" 2>/dev/null
  # guard against a partial/corrupt snapshot: if any required var is unset,
  # discard and fall through to a fresh parse (${x+s} is safe under set -u).
  for k in MODEL CTX_PCT CTX_SIZE COST DUR_MS API_MS RL5 RL7 GIT_OK ETA_CTX_AT ETA_RL_AT; do
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
    # Same trick as the data snapshot: the write time is the first field, so
    # freshness costs one builtin `read` instead of a `stat` fork.
    GAGE=999; GMT=0
    if [ -f "$GCACHE" ]; then
      IFS=$'\t' read -r GMT BRANCH DIR STAGED MODIFIED UNTRACKED AHEAD BEHIND < "$GCACHE" 2>/dev/null
      case "$GMT" in ''|*[!0-9]*) GMT=0 ;; esac
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
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NOW" "$BRANCH" "$DIR" "$STAGED" "$MODIFIED" "$UNTRACKED" "${AHEAD:-0}" "${BEHIND:-0}" \
        > "$GCACHE" 2>/dev/null
    fi
    # else: the `read` above already populated BRANCH..BEHIND from the cache
    # A truncated or half-written cache line would otherwise blow up the
    # integer tests further down, so normalise the counters here.
    for gk in STAGED MODIFIED UNTRACKED AHEAD BEHIND; do
      eval "case \"\${$gk:-}\" in ''|*[!0-9]*) $gk=0 ;; esac"
    done
  fi

  # --- runway: extrapolate context + rate-limit burn ------------------------
  # Percentages tell you where you are; they don't tell you whether you'll make
  # it to the reset. We append one sample per data-change tick and fit a simple
  # rate over the last 30 minutes. The result is stored as an ABSOLUTE target
  # timestamp, so cached render-only ticks still count it down correctly.
  ETA_CTX_AT=0; ETA_RL_AT=0
  if [ "$CCSL_RUNWAY" = "1" ]; then
    TREND="${TMPDIR:-/tmp}/ccsl-trend-${SESSID}"
    printf '%s %s %s\n' "$NOW" "$CTX_IN" "${RL5%.*}" >> "$TREND" 2>/dev/null
    # keep the file bounded; 40 samples is plenty for a 30-minute window
    if [ -f "$TREND" ]; then
      tail -n 40 "$TREND" > "$TREND.tmp" 2>/dev/null && mv "$TREND.tmp" "$TREND" 2>/dev/null
      TARGET_CTX=$(( CCSL_COMPACT_PCT * CTX_SIZE / 100 ))
      eval "$(awk -v now="$NOW" -v tgt="$TARGET_CTX" '
        { ts[n]=$1+0; c[n]=$2+0; r[n]=$3+0; n++ }
        END {
          ectx=0; erl=0
          if (n >= 2) {
            i=0; while (i < n-1 && now-ts[i] > 1800) i++   # 30-minute window
            span = ts[n-1]-ts[i]
            if (span >= 60) {
              dc = c[n-1]-c[i]
              if (dc > 0) { rem = tgt-c[n-1]; if (rem > 0) ectx = int(now + rem/(dc/span)) }
              dr = r[n-1]-r[i]
              if (dr > 0 && r[n-1] >= 0) { rem = 100-r[n-1]; if (rem > 0) erl = int(now + rem/(dr/span)) }
            }
          }
          print "ETA_CTX_AT=" ectx; print "ETA_RL_AT=" erl
        }' "$TREND" 2>/dev/null)"
    fi
  fi
  : "${ETA_CTX_AT:=0}" "${ETA_RL_AT:=0}"

  if [ "$CCSL_DECOUPLE" = "1" ]; then
    {
      printf '# %s %s\n' "$HASH" "$NOW"
      for k in MODEL EFFORT THINKING CTX_PCT CTX_IN CTX_SIZE COST DUR_MS API_MS \
               ADDED REMOVED RL5 RL5_RESET RL7 RL7_RESET PR_NUM PR_STATE OUTSTYLE \
               SESSNAME SESSID GIT_OK BRANCH DIR STAGED MODIFIED UNTRACKED AHEAD BEHIND \
               ETA_CTX_AT ETA_RL_AT; do
        printf '%s=%q\n' "$k" "${!k}"
      done
    } > "$DATA_CACHE" 2>/dev/null
  fi
fi

# ==========================================================================
# PHASE B -- PRESENTATION
# ==========================================================================

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
# EIGHTHS[n] is a block filling n/8 of a cell. They give the gauge sub-cell
# resolution: a 24-wide bar resolves ~0.5%, so small context moves are visible
# instead of sitting on the same whole block for ten percentage points.
if [ "$CCSL_ASCII" = "1" ]; then
  G_FULL='#'; G_EMPTY='-'; G_MARK='!'
  EIGHTHS=('' '' '' '' '' '' '' '')   # no sub-cell fill in ASCII mode
  SEP=' | '; SEP_W=3
else
  G_FULL='█'; G_EMPTY='░'; G_MARK='╎'
  EIGHTHS=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')
  SEP=' · '; SEP_W=3
fi

# --- severity ramp (same hue as the bar, brighter shades) -------------------
# RAMP[0] is the bar's base tone; RAMP[1..2] are brighter shades of the SAME
# hue, used for the static gloss at the fill edge and the busy sweep.
use256=0
case "$CCSL_COLOR256" in
  1) use256=1 ;;
  0) use256=0 ;;
  *) case "${TERM:-}" in *256color*|*-direct) use256=1 ;; esac ;;
esac
RAMP=()
if [ "$CCSL_COLOR" = "1" ]; then
  if [ "$use256" = "1" ]; then
    if   [ "${CTX_PCT:-0}" -ge 90 ]; then SHADES=(124 160 203)  # reds
    elif [ "${CTX_PCT:-0}" -ge 70 ]; then SHADES=(178 220 228)  # yellows
    else                                  SHADES=(34 40 46);  fi # greens
    for n in "${SHADES[@]}"; do RAMP+=("\033[38;5;${n}m"); done
  else
    if   [ "${CTX_PCT:-0}" -ge 90 ]; then RAMP=('\033[31m' '\033[91m' '\033[1;91m')
    elif [ "${CTX_PCT:-0}" -ge 70 ]; then RAMP=('\033[33m' '\033[93m' '\033[1;93m')
    else                                  RAMP=('\033[32m' '\033[92m' '\033[1;92m'); fi
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
# Truncation for text WE DON'T CONTROL. `trunc` keeps the head (project dirs,
# session names read left-to-right); `mtrunc` keeps head and tail with the
# ellipsis in the middle, because a branch's distinguishing part is usually its
# tail (feature/PROJ-1234-the-actual-thing).
trunc() {
  local s=$1 m=$2
  [ "${#s}" -le "$m" ] && { printf '%s' "$s"; return; }
  [ "$m" -lt 2 ] && { printf '%s' "${s:0:m}"; return; }
  printf '%s…' "${s:0:$((m-1))}"
}
mtrunc() {
  local s=$1 m=$2 h t
  [ "${#s}" -le "$m" ] && { printf '%s' "$s"; return; }
  [ "$m" -lt 4 ] && { trunc "$s" "$m"; return; }
  h=$(( (m-1)/2 )); t=$(( m-1-h ))
  printf '%s…%s' "${s:0:$h}" "${s:$(( ${#s} - t ))}"
}
# blink: wrap a segment so it pulses on alternating ticks. Color-only, so the
# printable width never changes and the right rail never jitters.
blink() {
  if [ "$CCSL_WARN_ANIM" = "1" ] && [ "$CCSL_COLOR" = "1" ] && [ $(( TICK % 2 )) -eq 0 ]; then
    printf '%b' "\033[1m\033[5m$1$RESET"
  else
    printf '%b' "$1"
  fi
}

# --- invocation counter -----------------------------------------------------
# Motion advances per INVOCATION, not per wall-clock second. That matters:
# the periodic timer is capped at 1 fps, but event-driven re-renders (300ms
# debounce) stack on top of it while the model is working. Counting invocations
# means the sweep automatically runs at whatever the real re-render rate is --
# ~1 step/s idle, ~2-3 steps/s busy -- with no clock arithmetic.
TICKF="${TMPDIR:-/tmp}/ccsl-${SESSID}.tick"
TICK=0; [ -f "$TICKF" ] && read -r TICK < "$TICKF" 2>/dev/null
case "$TICK" in ''|*[!0-9]*) TICK=0 ;; esac
TICK=$(( (TICK + 1) % 100000 ))
printf '%s' "$TICK" > "$TICKF" 2>/dev/null

CTX_LABEL="200k"; [ "$CTX_SIZE" -ge 1000000 ] && CTX_LABEL="1M"

# --- Nerd Font glyphs ------------------------------------------------------
nerd_installed() {
  local c="${TMPDIR:-/tmp}/ccsl-nerd.detect"
  ts=$(cat "$c.ts" 2>/dev/null || echo 0); ts=${ts:-0}
  if [ -f "$c" ] && [ "$(( NOW - ts ))" -lt 86400 ]; then
    [ "$(cat "$c" 2>/dev/null)" = "1" ]; return
  fi
  local found=0
  if command -v fc-list >/dev/null 2>&1; then
    # Linux (and WSL / any host with fontconfig)
    fc-list 2>/dev/null | grep -qiE 'nerd font|nerdfont' && found=1
  else
    ls "$HOME/Library/Fonts"/*[Nn]erd* /Library/Fonts/*[Nn]erd* \
       /System/Library/Fonts/*[Nn]erd* 2>/dev/null | grep -q . && found=1
    # Windows via Git Bash / MSYS: check the Windows font directories too
    ls "${WINDIR:-/c/Windows}/Fonts"/*[Nn]erd* \
       "${LOCALAPPDATA:-}/Microsoft/Windows/Fonts"/*[Nn]erd* 2>/dev/null \
       | grep -q . && found=1
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
  I_MODEL=$''; I_EFFORT=$''; I_THINK=$''; I_GIT=$''
  I_AHEAD=$''; I_BEHIND=$''; I_PR=$''; I_OK=$''
  I_LIMIT=$''; I_WARN=$''; I_RESET=$''; I_TIME=$''; I_LINES=$''
elif [ "$CCSL_ASCII" = "1" ]; then
  I_MODEL=''; I_EFFORT=''; I_THINK='*'; I_GIT=''
  I_AHEAD='^'; I_BEHIND='v'; I_PR='PR'; I_OK='ok'
  # '>' not '~' for the reset countdown: '~' is already the modified-files
  # marker, and "5h 31% ~1h30m" reads as an approximation rather than a deadline
  I_LIMIT=''; I_WARN='!'; I_RESET='>'; I_TIME=''; I_LINES=''
else
  I_MODEL=$'◆'; I_EFFORT=''; I_THINK=$'✻'; I_GIT=''
  I_AHEAD=$'⇡'; I_BEHIND=$'⇣'; I_PR='PR'; I_OK=$'✓'
  I_LIMIT=''; I_WARN=$'⚠'; I_RESET=$'↻'; I_TIME=''; I_LINES=''
fi

# --- API-busy detection (cache last api_ms per session) --------------------
# total_api_duration_ms only advances while a request is in flight, so a tick
# that sees it grow is a tick where the model is working.
API_BUSY=0
CACHE="${TMPDIR:-/tmp}/ccsl-${SESSID}.api"
LAST=0; [ -f "$CACHE" ] && read -r LAST < "$CACHE" 2>/dev/null
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
printf '%s' "$API_MS" > "$CACHE" 2>/dev/null
[ "$API_MS" -gt "$LAST" ] 2>/dev/null && API_BUSY=1

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
[ "$CCSL_ASCII" = "1" ] && SPIN_FRAMES=('|' '/' '-' '\')
SPIN="${SPIN_FRAMES[$(( TICK % ${#SPIN_FRAMES[@]} ))]}"

# ==========================================================================
# LAYOUT ENGINE
# ==========================================================================
# Every segment is (row, side, priority, colored text, printable width).
# Priority 0 never drops; higher numbers drop first. `fit` measures a row and
# removes the least important segments until the two rails clear each other by
# at least two columns -- which is what guarantees that a 60-character session
# name or a deeply-named repo can never displace the context gauge.
S_ROW=(); S_SIDE=(); S_PRI=(); S_TXT=(); S_W=(); S_LIVE=()
add() {  # add <row> <side L|R> <priority> <colored> <plain>
  addw "$1" "$2" "$3" "$4" "${#5}"
}
addw() { # addw <row> <side> <priority> <colored> <printable width>
  S_ROW+=("$1"); S_SIDE+=("$2"); S_PRI+=("$3"); S_TXT+=("$4"); S_W+=("$5"); S_LIVE+=(1)
}
# These set globals rather than echoing. `fit` calls them in a loop, and every
# $(...) is a fork -- at one render per second that adds up to real CPU for
# something that is only ever string arithmetic.
row_width() {  # <row> <side> -> sets RW
  local row=$1 side=$2 i w=0 n=0
  for i in "${!S_ROW[@]}"; do
    [ "${S_LIVE[$i]}" = "1" ] || continue
    [ "${S_ROW[$i]}" = "$row" ] && [ "${S_SIDE[$i]}" = "$side" ] || continue
    w=$(( w + S_W[i] )); n=$(( n + 1 ))
  done
  [ "$n" -gt 1 ] && w=$(( w + (n - 1) * SEP_W ))
  RW=$w
}
row_render() {  # <row> <side> -> sets RR
  local row=$1 side=$2 i out="" first=1
  for i in "${!S_ROW[@]}"; do
    [ "${S_LIVE[$i]}" = "1" ] || continue
    [ "${S_ROW[$i]}" = "$row" ] && [ "${S_SIDE[$i]}" = "$side" ] || continue
    if [ "$first" = "1" ]; then out="${S_TXT[$i]}"; first=0
    else out="${out}${GREY}${SEP}${RESET}${S_TXT[$i]}"; fi
  done
  RR=$out
}
fit() {  # <row> : drop lowest-priority segments until the row fits COLS
  local row=$1 lw rw i worst worst_pri guard=0
  while [ "$guard" -lt 40 ]; do
    guard=$(( guard + 1 ))
    row_width "$row" L; lw=$RW
    row_width "$row" R; rw=$RW
    [ $(( lw + rw + 2 )) -le "$COLS" ] && return 0
    worst=-1; worst_pri=0
    for i in "${!S_ROW[@]}"; do
      [ "${S_LIVE[$i]}" = "1" ] || continue
      [ "${S_ROW[$i]}" = "$row" ] || continue
      [ "${S_PRI[$i]}" -eq 0 ] && continue          # pinned: never drop
      # ties break toward the right rail, which is always supporting detail
      if [ "${S_PRI[$i]}" -gt "$worst_pri" ] ||
         { [ "${S_PRI[$i]}" -eq "$worst_pri" ] && [ "${S_SIDE[$i]}" = "R" ]; }; then
        worst=$i; worst_pri=${S_PRI[$i]}
      fi
    done
    [ "$worst" -lt 0 ] && return 1                  # only pinned segments left
    S_LIVE[$worst]=0
  done
}
emit() {  # <row> -> justified line
  local row=$1 left right lw rw gap pad
  row_render "$row" L; left=$RR
  row_render "$row" R; right=$RR
  row_width  "$row" L; lw=$RW
  row_width  "$row" R; rw=$RW
  gap=$(( COLS - lw - rw )); [ "$gap" -lt 1 ] && gap=1
  printf -v pad "%${gap}s" ""
  printf '%b%s%b\n' "$left" "$pad" "$right"
}

# --- name budgets scale with the terminal ----------------------------------
# Wide terminal -> more room for names. Narrow -> aggressive truncation. Both
# are then still subject to the priority drop in `fit`, so this is a first pass
# that keeps things pretty, not the thing that guarantees the row fits.
clamp() { local v=$1 lo=$2 hi=$3; [ "$v" -lt "$lo" ] && v=$lo; [ "$v" -gt "$hi" ] && v=$hi; printf '%d' "$v"; }
MODEL_MAX=$(clamp $(( COLS / 6 ))  8 22)
DIR_MAX=$(clamp   $(( COLS / 8 ))  6 20)
BRANCH_MAX=$(clamp $(( COLS / 7 )) 6 24)
SESS_MAX=$(clamp  $(( COLS / 7 ))  0 20)

# ==========================================================================
# ROW 1  --  identity + repo   |   budget
# ==========================================================================
if [ "$CCSL_ROWS" != "1" ]; then
  # model: strip the "(1M context)" parenthetical -- the window size is already
  # spelled out next to the context gauge, so repeating it here is pure noise.
  MNAME=${MODEL%% (*}
  MNAME=$(trunc "$MNAME" "$MODEL_MAX")
  MPFX=""; [ -n "$I_MODEL" ] && MPFX="${I_MODEL} "
  add 1 L 0 "${CYAN}${BOLD}${MPFX}${MNAME}${RESET}" "${MPFX}${MNAME}"

  # effort + thinking, collapsed into one segment. Quiet mode hides the default
  # effort level entirely -- "medium" on screen tells you nothing you didn't
  # already assume.
  MODE=""; MODE_P=""
  if [ -n "$EFFORT" ] && { [ "$CCSL_QUIET" != "1" ] || [ "$EFFORT" != "medium" ]; }; then
    P=""; [ -n "$I_EFFORT" ] && P="${I_EFFORT}"
    MODE="${MAGENTA}${P}${EFFORT}${RESET}"; MODE_P="${P}${EFFORT}"
  fi
  if [ -n "$THINKING" ]; then
    [ -n "$MODE" ] && { MODE="$MODE "; MODE_P="$MODE_P "; }
    MODE="${MODE}${MAGENTA}${I_THINK}${RESET}"; MODE_P="${MODE_P}${I_THINK}"
  fi
  [ -n "$MODE" ] && add 1 L 6 "$MODE" "$MODE_P"

  # repo/branch as one glued unit -- they're read together, and gluing them
  # means the layout engine can't strand a branch name with no repo context.
  if [ "${GIT_OK:-0}" = "1" ] && [ -n "$BRANCH$DIR" ]; then
    D=$(trunc "$DIR" "$DIR_MAX"); B=$(mtrunc "$BRANCH" "$BRANCH_MAX")
    GPFX=""; [ -n "$I_GIT" ] && GPFX="${I_GIT} "
    add 1 L 1 "${WHITE}${GPFX}${D}${RESET}${GREY}/${RESET}${GREEN}${B}${RESET}" "${GPFX}${D}/${B}"

    # working tree: only when dirty. A clean tree says nothing, so it prints
    # nothing -- absence is the signal.
    D2=""; D2P=""
    [ "$STAGED"    -gt 0 ] && { D2="$D2${GREEN}+${STAGED}${RESET} ";  D2P="$D2P+${STAGED} "; }
    [ "$MODIFIED"  -gt 0 ] && { D2="$D2${YELLOW}~${MODIFIED}${RESET} "; D2P="$D2P~${MODIFIED} "; }
    [ "$UNTRACKED" -gt 0 ] && { D2="$D2${RED}?${UNTRACKED}${RESET} ";  D2P="$D2P?${UNTRACKED} "; }
    [ -n "$D2" ] && add 1 L 2 "${D2% }" "${D2P% }"

    D3=""; D3P=""
    [ "${AHEAD:-0}"  -gt 0 ] && { D3="$D3${CYAN}${I_AHEAD}${AHEAD}${RESET} ";  D3P="$D3P${I_AHEAD}${AHEAD} "; }
    [ "${BEHIND:-0}" -gt 0 ] && { D3="$D3${CYAN}${I_BEHIND}${BEHIND}${RESET} "; D3P="$D3P${I_BEHIND}${BEHIND} "; }
    [ -n "$D3" ] && add 1 L 4 "${D3% }" "${D3P% }"
  fi

  # PR: loud when it wants something from you, a tick when it doesn't.
  if [ -n "$PR_NUM" ]; then
    if [ "$USE_NERD" = "1" ]; then PRLBL="${I_PR} ${PR_NUM}"; else PRLBL="${I_PR}#${PR_NUM}"; fi
    case "$PR_STATE" in
      changes_requested) add 1 L 3 "${BLUE}${PRLBL}${RESET} $(blink "${RED}changes${RESET}")" "${PRLBL} changes" ;;
      draft)             add 1 L 7 "${GREY}${PRLBL} draft${RESET}" "${PRLBL} draft" ;;
      approved)          add 1 L 7 "${BLUE}${PRLBL}${RESET}${GREEN}${I_OK}${RESET}" "${PRLBL}${I_OK}" ;;
      *)                 add 1 L 5 "${BLUE}${PRLBL}${RESET} ${YELLOW}review${RESET}" "${PRLBL} review" ;;
    esac
  fi

  # Free text the model chose. Lowest priority and hard-capped: a session named
  # "Investigating the Great Wombat Regression of 2026" gets 20 columns at most
  # and is the first thing thrown overboard when the row is tight.
  if [ -n "$SESSNAME" ] && [ "$SESS_MAX" -ge 6 ]; then
    SN=$(trunc "$SESSNAME" "$SESS_MAX")
    add 1 L 8 "${DIM}${SN}${RESET}" "$SN"
  fi
  [ "$OUTSTYLE" != "default" ] && add 1 L 8 "${DIM}${OUTSTYLE}${RESET}" "$OUTSTYLE"

  [ "$API_BUSY" = "1" ] && add 1 L 2 "${BRIGHT}${SPIN}${RESET}" "$SPIN"

  # --- right rail: the actual budget ---------------------------------------
  HAVE_RL=0
  if [ "$RL5" != "-1" ]; then
    HAVE_RL=1; RL5I=${RL5%.*}; C=$(pcolor "$RL5I")
    LP=""; [ -n "$I_LIMIT" ] && LP="${I_LIMIT} "
    T="${C}${LP}5h ${RL5I}%${RESET}"; TP="${LP}5h ${RL5I}%"
    [ "$RL5I" -ge 90 ] && T=$(blink "${C}${LP}5h ${RL5I}%${RESET}")
    if [ "$RL5_RESET" -gt 0 ]; then
      U=$(until_reset "$RL5_RESET")
      T="$T ${DIM}${I_RESET}${U}${RESET}"; TP="$TP ${I_RESET}${U}"
    fi
    add 1 R 1 "$T" "$TP"
  fi
  # Seven-day window: only interesting once something is warm. Below that it's a
  # number that never moves, so it's hidden and can't crowd the five-hour one.
  if [ "$RL7" != "-1" ]; then
    RL7I=${RL7%.*}; RL5I2=${RL5%.*}; [ "$RL5" = "-1" ] && RL5I2=0
    if [ "$CCSL_QUIET" != "1" ] || [ "$RL7I" -ge 60 ] || [ "$RL5I2" -ge 60 ]; then
      C=$(pcolor "$RL7I")
      T="${C}7d ${RL7I}%${RESET}"; TP="7d ${RL7I}%"
      [ "$RL7I" -ge 90 ] && T=$(blink "${C}7d ${RL7I}%${RESET}")
      add 1 R 5 "$T" "$TP"
    fi
  fi
  # Runway: pinned, because "you will run dry before the window resets" is the
  # single most decision-changing thing this status line can say. Only shown
  # when it's actually true.
  if [ "$CCSL_RUNWAY" = "1" ] && [ "${ETA_RL_AT:-0}" -gt "$NOW" ] && [ "${RL5_RESET:-0}" -gt 0 ] &&
     [ "$ETA_RL_AT" -lt "$RL5_RESET" ]; then
    E=$(until_reset "$ETA_RL_AT")
    add 1 R 0 "$(blink "${RED}${I_WARN} dry ~${E}${RESET}")" "${I_WARN} dry ~${E}"
  fi
  # No rate limits (API auth) -> the cost estimate is the only budget signal
  # there is, so it moves here instead of a "no data" placeholder.
  if [ "$HAVE_RL" = "0" ]; then
    add 1 R 3 "${YELLOW}$(printf '~$%.2f' "$COST")${RESET}" "$(printf '~$%.2f' "$COST")"
  fi

  fit 1
fi

# ==========================================================================
# ROW 2  --  context gauge   |   work
# ==========================================================================
# Build the right rail first so the gauge knows how much room it really has.
if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
  XP=""; [ -n "$I_LINES" ] && XP="${I_LINES} "
  add 2 R 4 "${XP}${GREEN}+${ADDED}${RESET}${GREY}/${RESET}${RED}-${REMOVED}${RESET}" "${XP}+${ADDED}/-${REMOVED}"
fi
# Session duration: below a minute it's noise. The api-vs-wall split that used
# to live here was interesting exactly once, so it's gone.
if [ "$DUR_MS" -ge 60000 ]; then
  TP=""; [ -n "$I_TIME" ] && TP="${I_TIME} "
  add 2 R 5 "${DIM}${TP}$(dur "$DUR_MS")${RESET}" "${TP}$(dur "$DUR_MS")"
fi
# Cost estimate, when rate limits already answered the budget question. Lowest
# priority on the row: it's an estimate, not a bill.
if [ "$RL5" != "-1" ] || [ "$CCSL_ROWS" = "1" ]; then
  add 2 R 6 "${DIM}${YELLOW}$(printf '~$%.2f' "$COST")${RESET}" "$(printf '~$%.2f' "$COST")"
fi
# The two left-hand extras are measured now but added AFTER the gauge, because
# `add` order is render order and the gauge has to come first. Measuring them
# up front is what lets the gauge claim exactly the leftover width.
RUNWAY_TXT=""; RUNWAY_PLAIN=""
if [ "$CCSL_RUNWAY" = "1" ] && [ "${ETA_CTX_AT:-0}" -gt "$NOW" ] &&
   [ $(( ETA_CTX_AT - NOW )) -lt 2700 ]; then
  E=$(until_reset "$ETA_CTX_AT")
  RUNWAY_PLAIN="compact ~${E}"
  RUNWAY_TXT="${DIM}${YELLOW}${RUNWAY_PLAIN}${RESET}"
fi
TOK_PLAIN="$(human "$CTX_IN")/${CTX_LABEL}"
TOK_TXT="${GREY}${TOK_PLAIN}${RESET}"

# Gauge width: whatever is left after everything else on the row, clamped.
OTHER_L=$(( ${#TOK_PLAIN} + SEP_W ))
[ -n "$RUNWAY_PLAIN" ] && OTHER_L=$(( OTHER_L + ${#RUNWAY_PLAIN} + SEP_W ))
row_width 2 R; OTHER_R=$RW
[ "$OTHER_R" -gt 0 ] && OTHER_R=$(( OTHER_R + 2 ))
PCT_W=$(( ${#CTX_PCT} + 2 ))
BAR_W=$(( COLS - OTHER_L - OTHER_R - PCT_W - 2 ))
[ "$BAR_W" -gt "$CCSL_BAR_MAX" ] && BAR_W=$CCSL_BAR_MAX
[ "$BAR_W" -lt 10 ] && BAR_W=10
BC=$(pcolor "$CTX_PCT")

# --- the gauge -------------------------------------------------------------
# Eighth-blocks give sub-cell resolution: FILL8 is the fill measured in eighths
# of a cell, so the last cell shows a partial block instead of rounding away up
# to a whole cell's worth of context.
FILL8=$(( CTX_PCT * BAR_W * 8 / 100 ))
[ "$FILL8" -gt $(( BAR_W * 8 )) ] && FILL8=$(( BAR_W * 8 ))
[ "$FILL8" -lt 0 ] && FILL8=0
FULL=$(( FILL8 / 8 )); REM=$(( FILL8 % 8 ))
[ "$CCSL_ASCII" = "1" ] && { REM=0; }
PART=""; [ "$REM" -gt 0 ] && PART="${EIGHTHS[$REM]}"
[ -n "$PART" ] || REM=0
CELLS=$(( FULL + (REM > 0 ? 1 : 0) ))
EMPTY=$(( BAR_W - CELLS ))
[ "$EMPTY" -lt 0 ] && EMPTY=0

BASE_FG=$BC
[ "${#RAMP[@]}" -ge 3 ] && BASE_FG=${RAMP[0]}

# Motion: a two-cell bright band travels the filled region, but ONLY while the
# API is busy. Idle ticks render byte-identical output -- at 1 fps a moving
# highlight reads as a rendering glitch, not as animation. See the header.
MOVING=0
[ "$CCSL_MOTION" = "busy" ] && [ "$API_BUSY" = "1" ] && [ "${#RAMP[@]}" -ge 3 ] &&
  [ "$FULL" -gt 4 ] && [ "$CCSL_COLOR" = "1" ] && MOVING=1

if [ "$MOVING" = "1" ]; then
  # band start sweeps 0..FULL-2 and wraps; colour-only, so width is unchanged
  POS=$(( TICK % (FULL - 1) ))
  printf -v A "%${POS}s" ""
  printf -v B "%$(( FULL - POS - 2 ))s" ""
  BAR="${BASE_FG}${A// /$G_FULL}${RAMP[2]}${G_FULL}${RAMP[1]}${G_FULL}${BASE_FG}${B// /$G_FULL}${RESET}"
else
  # Static gloss at the fill edge: the last cells step up through brighter
  # shades of the same hue, so the gauge reads as lit while never changing.
  GLOSS=0
  [ "$CCSL_SHINE" = "1" ] && [ "${#RAMP[@]}" -ge 3 ] && [ "$FULL" -gt 3 ] && GLOSS=1
  if [ "$GLOSS" = "1" ]; then
    printf -v FF "%$(( FULL - 3 ))s" ""
    BAR="${BASE_FG}${FF// /$G_FULL}${RAMP[1]}${G_FULL}${G_FULL}${RESET}${RAMP[2]}${G_FULL}${RESET}"
  else
    printf -v FF "%${FULL}s" ""; BAR="${BASE_FG}${FF// /$G_FULL}${RESET}"
  fi
fi
[ "$REM" -gt 0 ] && BAR="${BAR}${RAMP[2]:-$BC}${PART}${RESET}"

# Empty region, with the auto-compact threshold marked. The marker replaces one
# empty cell (never adds width). Once the fill passes it the whole gauge is
# already in warn colours, so the marker just disappears under the fill.
MARK_CELL=$(( CCSL_COMPACT_PCT * BAR_W / 100 ))
[ "$MARK_CELL" -ge "$BAR_W" ] && MARK_CELL=$(( BAR_W - 1 ))
if [ "$EMPTY" -gt 0 ] && [ "$MARK_CELL" -ge "$CELLS" ]; then
  LGAP=$(( MARK_CELL - CELLS ))
  RGAP=$(( EMPTY - LGAP - 1 )); [ "$RGAP" -lt 0 ] && RGAP=0
  printf -v EL "%${LGAP}s" ""; printf -v ER "%${RGAP}s" ""
  BAR="${BAR}${GREY}${EL// /$G_EMPTY}${YELLOW}${G_MARK}${GREY}${ER// /$G_EMPTY}${RESET}"
else
  printf -v EE "%${EMPTY}s" ""; BAR="${BAR}${GREY}${EE// /$G_EMPTY}${RESET}"
fi

PCT_SEG="${BC}${BOLD}${CTX_PCT}%${RESET}"
[ "$CTX_PCT" -ge 90 ] && PCT_SEG=$(blink "${BC}${BOLD}${CTX_PCT}%${RESET}")

# Gauge first (pinned at priority 0 -- it is the reason this status line
# exists), then the extras that were measured above. Its printable width is
# passed explicitly: the string is nothing but colour codes and block glyphs,
# so ${#...} on the rendered form would be meaningless.
addw 2 L 0 "${BAR} ${PCT_SEG}" $(( BAR_W + 1 + ${#CTX_PCT} + 1 ))
[ -n "$RUNWAY_PLAIN" ] && add 2 L 3 "$RUNWAY_TXT" "$RUNWAY_PLAIN"
add 2 L 4 "$TOK_TXT" "$TOK_PLAIN"

fit 2

[ "$CCSL_ROWS" != "1" ] && emit 1
emit 2
