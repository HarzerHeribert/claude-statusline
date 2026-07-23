# claude-statusline

A quiet, full-width, **no-emoji** status line for
[Claude Code](https://code.claude.com/docs/en/statusline) that tells you how much
runway you have left.

Two rows, left/right justified to fill the terminal. When nothing is wrong, it
stays out of the way (Nerd Font icons shown; falls back to Unicode without one):

```
◆ Opus 4.8 · high ✻ · claude-statu…/main · ~3                                                    5h 23% ↻2h14m
████████████████▋░░░░░░░░░░░░░░░░░░░░░░░╎░░░ 38% · 76k/200k                            +229/-96 · 18m · ~$4.21
```

When something *is* wrong, the same two rows say so — without getting any wider:

```
◆ Opus 4.8 · xhigh ✻ · claude-statu…/main · ~3 · PR#673 changes · ⠙           5h 90% ↻45m · 7d 74% · ⚠ dry ~5m
██████████████████████████████████████▋░╎░░░ 88% · compact ~3m · 176k/200k        +1204/-655 · 2h30m · ~$31.80
```

The second render is the interesting one. `5h 90%` is a fact you could get
anywhere. `⚠ dry ~5m` is the part that changes what you do next: at the rate
you're actually burning it, you hit the five-hour limit in five minutes, and the
window doesn't reset for forty-five. Same for `compact ~3m` on the context row.

## Three ideas

### 1. Quiet by default

The status line is on screen permanently, so every character has to earn its
place. A segment appears only when it's **actionable**:

| Situation | What you see |
| --------- | ------------ |
| Clean working tree | *nothing* — absence is the signal |
| Approved PR | `PR#673✓` |
| PR wants changes | `PR#673 changes`, blinking |
| Both rate-limit windows cool | just the 5h one; `7d` stays hidden until either passes 60% |
| Default reasoning effort | *nothing* |
| Session under a minute old | no duration |
| Rate limits present | the cost estimate demotes to last place |

`CCSL_QUIET=0` turns all of this off and shows everything, always.

### 2. Nothing can push out something more important

Every segment carries a priority. The layout engine measures the row and drops
the least important segments until it fits. Free text that the model or the repo
controls — session names, project directories, branch names — is **both**
truncated to a width budget **and** given low priority, so it can never crowd out
the context gauge or your remaining budget.

Watch the same session — 56-character session name, 62-character branch,
51-character project directory — get narrower (real output, row 1 only):

```
160  ◆ Opus 4.8 · xhigh ✻ · enterprise-platfor…/feature/PL…efresh-flow · +1 ?1 · Untangling The Lega… · ⠙                                5h 58% ↻1h00m · 7d 66%
120  ◆ Opus 4.8 · xhigh ✻ · enterprise-pl…/feature…esh-flow · +1 ?1 · Untangling The …           5h 58% ↻1h00m · 7d 66%
100  ◆ Opus 4.8 · xhigh ✻ · enterprise…/featur…h-flow · +1 ?1                5h 58% ↻1h00m · 7d 66%
 80  ◆ Opus 4.8 · enterpri…/feat…-flow · +1 ?1           5h 58% ↻1h00m · 7d 66%
 64  ◆ Opus 4.8 · enterp…/fea…flow · +1 ?1        5h 58% ↻1h00m
```

The session name goes first, then the output style, then effort/thinking, then
the seven-day window. The gauge and the five-hour budget are pinned and never
drop. Branch names are truncated in the *middle*, because the distinguishing
part of `feature/PLATFORM-48291-migrate-legacy-oauth-token-refresh-flow` is its
tail, not its head.

Verified across 378 render combinations (9 payloads × 7 modes × 6 terminal
widths): no row ever exceeds its column budget.

### 3. Runway, not just level

Percentages tell you where you are. They don't tell you whether you'll make it
to the reset. The script samples context and rate-limit usage on every
data-changing tick, fits a rate over the last 30 minutes, and extrapolates:

- **`⚠ dry ~10m`** — you will exhaust the five-hour window *before* it resets.
  Only shown when that's actually true, and pinned at the highest priority when
  it is.
- **`compact ~6m`** — projected time until context hits the auto-compact
  threshold. Only shown when it's under 45 minutes, i.e. close enough to plan
  around.

Both are stored as absolute target timestamps, so they keep counting down
correctly even on cached render-only ticks. `CCSL_RUNWAY=0` disables them.

## The gauge

```
████████████████▋░░░░░░░░░░░░░░░░░░░░░░░╎░░░ 38%
                ↑                       ↑
                partial cell            auto-compact threshold
```

Eighth-block glyphs (`▏▎▍▌▋▊▉█`) give the fill **8× the resolution** of a normal
block bar, so a 24-cell gauge resolves about half a percent and small context
moves are actually visible instead of sitting on the same whole block for ten
percentage points.

The `╎` marks where the harness auto-compacts (`CCSL_COMPACT_PCT`, default 92).
That threshold is worth marking because `context_window.used_percentage` — the
number `/context` shows and the one on the gauge — is **not** the same 100% the
harness's context alerts fire against. Those fire against the usable budget
(window − output reservation − compaction margin). So a 73% gauge can coexist
with a "context low" alert. Marking the line keeps the familiar percentage
*and* shows you the line that actually matters.

## Animation: measured, not guessed

**Short version: the periodic refresh is hard-capped at 1 fps, but that isn't
the whole story — while the model is working you get 2–3 renders per second for
free.** So the gauge sweeps only while the API is busy, and is byte-identical
when idle.

### The 1 fps cap is real, and it's two clamps deep

Claude Code 2.1.217 validates the setting as `number().min(1)` and then clamps
it again at runtime:

```js
refreshInterval: v.number().min(1).optional().catch(void 0)   // schema
gc(U, G !== void 0 ? Math.max(1, G) * 1000 : null)            // runtime
```

Asking for `0.2` gets you exactly 1.000s. Confirmed by probe — a wrapper that
logged millisecond timestamps on every invocation, with `refreshInterval: 0.2`
configured, over 157 ticks:

```
min gap  0.300s     median  1.000s     max  1.281s

0.2–0.3s :  1        0.9–1.0s : 47
0.3–0.4s :  4        1.0–1.1s : 86     ← the timer
0.4–0.5s :  3        1.2–1.3s :  3
0.5–0.8s : 12        ← event-driven
```

### But event-driven renders stack on top

The 133 ticks in the 0.9–1.1s buckets are the timer. The 20 ticks **below 0.8s**
are event-driven re-renders, which fire whenever session state changes and are
debounced at 300ms — the fastest observed gap is exactly 0.300s, the debounce
floor. Those only happen while the model is actively working.

So there are two regimes, and they want opposite things:

| | render rate | motion reads as |
| --- | --- | --- |
| Idle | ~1 fps | a rendering glitch |
| Model working | ~2–3 fps | motion |

Hence: **the gauge sweeps only while the API is busy** (detected by watching
`total_api_duration_ms` advance between ticks) and renders byte-identical output
when idle, where it gets a static same-hue gloss at the fill edge instead.

The sweep advances off an **invocation counter**, not a wall clock, so it
automatically runs at whatever rate Claude Code is actually re-rendering at —
no frame-rate configuration to keep in sync. `CCSL_MOTION=off` disables it.

### What you still can't do

- **Stream frames from one invocation.** The harness `await`s the command to
  completion and takes the result once (`let l = await r(); ... i(l)`). An
  in-flight run is discarded entirely when a new update supersedes it.
- **Get a smooth sub-second clock.** Event-driven ticks are irregular and only
  occur during activity. They're enough for a sweep; they're not a frame timer.

Filed as [a feature request](https://github.com/anthropics/claude-code/issues)
against `anthropics/claude-code`.

## Honest about cost

`cost.total_cost_usd` is a **client-side estimate**, not your bill — shown as
`~$…`. The real budget signal on a Pro/Max subscription is `rate_limits` (5h +
7d windows with reset countdowns), which the API only sends to subscribers.

So when rate limits *are* present, the cost estimate is demoted to the lowest
priority on the row and is the first thing dropped. When they're absent (API
auth), it moves up to the budget rail — because then it's the only budget signal
there is. No "no data available" placeholder either way.

## Install

One line, no clone needed — the installer downloads `statusline.sh` for you:

```bash
curl -fsSL https://raw.githubusercontent.com/HarzerHeribert/claude-statusline/main/install.sh | bash
```

Pass flags after `--`, or env vars before `bash`:

```bash
curl -fsSL .../install.sh | bash -s -- --no-nerd   # skip the Nerd Font
curl -fsSL .../install.sh | REFRESH=5 bash          # slower tick
```

Or clone and run it locally (identical behavior; uses the local script instead
of downloading):

```bash
git clone https://github.com/HarzerHeribert/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer copies `statusline.sh` to `~/.claude/`, backs up your
`settings.json`, and wires up the `statusLine` block with `refreshInterval: 1`.
It appears on your next interaction with Claude Code.

```bash
REFRESH=5 ./install.sh     # slower tick, if you want it even lighter
./install.sh --dry-run     # show changes, do nothing
./install.sh --uninstall   # remove the statusLine block (keeps the script)
```

### Platform support

Works on **Linux** (all major distros), **macOS**, and **Windows** via Git Bash
or WSL.

Minimal prerequisites: `bash`, `jq`, and `git`, plus `curl` or `wget` when the
installer needs to download files. The installer keeps this minimal and will
install missing prerequisites for you when it finds a supported package manager:

| Platform / manager        | Used for missing prerequisites                    |
| ------------------------- | ------------------------------------------------- |
| Debian / Ubuntu           | `apt-get install jq git curl/wget unzip fontconfig` |
| Fedora / RHEL             | `dnf` / `yum install ...`                         |
| Arch                      | `pacman -S ...`                                   |
| openSUSE                  | `zypper install ...`                              |
| Alpine                    | `apk add ...`                                     |
| macOS                     | `brew install ...` or `port install ...`          |
| Windows                   | `choco`, `winget`, `scoop`, or Git Bash `pacman`  |

If no supported package manager is detected, it prints official download links
for the missing tool (`jq`, `git`, `curl`/`wget`, `unzip`, or `fontconfig`) and
stops before changing your Claude config.

The Nerd Font is **optional** — without one the status line uses a readable
ASCII/Unicode fallback everywhere (see [Nerd Font icons](#nerd-font-icons)).

## Preview it without a session

```bash
./demo.sh        # render in your terminal with sample data (Ctrl-C to quit)
```

The demo ticks at ~2.5 fps — roughly the real busy-state render rate — and
alternates ~6s busy (spinner runs, gauge sweeps) with ~6s idle (payload frozen,
everything holds perfectly still), so you can see both regimes.

## Configuration

Set these as env vars (e.g. inside the `command` in `settings.json`, or your
shell profile):

| Var                | Default | Meaning                                                  |
| ------------------ | ------- | -------------------------------------------------------- |
| `CCSL_ROWS`        | `2`     | `2` = identity row + context row; `1` = context row only  |
| `CCSL_QUIET`       | `1`     | hide non-actionable segments (`0` = show everything)      |
| `CCSL_RUNWAY`      | `1`     | burn-rate projections (`⚠ dry`, `compact ~`)              |
| `CCSL_ANIM`        | `1`     | master switch for all animation                           |
| `CCSL_MOTION`      | `busy`  | `busy` = sweep the gauge while working; `off` = never     |
| `CCSL_SPINNER`     | `1`     | spinner while API busy                                    |
| `CCSL_SHINE`       | `1`     | static same-hue gloss at the fill edge (never moves)      |
| `CCSL_WARN_ANIM`   | `1`     | blink high context/rate-limit + "changes requested"       |
| `CCSL_DECOUPLE`    | `1`     | skip jq/git on unchanged ticks (cache parsed data)        |
| `CCSL_DATA_TTL`    | `5`     | max seconds to trust the data snapshot                    |
| `CCSL_GIT_TTL`     | `2`     | seconds to cache git state between ticks                  |
| `CCSL_BAR_MAX`     | `44`    | max context-gauge width, chars                            |
| `CCSL_COMPACT_PCT` | `92`    | window % where the harness auto-compacts (marker position)|
| `CCSL_COLOR`       | `1`     | colored output (`0` = plain)                              |
| `CCSL_COLOR256`    | `auto`  | 256-color ramp when supported                             |
| `CCSL_ASCII`       | `0`     | `1` = ASCII gauge (`#`/`-`) + `\|/-\` spinner              |
| `CCSL_NERD`        | `auto`  | `auto` detect a Nerd Font, `1` force icons, `0` off       |
| `CCSL_MARGIN`      | `6`     | columns reserved at the right edge (anti-clip)            |

> Removed in this version: `CCSL_REFRESH` (motion is now driven by an invocation
> counter, so there's no frame rate to keep in sync), `CCSL_MARQUEE` and
> `CCSL_SEP_ANIM` (both added motion without adding information).

### Nerd Font icons

With a [Nerd Font](https://nerdfonts.com) installed and selected in your
terminal, the status line uses glyphs instead of text labels. `CCSL_NERD=auto`
(the default) uses icons only when a Nerd Font is detected, so it's safe on
machines without one — it falls back to `◆`, `⇡`/`⇣`, `PR#673`, `↻`, `⚠`.

```bash
./install.sh --nerd      # install the font + force icons on
./install.sh --no-nerd   # skip the font, use the ASCII/Unicode fallback
./install.sh             # detects a font; if none, offers to install it
```

How the font gets installed per platform:

- **macOS** — `brew install --cask font-jetbrains-mono-nerd-font` (falls back to
  a direct download into `~/Library/Fonts` if Homebrew is absent).
- **Linux** — the distro package where one exists (`ttf-jetbrains-mono-nerd` on
  Arch), otherwise a direct download into `~/.local/share/fonts` + `fc-cache`.
  Package-manager installs use `sudo` when needed.
- **Windows (Git Bash)** — downloads the `.ttf`s into your per-user font dir;
  Windows may still ask you to confirm the install (right-click → Install). Under
  WSL, the Linux path is used.

Requires `unzip` and `curl`/`wget` for the direct-download path; if either is
missing the installer prints manual instructions instead.

After installing, **set your terminal profile's font** to the Nerd Font (e.g.
"JetBrainsMono Nerd Font") — the shell can't switch the terminal font for you.

> **The font must be selected in whatever actually draws the terminal.**
> Installing the font is not enough; each terminal app, multiplexer, or wrapper
> has its own font setting that has to point at the Nerd Font:
>
> - **Warp** — Settings (`Cmd+,`) → Appearance → Text → *Terminal font*
> - **iTerm2** — Settings → Profiles → Text → *Font*
> - **Apple Terminal** — Settings → Profiles → Text → *Font*
> - **VS Code / Cursor** — `"terminal.integrated.fontFamily": "JetBrainsMono Nerd Font"`
> - **Windows Terminal** — Settings → your profile → Appearance → *Font face* (this also covers WSL)
> - **GNOME Terminal / Konsole** — Preferences → Profile → *Custom font*
> - **Alacritty / Kitty / WezTerm** — set the font family in their config file
> - **tmux / screen** — these don't draw glyphs themselves, but they can mangle
>   wide/PUA glyphs; make sure the *outer* terminal uses the Nerd Font
>
> If icons show as blank cells or boxes, the drawing layer isn't using the Nerd
> Font yet. Prefer the plain `JetBrainsMono Nerd Font` variant over the
> `…Mono`/`…Propo` variants — the `Mono` variant squeezes icons into a narrow
> cell and can clip them.

## Rendering is cheap: data is cached between ticks

Claude Code sends the JSON payload on stdin and only changes it when real data
changes. So the script splits into two phases:

1. **Data** — hash stdin; if it matches the last snapshot (and the snapshot is
   younger than `CCSL_DATA_TTL`), reuse the cached parsed values and **skip `jq`
   and `git` entirely.** Otherwise parse with `jq`, gather git state, update the
   burn-rate trend, and write a fresh snapshot.
2. **Presentation** — always runs, but it's pure string arithmetic off the
   invocation counter. No subprocesses.

Every state flip (spinner, warn-blink, gauge sweep) is **width-invariant** — it
only changes colors or swaps equal-width glyphs — so the right-aligned rail
never jitters between frames.

## Performance

The script does no network I/O and **costs zero API tokens** — Claude Code runs
it locally.

Measured on an Apple Silicon Mac, 30 consecutive invocations, wall clock ÷ 30:

| | per tick |
| --- | --- |
| `bash` startup floor (`bash -c true`) | 5.7 ms |
| Unchanged tick — no `jq`, no `git` | **~22 ms** |
| Previous version, same conditions | 38 ms |

Roughly 40% of that remainder is bash startup. The snapshot and git caches carry
their own write timestamps inside the file, so a freshness check is one builtin
`read` rather than a `stat` fork; the session id comes from a bash regex rather
than `grep | head | cut`; and the layout engine sets globals instead of
capturing `$(...)` subshells.

At `refreshInterval: 1` that's about 2% of one core when idle, and 0% while
you're actively typing (the timer is paused then). Raise `CCSL_DATA_TTL` /
`CCSL_GIT_TTL` or the interval to make it lighter still; set `CCSL_DECOUPLE=0`
to always re-parse (debugging).

## Plain ASCII / no-color mode

For a minimal, dependency-light render (ASCII bar characters, no color), wire the
`statusLine` command with those env vars set:

```json
{
  "statusLine": {
    "type": "command",
    "command": "CCSL_ASCII=1 CCSL_COLOR=0 ~/.claude/statusline.sh",
    "refreshInterval": 10
  }
}
```

## How it works

Claude Code pipes [session JSON](https://code.claude.com/docs/en/statusline#available-data)
to the script on stdin; the script prints two lines to stdout. It reads
`COLUMNS` (set by the harness) for terminal width, uses `jq` to parse the
payload, and caches a handful of small files under `$TMPDIR` per session
(parsed snapshot, git state, invocation counter, burn-rate trend). No network,
no token cost.

## License

MIT — see [LICENSE](LICENSE).
