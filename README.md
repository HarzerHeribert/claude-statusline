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
| `CCSL_WAVE`     | `1`     | scrolling color gradient across the filled bar       |
| `CCSL_PULSE`    | `1`     | breathing (dim↔bright) intensity on the bar          |
| `CCSL_WARN_ANIM`| `1`     | blink high context/rate-limit + "changes requested"  |
| `CCSL_SEP_ANIM` | `0`     | animate the `::` / `\|` separators (subtle)           |
| `CCSL_MARQUEE`  | `0`     | cycle the right rail of row 2 (off = show all)       |
| `CCSL_DECOUPLE` | `1`     | skip jq/git on unchanged ticks (cache parsed data)   |
| `CCSL_DATA_TTL` | `5`     | max seconds to trust the data snapshot               |
| `CCSL_GIT_TTL`  | `2`     | seconds to cache git state between animation ticks    |
| `CCSL_REFRESH`  | `10`    | must match `refreshInterval` for frame timing        |
| `CCSL_BAR_MAX`  | `60`    | max context-bar width, chars                          |
| `CCSL_COLOR`    | `1`     | colored output (`0` = plain)                          |
| `CCSL_COLOR256` | `auto`  | 256-color ramp for the wave when supported           |
| `CCSL_ASCII`    | `0`     | `1` = ASCII bar (`#`/`-`) + `\|/-\` spinner           |
| `CCSL_NERD`     | `auto`  | `auto` detect a Nerd Font, `1` force icons, `0` off   |
| `CCSL_MARGIN`   | `6`     | columns reserved at the right edge (anti-clip)        |

### Nerd Font icons

With a [Nerd Font](https://nerdfonts.com) installed and selected in your terminal,
the status line shows glyphs instead of text labels:

```
 Opus 4.8:1M   high    ::  bitesize  main   1  1  ::   673 OK
 [████▓██░░░] 13% 128k/1M                        ~$16.52  |   +830/-107  |   17m
```

`CCSL_NERD=auto` (default) uses icons only when a Nerd Font is detected, so it's
safe on machines without one — it falls back to `eff:high`, `git:main`, `↑1 ↓1`,
`PR#673`, etc. The installer can install **JetBrainsMono Nerd Font** for you:

```bash
./install.sh --nerd      # brew-install the font + force icons on
./install.sh --no-nerd   # skip the font, use the ASCII/Unicode fallback
./install.sh             # detects a font; if none, offers to install it
```

After installing, **set your terminal profile's font** to the Nerd Font (e.g.
"JetBrainsMono Nerd Font") — the shell can't switch the terminal font for you.

> **The font must be selected in whatever actually draws the terminal.** Installing
> the font is not enough; each terminal app, multiplexer, or wrapper has its own font
> setting that has to point at the Nerd Font:
>
> - **Warp** — Settings (`Cmd+,`) → Appearance → Text → *Terminal font*
> - **iTerm2** — Settings → Profiles → Text → *Font*
> - **Apple Terminal** — Settings → Profiles → Text → *Font*
> - **VS Code / Cursor integrated terminal** — set `"terminal.integrated.fontFamily": "JetBrainsMono Nerd Font"`
> - **Alacritty / Kitty / WezTerm** — set the font family in their config file
> - **tmux / screen** — these don't draw glyphs themselves, but they can mangle
>   wide/PUA glyphs; make sure the *outer* terminal uses the Nerd Font
>
> If icons show as blank cells or boxes, the drawing layer isn't using the Nerd Font
> yet. Prefer the plain `JetBrainsMono Nerd Font` variant over the `…Mono`/`…Propo`
> variants — the `Mono` variant squeezes icons into a narrow cell and can clip them.

## Animation is decoupled from data

Claude Code sends the JSON payload on stdin and only changes it when real data
changes. So the script splits into two phases:

1. **Data** — hash stdin; if it matches the last snapshot (and the snapshot is
   younger than `CCSL_DATA_TTL`), reuse the cached parsed values and **skip `jq`
   and `git` entirely.** Otherwise parse with `jq`, gather git state, and write a
   fresh snapshot.
2. **Animation** — always runs, but it's pure arithmetic off a wall-clock frame
   counter (`epoch / refreshInterval`). No subprocesses.

The result: a tick where nothing changed is just a `cksum` + a `source` + string
math. Every animation (shimmer, wave, pulse, warn-blink, separators) is
**width-invariant** — it only changes colors or swaps equal-width glyphs — so the
right-aligned rail never jitters between frames.

This does **not** raise the frame rate (that's capped at 1s, see below); it makes
each frame as cheap as possible.

## Performance

The script does no network I/O and **costs zero API tokens** — Claude Code runs it
locally.

- **Unchanged tick (the common case):** no `jq`, no `git` — just a hash + reading
  the cached snapshot. **~3–8 ms.**
- **Data changed:** one `jq` parse + (on a git-cache miss) ~8 short-lived `git`
  subprocesses. **~25–45 ms.**

Measured on an Apple Silicon Mac. At `refreshInterval: 1` the idle cost is well
**under a few percent of one CPU core, and 0% while you're actively working** (the
timer is paused then). Raise `CCSL_DATA_TTL` / `CCSL_GIT_TTL` or the interval to
make it lighter still; set `CCSL_DECOUPLE=0` to always re-parse (debugging).

## Why the animation updates once per second

`refreshInterval: 1` is the **fastest Claude Code allows** — the
[docs](https://code.claude.com/docs/en/statusline) state the minimum is `1` second,
so one frame per second is the ceiling, not a choice. Two more facts worth knowing:

- Frames are derived from wall-clock time (`epoch / refreshInterval`), so at a 1 s
  interval the shimmer/spinner advance one step per second.
- The refresh timer **only fires while the session is idle.** During active
  streaming the harness drives status-line updates its own way, so you won't see
  steady 1 s animation mid-response. This is a platform constraint, not a bug.

Set `CCSL_ANIM=0` for a fully static line if you'd rather not have the tick at all.

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
