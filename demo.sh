#!/usr/bin/env bash
# demo.sh — render the status line live in your terminal so you can see the
# animation, without needing a Claude Code session. Ctrl-C to quit.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLS=$(tput cols 2>/dev/null || echo 120)
START=$(date +%s)

trap 'tput cnorm 2>/dev/null; echo; exit 0' INT
tput civis 2>/dev/null  # hide cursor

while true; do
  now=$(date +%s); el=$(( (now-START)*1000 ))
  # a fake, slowly-growing session; api_ms advances every other second so the
  # spinner toggles busy/idle
  api=$(( el / 2 ))
  pct=$(( 10 + (now-START)*2 % 80 ))
  payload=$(cat <<JSON
{"model":{"display_name":"Opus 4.8 (1M context)"},
 "workspace":{"current_dir":"$DIR"},
 "effort":{"level":"high"},"thinking":{"enabled":true},
 "context_window":{"used_percentage":$pct,"total_input_tokens":$((pct*10000)),"context_window_size":1000000},
 "cost":{"total_cost_usd":12.34,"total_duration_ms":$el,"total_api_duration_ms":$api,"total_lines_added":198,"total_lines_removed":28},
 "session_id":"demo"}
JSON
)
  out=$(COLUMNS=$COLS CCSL_REFRESH=1 printf '%s' "$payload" | COLUMNS=$COLS CCSL_REFRESH=1 "$DIR/statusline.sh")
  tput cup 0 0 2>/dev/null; tput ed 2>/dev/null
  printf '%s\n' "$out"
  printf '\033[2m(demo — Ctrl-C to quit)\033[0m\n'
  sleep 1
done
