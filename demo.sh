#!/usr/bin/env bash
# demo.sh — render the status line live in your terminal so you can see it,
# without needing a Claude Code session. Ctrl-C to quit.
#
# Cycles 12s: ~5s "active" (the payload changes each tick, so the spinner runs
# and the numbers move), then ~7s idle (the payload is frozen — note the bar
# and everything else hold perfectly still; only state flips ever animate).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLS=$(tput cols 2>/dev/null || echo 120)
START=$(date +%s)
ACT=0

trap 'tput cnorm 2>/dev/null; echo; exit 0' INT
tput civis 2>/dev/null  # hide cursor

while true; do
  now=$(date +%s); t=$(( now - START ))
  phase=$(( t % 12 ))
  label="idle   (everything holds still; static gloss at the fill edge)"
  if [ "$phase" -lt 5 ]; then
    # active: advance the fake session so the spinner + numbers move
    ACT=$(( ACT + 1 ))
    label="active (spinner runs, numbers move; the bar itself never animates)"
  fi
  el=$(( ACT * 1800 )); api=$(( ACT * 900 ))
  pct=$(( 15 + ACT * 3 % 75 ))
  payload=$(cat <<JSON
{"model":{"display_name":"Opus 4.8 (1M context)"},
 "workspace":{"current_dir":"$DIR"},
 "effort":{"level":"high"},"thinking":{"enabled":true},
 "context_window":{"used_percentage":$pct,"total_input_tokens":$((pct*10000)),"context_window_size":1000000},
 "cost":{"total_cost_usd":12.34,"total_duration_ms":$el,"total_api_duration_ms":$api,"total_lines_added":198,"total_lines_removed":28},
 "session_id":"demo"}
JSON
)
  out=$(printf '%s' "$payload" | \
    COLUMNS=$COLS CCSL_REFRESH=1 CCSL_COLOR256=1 "$DIR/statusline.sh")
  tput cup 0 0 2>/dev/null; tput ed 2>/dev/null
  printf '%s\n' "$out"
  printf '\033[2m(demo — %s; Ctrl-C to quit)\033[0m\n' "$label"
  sleep 1
done
