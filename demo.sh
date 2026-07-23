#!/usr/bin/env bash
# demo.sh — render the status line live in your terminal so you can see it,
# without needing a Claude Code session. Ctrl-C to quit.
#
# The loop deliberately ticks at ~2.5 fps, which is roughly the rate Claude Code
# actually re-renders at while the model is working (the 1s timer plus
# event-driven updates on a 300ms debounce). It cycles:
#
#   ~6s BUSY  — total_api_duration_ms advances, so the script sees the API as
#               active: the spinner runs and the gauge sweeps.
#   ~6s IDLE  — the payload is frozen. Watch the gauge go completely still;
#               that is the point. At 1 fps motion reads as a glitch, so idle
#               ticks render byte-identical output.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLS=$(tput cols 2>/dev/null || echo 120)
NOW=$(date +%s)
STEP=0
ACT=0

trap 'tput cnorm 2>/dev/null; echo; exit 0' INT
tput civis 2>/dev/null  # hide cursor

while true; do
  STEP=$(( STEP + 1 ))
  # 15 steps busy, 15 steps idle, at 0.4s per step
  phase=$(( (STEP / 15) % 2 ))
  if [ "$phase" -eq 0 ]; then
    ACT=$(( ACT + 1 ))
    label="BUSY  — api time advancing: spinner runs, gauge sweeps"
  else
    label="IDLE  — payload frozen: everything holds perfectly still"
  fi
  el=$(( 600000 + ACT * 24000 )); api=$(( 180000 + ACT * 9000 ))
  pct=$(( 20 + (ACT * 2) % 70 ))
  tok=$(( pct * 2000 ))
  payload=$(cat <<JSON
{"model":{"display_name":"Opus 4.8 (1M context)"},
 "workspace":{"current_dir":"$DIR"},
 "effort":{"level":"high"},"thinking":{"enabled":true},
 "context_window":{"used_percentage":$pct,"total_input_tokens":$tok,"context_window_size":200000},
 "cost":{"total_cost_usd":12.34,"total_duration_ms":$el,"total_api_duration_ms":$api,
         "total_lines_added":198,"total_lines_removed":28},
 "rate_limits":{"five_hour":{"used_percentage":34,"resets_at":$(( NOW + 7200 ))},
                "seven_day":{"used_percentage":61}},
 "session_id":"demo"}
JSON
)
  out=$(printf '%s' "$payload" | \
    COLUMNS=$COLS CCSL_COLOR256=1 "$DIR/statusline.sh")
  tput cup 0 0 2>/dev/null; tput ed 2>/dev/null
  printf '%s\n' "$out"
  printf '\033[2m(demo — %s; Ctrl-C to quit)\033[0m\n' "$label"
  sleep 0.4
done
