<p align="center"><img src="docs/icon.png" width="128" alt="Claude RC icon"></p>

# Claude RC

A macOS menu bar app for `claude remote-control`. It starts and stops the
server from next to the clock, shows its status, and can bring itself back
every time the Mac starts.

**Website:** https://erenbekman.github.io/claude-rc-menubar/

> **The original project belongs to [ocracy](https://github.com/ocracy).**
> Process management, orphan protection, log trimming, launch at login and
> session naming are ocracy's work. Added in this repo by
> [erenbekman](https://github.com/erenbekman): the SwiftUI panel and UI
> design, the custom icon, QR code, notifications, universal builds and the
> one-line installer. Details: [Credits](#credits).

![The Claude RC panel in light and dark mode, in all four states](docs/panel.png)

## Install

Requirements: macOS 13+ (Apple silicon or Intel) and the
[`claude` CLI](https://docs.anthropic.com/en/docs/claude-code), installed and
signed in.

### One command

```bash
curl -fsSL https://raw.githubusercontent.com/erenbekman/claude-rc-menubar/main/install.sh | bash
```

Downloads the latest release, installs it into `/Applications` (quitting and
replacing a running copy) and opens it. Run the same command again to update.
To install somewhere else:
`curl -fsSL … | INSTALL_DIR=~/Applications bash`.

### Manual download

Download `Claude-RC.zip` from
[Releases](https://github.com/erenbekman/claude-rc-menubar/releases/latest),
unzip it and drag `Claude RC.app` into Applications.

The app is not notarized by Apple, so macOS blocks a copy downloaded with a
browser on first launch. Choose **System Settings › Privacy & Security ›
Open Anyway**, or remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Claude RC.app"
```

### Build from source

```bash
./build.sh --install     # build, copy to /Applications, open
./build.sh               # only build build/Claude RC.app and build/Claude-RC.zip
```

Also needs the Xcode Command Line Tools (`swiftc`). The output is universal
(arm64 + x86_64).

### First launch

- The icon appears in the menu bar; click it and pick a **Working folder**.
- If you have never run `claude` in that folder, run it once in a terminal
  and accept the workspace trust prompt.
- macOS asks for notification permission; allow it to get drop and error
  alerts.

## Menu bar

| Icon | Meaning |
|---|---|
| Open ring with `›` (dim) | Off |
| Ring with signal arc (dim) + `…` | Connecting |
| Ring with signal arc + number | Connected — the number is the count of active sessions |
| Warning triangle | Error (the panel shows why) |

Click the icon to open the panel; click outside it or press `Esc` to close.

## Panel

- **Status pill** — Off / Connecting (pulsing dot) / Connected / Error.
- **Status card** — while connected: the session name reported by the server
  (copy), uptime, an `N / 32` capacity bar and the
  `claude.ai/code?environment=…` link (copy / open in browser). When off,
  connecting or failed: a short note on what to do next.
- **QR code** — the QR button in the link row shows the environment link as a
  QR code; scan it with your phone's camera to connect. The choice is
  remembered.
- **Warning strip** — warnings such as a retry in progress or another server
  in the same folder.
- **Start / Stop** (⌘S), **Restart** (⌘R)
- **Working folder** — the 8 most recent folders + `Choose Folder…`. If the
  folder changes while RC is running, the process restarts automatically.
- **Session name** — the fixed name shown on your phone and claude.ai; edited
  in place, saved with Enter or **Save**, with a live preview of the slug that
  will be saved. Default: a slug of the computer name. Leave it empty and
  `--name` is not passed at all, so claude picks a random name just like in
  the terminal.
- **Settings** (collapsible, open/closed state is remembered):
  - **Launch at login** — writes `~/Library/LaunchAgents/com.safepluspay.claude-rc.plist`
    and registers it with `launchctl bootstrap gui/$UID`. The app starts with
    every login (and starts RC if that is enabled too).
  - **Start RC on launch** — 3 seconds after launch, so the network is ready.
  - **Prevent idle sleep** — an IOKit power assertion, held only while RC runs.
  - **Retry after crashes** — up to 5 attempts with growing delays after an
    unexpected exit.
  - **Notifications** — macOS notifications when the connection drops,
    reconnects, stops for good (with sound), and when a new session attaches
    from your phone. Nothing is sent while the panel is open; clicking a
    notification opens the panel. If permission is off in System Settings,
    the row says so.
- **Log** (⌘L) — `~/Library/Logs/ClaudeRC.log`, **About**, **Quit** (⌘Q)

The panel is SwiftUI inside an `NSPopover` and follows the light/dark system
appearance.

## Design

- **Icon** — a thin, minimal mark: a ring open on the right (Claude's "C"),
  a terminal prompt `›` inside, and a single orange signal arc leaving the
  opening. The app icon is drawn as vectors by `Sources/makeicon.swift`
  (light background, navy lines, orange signal). The menu bar uses a 1.2 pt
  monochrome version of the same mark; the signal arc is hidden while off.
- **Colors** — Color Hunt palette
  [`#000000 #233D4D #FE7F2D #EAECF0`](https://colorhunt.co/palette/000000233d4dfe7f2deaecf0).
  The accent is navy `#233D4D` in light mode and orange `#FE7F2D` in dark
  mode; signal elements (capacity bar, QR button) are orange in both. Status
  colors are derived from the palette and tuned for contrast (text ≥ 4.5:1).
- **Metrics** — 4-8-12-16 pt spacing, 8/12 pt corner radii, 320 pt panel.

## How it works

The process is started like this:

```
/bin/zsh -lc "cd <folder> && exec <claude> remote-control --name <name>"
```

- `-l` (login shell) reads `.zprofile`/`.zshrc`, so `PATH` (Homebrew, nvm) is
  right even in launchd's bare environment.
- `exec` replaces zsh with claude; no wrapper process is left and
  `terminate()` goes straight to claude.
- No TTY is needed; output is read from a pipe, ANSI codes are stripped, and
  the `Connected` / `Capacity: N/32` lines are reflected in the panel.

## Why the session name must be a slug

The first version passed `--name "Jane’s Mac mini"` (spaces, capitals, a
curly apostrophe U+2019). The names claude generates itself are strict slugs
such as `janes-mac-mini-2-local-virtual-aho` — only `[a-z0-9-]`. That name did
not match the format expected in the list on the phone. Every name you enter
is now converted with `slugify()`; the apostrophe is **removed**, not turned
into a separator (`Jane’s` → `janes`, not `jane-s`).

The TTY has nothing to do with it — measured: running with and without a pty
gives exactly the same result. The only difference was `--name`.

## Orphan protection

If the app is killed (pkill, a crash, logging out), macOS does not run
`applicationWillTerminate`; the `claude rc` it started is left without an
owner, lives forever and leaves a ghost environment on the phone. Two
safeguards:

1. **Signal handling** — SIGTERM/SIGINT/SIGHUP are ignored and handled with a
   `DispatchSourceSignal`; the child is stopped before the app exits.
2. **PID file** — `~/Library/Application Support/ClaudeRC/child.pid`. On
   launch, a leftover PID is stopped if it really is a `claude remote-control`
   process (checked with `ps` to guard against PID reuse).

Starting from the panel while another server runs in the same folder shows a
warning with a "Stop Others and Start" option. A server that shuts down
cleanly keeps its environment and reuses **the same environment** when it
restarts; a server that dies uncleanly creates a new one every time — that is
what piles up sessions.

## Why the log stays small

`claude rc` is a TUI: it clears the screen and redraws the same 5–6 lines
**every second**. Dumped raw, the log would grow ~29 MB a day, ~880 MB a
month. Two layers prevent that:

1. **Deduplication** — a line seen in the last 16 lines is never written to
   disk. Nothing is written while the state does not change (measured: 0 bytes
   in 30 s).
2. **Trim on write** — once the file passes 512 KB, the last 64 KB are kept
   and the rest is dropped. The check runs on every write, not at launch, so
   the file cannot exceed the cap even if the app stays open for months.

Every written line gets a `yyyy-MM-dd HH:mm:ss` timestamp.

## Notes

- If you move the app, the login item registration is fixed on the next
  launch.
- Before the first run in a new folder, run `claude` there once and accept the
  workspace trust prompt.
- Quitting the app also stops the RC process.
- If you want your phone to keep working while the computer is fully off,
  this is not enough; that needs a cloud session (`claude --cloud`).

## Credits

- **[ocracy](https://github.com/ocracy)** — original author of Claude RC:
  process management for `claude remote-control`, orphan protection (signal
  handling + PID file), the duplicate-server warning, log deduplication and
  trimming, launch at login via LaunchAgent, session-name slugs and the first
  menu bar interface.
- **[erenbekman](https://github.com/erenbekman)** — v1.1 and later: the
  SwiftUI panel and UI design, the Color Hunt color system, the custom app and
  menu bar icon, QR code, macOS notifications, universal (arm64 + x86_64)
  builds, `install.sh`, GitHub Releases, the English interface and the
  website.

## Files

```
Sources/ClaudeRC.swift   the app (process management + SwiftUI panel)
Sources/makeicon.swift   app icon generator
build.sh                 build (universal) + zip + local install
install.sh               one-line installer for the latest release
docs/                    website (GitHub Pages) and README images
```
