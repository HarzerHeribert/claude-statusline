# claude-statusline

A verbose, full-width, **no-emoji** status line for
[Claude Code](https://code.claude.com/docs/en/statusline).

Two rows, left/right justified to fill the terminal (Nerd Font icons; the
`auto mode` footer badge is Claude Code's, not ours):

![claude-statusline screenshot](statusline.png)

- **Row 1** — model + context-window size (`1M`/`200k`), reasoning effort, thinking
  state, output style, session name; then repo, git branch, working-tree state
  (`+staged ~modified ?untracked` or `clean`), ahead/behind (`^ v`), and open-PR
  number with review state (`OK` / `CHANGES` / `DRAFT` / `REVIEW`). Rate limits on
  the right.
- **Row 2** — a context-usage bar (color-coded, scales to terminal width) with % and
  token count; cost estimate, lines changed, and durations on the right.

## Honest about cost

`cost.total_cost_usd` is a **client-side estimate**, not your bill — shown as `~$…`.
The real budget signal on a Pro/Max subscription is `rate_limits` (5h + 7d windows
with reset countdowns), which the API only sends to subscribers. When absent (API
auth), the status line says so rather than faking a number.

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
`settings.json`, and wires up the `statusLine` block. It appears on your next
interaction with Claude Code.

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

The demo feeds the script sample session data so you can see both rows render
without starting a Claude Code session.

## Configuration

Set these as env vars (e.g. inside the `command` in `settings.json`, or your shell
profile):

| Var             | Default | Meaning                                             |
| --------------- | ------- | --------------------------------------------------- |
| `CCSL_ANIM`     | `1`     | master switch for the state-flip animations         |
| `CCSL_SPINNER`  | `1`     | spinner while API is busy                            |
| `CCSL_SHINE`    | `1`     | static same-hue gloss at the fill edge (never moves) |
| `CCSL_WARN_ANIM`| `1`     | blink high context/rate-limit + "changes requested"  |
| `CCSL_SEP_ANIM` | `0`     | animate the `::` / `\|` separators (subtle)           |
| `CCSL_MARQUEE`  | `0`     | cycle the right rail of row 2 (off = show all)       |
| `CCSL_DECOUPLE` | `1`     | skip jq/git on unchanged ticks (cache parsed data)   |
| `CCSL_DATA_TTL` | `5`     | max seconds to trust the data snapshot               |
| `CCSL_GIT_TTL`  | `2`     | seconds to cache git state between animation ticks    |
| `CCSL_REFRESH`  | `10`    | must match `refreshInterval` for frame timing        |
| `CCSL_BAR_MAX`  | `60`    | max context-bar width, chars                          |
| `CCSL_COLOR`    | `1`     | colored output (`0` = plain)                          |
| `CCSL_COLOR256` | `auto`  | 256-color ramp for the shine when supported          |
| `CCSL_ASCII`    | `0`     | `1` = ASCII bar (`#`/`-`) + `\|/-\` spinner           |
| `CCSL_NERD`     | `auto`  | `auto` detect a Nerd Font, `1` force icons, `0` off   |
| `CCSL_MARGIN`   | `6`     | columns reserved at the right edge (anti-clip)        |

### Nerd Font icons

With a [Nerd Font](https://nerdfonts.com) installed and selected in your terminal,
the status line shows glyphs instead of text labels:

```
 Opus 4.8:1M   high    ::  bitesize  main   1  1  ::   673 OK
 [███████░░░] 13% 128k/1M                        ~$16.52  |   +830/-107  |   17m
```

`CCSL_NERD=auto` (default) uses icons only when a Nerd Font is detected, so it's
safe on machines without one — it falls back to `eff:high`, `git:main`, `↑1 ↓1`,
`PR#673`, etc. The installer can install **JetBrainsMono Nerd Font** for you:

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

> **The font must be selected in whatever actually draws the terminal.** Installing
> the font is not enough; each terminal app, multiplexer, or wrapper has its own font
> setting that has to point at the Nerd Font:
>
> - **Warp** — Settings (`Cmd+,`) → Appearance → Text → *Terminal font*
> - **iTerm2** — Settings → Profiles → Text → *Font*
> - **Apple Terminal** — Settings → Profiles → Text → *Font*
> - **VS Code / Cursor integrated terminal** — set `"terminal.integrated.fontFamily": "JetBrainsMono Nerd Font"`
> - **Windows Terminal** — Settings → your profile → Appearance → *Font face* (this also covers WSL)
> - **GNOME Terminal / Konsole** — Preferences → Profile → *Custom font*
> - **Alacritty / Kitty / WezTerm** — set the font family in their config file
> - **tmux / screen** — these don't draw glyphs themselves, but they can mangle
>   wide/PUA glyphs; make sure the *outer* terminal uses the Nerd Font
>
> If icons show as blank cells or boxes, the drawing layer isn't using the Nerd Font
> yet. Prefer the plain `JetBrainsMono Nerd Font` variant over the `…Mono`/`…Propo`
> variants — the `Mono` variant squeezes icons into a narrow cell and can clip them.

## Rendering is cheap: data is cached between ticks

Claude Code sends the JSON payload on stdin and only changes it when real data
changes. So the script hashes stdin; if it matches the last snapshot (and the
snapshot is younger than `CCSL_DATA_TTL`), it reuses the cached parsed values and
**skips `jq` and `git` entirely.** Otherwise it parses with `jq`, gathers git
state, and writes a fresh snapshot.

The result: a tick where nothing changed is just a `cksum` + a `source` + string
math — no subprocess parsing at all.

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
to the script on stdin; the script prints two lines to stdout. It reads `COLUMNS`
(set by the harness) for terminal width, uses `jq` to parse the payload, and caches
parsed data per session under `$TMPDIR` between ticks. No network, no token cost.

## License

MIT — see [LICENSE](LICENSE).
