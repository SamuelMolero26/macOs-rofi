# ADR 0003: Keep rofi resident for hotkey launches

## Status

Proposed — 2026-11-17. Not decided; recorded so the measurements and trade-offs
are not lost.

## Context

rofi runs as one process per invocation, like upstream: a hotkey (skhd) spawns
`rofi -show drun`, which loads config, discovers modes, starts AppKit, builds
the panel and shows it. Spotlight is resident and only reveals an existing
window, so it appears in roughly 30–50ms.

Measured on 2026-11-17 for `-show drun -show-icons` (release build, external
watcher polling `CGWindowListCopyWindowInfo` for the panel being on screen):

| Stage                                   | Cost       |
|-----------------------------------------|------------|
| spawn and dyld to `main`                | ~18ms      |
| config and options                      | ~19ms      |
| discovery: apps, `$PATH`, ssh           | ~50–70ms   |
| `NSApplication.shared`                  | ~35ms      |
| panel window and layout                 | ~50ms      |
| `run` to `applicationDidFinishLaunching` | ~30ms      |
| present                                 | ~8ms       |

Discovery fixes (`readdir` scans, parallel bundle reads) and overlapping
discovery with the window server connection bring the panel on screen in about
180ms, down from ~430ms. About 120ms of what remains is AppKit start-up, which
a new process pays every time. Tried and rejected: presenting before
`application.run()` (no gain) and starting with the `.accessory` policy (~15ms,
within noise, and `.regular` exists for activation reliability).

## Options

1. **Per-process (current).** Upstream's model; ~180ms floor.
2. **Hybrid.** A resident process (LaunchAgent) serves the hotkey `-show`
   launcher only. `rofi -dmenu` from scripts stays per-process, exactly as
   upstream. Expected ~30–60ms where latency is felt.
3. **Full daemon.** Every invocation is a thin client forwarding to a resident
   process.

Containers were considered and rejected: containers on macOS run Linux in a
VM, which has no AppKit, window server, NSWorkspace or Accessibility API, and
container start-up adds latency instead of removing it.

## Consequences of a resident process

- **Activation (highest risk).** A freshly spawned app may activate itself; a
  resident app asked to activate over IPC did not receive the input event, and
  macOS 14 made activation cooperative (`activate(ignoringOtherApps:)` is
  deprecated). The panel could show while keystrokes go to the previous app.
  Launchers that work register the global hotkey themselves and/or use a
  `.nonactivatingPanel` that becomes key without activating the app.
- **CLI contract (full daemon only).** Raw argv bytes, streamed stdin (async
  dmenu reader, FIFOs, `-input`), stdout, exit codes (`kb-custom-N` returns
  10–28), cwd, environment and Ctrl-C must cross a socket.
- **Freshness.** Config, theme, apps, `$PATH`, `known_hosts` and history are
  read fresh by every process today. A resident process must watch them
  (FSEvents) or re-read per show. A LaunchAgent's `$PATH` is launchd's, not the
  user's shell's, so `run` would list the wrong commands unless the client
  sends its environment.
- **Children.** Apps and commands launched from `drun`/`run` inherit the
  resident process's environment and working directory.
- **Lifecycle.** LaunchAgent plist, start at login, `KeepAlive` restarts,
  client/daemon version skew after `make build`, stale sockets, and a fallback
  to the in-process path, which means two launch paths to maintain.
- **Permissions.** The Accessibility grant (`window` mode) moves to the
  resident binary; an unsigned rebuild changes its code hash and can drop the
  grant. A signed `.app` bundle gives a stable identity.
- **Resources.** ~30–60MB resident, idle CPU ~0. Not a concern.

## Decision

None yet. If the per-process floor still feels slow in daily use, prefer the
hybrid (option 2), and start with a spike on activation: show a resident
`.nonactivatingPanel` from an skhd-triggered IPC message and confirm it takes
keystrokes on macOS 15. If that spike fails, the resident model fails with it.
