# claude-statusline

A verbose, full-width, **no-emoji**, lightly **animated** status line for
[Claude Code](https://code.claude.com/docs/en/statusline).

Two rows, left/right justified to fill the terminal:

```
Opus 4.8 (1M context):1M  eff:xhigh  think:on  ⠏ working    :: bitesize git:main clean ^1 v1  :: PR#673 OK          5h 23% 2h14m  |  7d 41% 83h20m
ctx [███████████▓██████████░░░░░░░░░░░░░░░░░░░░] 38% 379k/1M                                          ~$1283.62  |  +22909/-967  |  25h11m (api 8h03m)
```

- **Row 1** — model + context-window size (`1M`/`200k`), reasoning effort, thinking
  state, output style, session name; then repo, git branch, working-tree state
  (`+staged ~modified ?untracked` or `clean`), ahead/behind (`^ v`), and open-PR
  number with review state (`OK` / `CHANGES` / `DRAFT` / `REVIEW`). Rate limits on
  the right.
- **Row 2** — a context-usage bar (color-coded, scales to terminal width) with % and
  token count; cost estimate, lines changed, and durations on the right.

### Animation (tick-based)

Claude Code re-runs the status line on events and every `refreshInterval` seconds.
Frames advance off wall-clock time, so no persistent state is needed.

- **Spinner** — `⠋⠙⠹…` next to the model while the API is actively responding
  (detected by watching `total_api_duration_ms` advance between ticks).
- **Shimmer** — a bright cell sweeps across the filled part of the context bar.
- **Marquee** *(opt-in)* — the right rail of row 2 cycles through
  cost → lines → durations → tokens, one per tick.

## Honest about cost

`cost.total_cost_usd` is a **client-side estimate**, not your bill — shown as `~$…`.
The real budget signal on a Pro/Max subscription is `rate_limits` (5h + 7d windows
with reset countdowns), which the API only sends to subscribers. When absent (API
auth), the status line says so rather than faking a number.

## Install

Requires `bash`, `jq`, and `git`. On macOS: `brew install jq`.

```bash
git clone https://github.com/HarzerHeribert/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer copies `statusline.sh` to `~/.claude/`, backs up your
`settings.json`, and wires up the `statusLine` block with `refreshInterval: 10`.
It appears on your next interaction with Claude Code.

```bash
REFRESH=5 ./install.sh     # faster animation
./install.sh --dry-run     # show changes, do nothing
./install.sh --uninstall   # remove the statusLine block (keeps the script)
```

## Preview it without a session

```bash
./demo.sh        # live animated render in your terminal (Ctrl-C to quit)
```

## Configuration

Set these as env vars (e.g. inside the `command` in `settings.json`, or your shell
profile):

| Var             | Default | Meaning                                             |
| --------------- | ------- | --------------------------------------------------- |
| `CCSL_ANIM`     | `1`     | master switch for all animation                     |
| `CCSL_SPINNER`  | `1`     | spinner while API is busy                            |
| `CCSL_SHIMMER`  | `1`     | sweeping bright cell in the context bar              |
| `CCSL_MARQUEE`  | `0`     | cycle the right rail of row 2 (off = show all)       |
| `CCSL_REFRESH`  | `10`    | must match `refreshInterval` for frame timing        |
| `CCSL_BAR_MAX`  | `60`    | max context-bar width, chars                          |
| `CCSL_COLOR`    | `1`     | colored output (`0` = plain)                          |
| `CCSL_ASCII`    | `0`     | `1` = ASCII bar (`#`/`-`) + `\|/-\` spinner           |

Example — static, ASCII, no color:

```json
{
  "statusLine": {
    "type": "command",
    "command": "CCSL_ANIM=0 CCSL_ASCII=1 CCSL_COLOR=0 ~/.claude/statusline.sh",
    "refreshInterval": 10
  }
}
```

## How it works

Claude Code pipes [session JSON](https://code.claude.com/docs/en/statusline#available-data)
to the script on stdin; the script prints two lines to stdout. It reads `COLUMNS`
(set by the harness) for terminal width, uses `jq` to parse the payload, and caches
one integer per session under `$TMPDIR` for spinner busy-detection. No network, no
token cost.

## License

MIT — see [LICENSE](LICENSE).
