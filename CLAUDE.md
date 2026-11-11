# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native macOS (AppKit) port of [rofi](https://github.com/davatorium/rofi), installed as an executable named `rofi` so existing `rofi -dmenu` scripts work unchanged. Behavior targets upstream rofi: source comments cite upstream C files and lines (e.g. `source/modes/script.c:161`). When implementing a feature, match upstream semantics first.

## Commands

```sh
make build   # swift build
make lint    # swift format lint --strict (config: .swift-format, 4 spaces, 120 cols)
make test    # swift test + Python CLI contract tests
make check   # lint + test
```

- `make test` passes `-F` flags for Command Line Tools' Swift Testing framework. Plain `swift test` only works with full Xcode selected.
- Single test: `swift test $(TEST_FLAGS) --filter RofiCoreTests/<SuiteOrTest>` — copy `TEST_FLAGS` from the `Makefile`.
- `Tests/CLITests/test_cli.py` runs the real binary at `.build/debug/rofi`, so run `swift build` first. It uses `executable=` with a custom argv[0] to test the `dmenu` basename switch.
- CI (`macos-15`, Xcode 16.4) runs `make lint` and `make test`. Swift tools 6.0, macOS 13+.

## Architecture

Three targets, with a strict dependency direction `rofi` → `RofiAppKit` → `RofiCore`:

- **RofiCore** — all logic, no AppKit: argument parsing, matching/scoring, dmenu pipeline, modes, Rasi config/theme parsing. Everything testable lives here.
- **RofiAppKit** — panels (`DmenuPanel`, `ModePanel`), `PanelStyle`, the native app catalog. It only renders what Core resolves.
- **rofi** (`main.swift`) — thin glue: raw argv bytes → `Arguments` → pick dmenu vs `-show` → run panel → exit code. Argv is read as raw bytes (not `String`) to preserve rofi's byte-level behavior.

Key seams in Core:

- **`Mode` protocol** (`Mode.swift`): `-show` modes (`RunMode`, `SshMode`, `DrunMode`, `CombiMode`, `KeysMode`, `FileBrowserMode`, `ScriptMode`) are class-bound because `result` mutates what `rows` returns next. `ModeSwitcher` handles next/previous/switch between modes; modes return `ModeResult` and never switch themselves. `ShowOptions.swift` maps `-show <name>` to a concrete mode; the default `-modes` is `drun,run,ssh` (upstream without `window`, which is decided in #75 and not built yet). `CombiMode` routes every action to the submode owning the row.
- **dmenu**: `DmenuPipeline` / `DmenuSession` implement the stdin → filter → select → output flow, including `-dump`, `-format`, and meta/icon rows.
- **Config/theming**: `RasiParser` → `RasiModel` → `RasiResolver` → `PanelStyle`. Only a *subset* of Rasi is supported, with unsupported declarations warning instead of failing. The boundary is decided in ADR 0001.
- **Command launching** (`run`, `ssh`): `CommandTemplate` (rofi placeholder/optional-group/argv-split engine), `TerminalLaunch` (injected launcher; Terminal.app has no `-e`, so it uses a `.command` file adapter), `ProcessCommandLauncher`. Launchers are injected so tests assert the final argv and never spawn processes.

## Project conventions

- **ADRs**: `docs/adr/` holds locked design decisions. Read the relevant one before changing a design assumption.
- **Feature tracking**: `odd/tasks/<feature>.md` holds objective, constraints, and a task checklist per feature. Check there for decided constraints before starting work on a feature (e.g. `native-run-ssh-combi-keys.md`).
- **Tests**: Swift Testing in `Tests/RofiCoreTests` and `Tests/RofiAppKitTests`; fixtures in `Tests/RofiCoreTests/Fixtures`. Core logic gets unit tests; side effects (process spawn, filesystem) go behind an injected seam.
Only test the core functinality and test hard, the less but robust test the better. 

- **Workflow**: one PR per mode/feature slice, around 400 authored lines as a planning heuristic. Conventional Commits; no AI attribution or `Co-Authored-By` trailers in commits or PRs.
- Deliberate simplifications are marked with `ponytail:` comments (e.g. in `Mode.swift`); respect them rather than "fixing" them unasked.

## Engineering practices
- We're a startup. You're probably used to writing enterprise code - code that tries to handle every possible edge case and has fallbacks for everything. That's not how we do things around here: our number one rule is to keep things simple. We handle ONLY the most important cases.

- We try to only add new functionality that is small (that is, simple and few lines of code) or absolutely necessary. If a change is not small or absolutely necessary, don't make it.

- Only add necessary testing. When writitng new test, see current test first and improve those to meet new needs rather than inctroducing a new test file. Lets keep test lean and direct.




