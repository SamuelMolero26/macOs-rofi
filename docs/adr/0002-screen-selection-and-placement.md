# ADR 0002: Map monitor selection and panel placement to NSScreen

## Status

Accepted — 2026-11-16

## Context

Issue #74 adds navigation keys, mouse handling and placement options. Its
placement scope (`-monitor`, `-xoffset`, `-yoffset`) depends on issue #75, which
records how X11/Wayland-only features map to macOS. ADR 0001 section 6 listed
monitor selectors as excluded X11/Wayland-only semantics. This ADR replaces that
exclusion with a mapping.

Upstream resolves one monitor work area and places the window inside it:

- `-monitor` accepts a monitor name, `primary`, `wid:<id>`, a nonnegative index
  in detection order, or a negative selector (`doc/rofi.1.markdown:551-569`,
  `source/xcb/display.c:1003-1072`). The default is `-5`
  (`config/config.c:149`).
- Negative selectors are resolved in `source/xcb/display.c:922-995`: `-1` the
  current desktop's viewport, `-2` the focused window's frame, `-3` the pointer
  position, `-4` the monitor holding the focused window's top-left corner, `-5`
  the monitor holding the pointer. Each unresolvable selector falls back to
  `-5`.
- `-3` forces location 1, north west (`source/helper.c:769-772`).
- The location picks a point on the work area, the anchor shifts the window
  around it, then `x-offset` and `y-offset` are added, with positive Y going
  down (`source/xcb/view.c:279-364`).
- The result is cached for the process (`mon_cache`, `mon_set`).
- With `click-to-exit` (default true, `config/config.c:156`), a click outside
  the window cancels (`source/xcb/view.c:864-871`). This works because X11 rofi
  grabs the pointer and keyboard.

The current port sizes the panel from `NSScreen.main`
(`Sources/RofiAppKit/DmenuPanel.swift:136`) and places it on whatever screen
`NSPanel.center()` picks (`DmenuPanel.swift:162-164`). Neither matches the
upstream default of the screen under the mouse.

### Measurements

A spike on macOS 15 (one built-in display) measured these inputs:

| Input | API | Cost |
| --- | --- | --- |
| Screens | `NSScreen.screens` | About 35 ms on the first call, the one-time WindowServer connection. The panel pays it anyway when `NSApplication.shared` starts. 0.001 ms afterwards. |
| Mouse point | `NSEvent.mouseLocation` | 0.07 ms |
| Frontmost app | `NSWorkspace.shared.frontmostApplication` | 0.02-0.07 ms |
| Window list | `CGWindowListCopyWindowInfo` (on-screen, no desktop elements) | 3-12 ms on the first call, 0.5-2 ms afterwards |

The frontmost app is the launching app (the terminal or hotkey daemon) until
rofi activates itself. Right after `NSApplication.activate`, it is rofi.

The same spike ran with no TCC grants, as a launchd job so that TCC attributed
it to the binary itself (`CGPreflightScreenCaptureAccess` false,
`AXIsProcessTrusted` false). Every other app's layer-0 window still reported
`kCGWindowBounds`, `kCGWindowOwnerPID` and `kCGWindowLayer`. Only
`kCGWindowName` was missing. CGWindowList bounds use a top-left origin. In
AppKit coordinates the origin's Y is `primary.frame.maxY - (y + height)`, which
was verified against a panel the spike placed itself.

## Decision

### 1. Resolve one work area with these selector mappings

| Selector | Upstream | macOS work area |
| --- | --- | --- |
| `-5` (default) | Monitor holding the pointer | Visible frame of the screen whose frame contains `NSEvent.mouseLocation` |
| `-4` | Monitor holding the focused window's top-left corner | Visible frame of the screen containing the frontmost app's topmost layer-0 window's top-left corner |
| `-3` | Pointer position, location forced to north west | Screen as `-5`. The panel's top-left corner sits at the pointer |
| `-2` | Focused window's frame | Frame of the frontmost app's topmost layer-0 window |
| `-1` | Current desktop's viewport | Same as `-4`. macOS has no public API for the active Space's display, and the focused window's screen is the closest public equivalent |
| `primary` | Primary output | `NSScreen.screens[0]`, the screen with the menu bar |
| `N` (0 or more) | Nth monitor in detection order | `NSScreen.screens[N]` |
| Name | xrandr output name | Exact match on `NSScreen.localizedName`, for example `Built-in Retina Display` |
| `wid:<id>` | Frame of an X11 window id | Dropped: warns, then behaves as `-5` |

Fallbacks follow upstream:

- `-1`, `-2` and `-4` fall back to `-5` when there is no frontmost window, for
  example when the desktop is focused.
- An unknown name or an out-of-range index warns through the existing
  `rofi: warning:` diagnostics and uses `primary`. Upstream falls back to the
  monitor at the origin (`source/xcb/display.c:1067-1068`).

`-monitor` and its alias `-m` come from the command line only. `-m` wins when
both are given, because it follows `-monitor` in upstream's option table. The
port already reads other nonvisual options, such as `-no-cycle`, only from the
command line. config.rasi support for them is a separate, shared gap.

### 2. Place the panel within the work area as upstream does

- The work area for `-1`, `-3`, `-4`, `-5`, `primary`, `N` and names is the
  selected screen's `visibleFrame`, which leaves out the menu bar and Dock. For
  `-2` it is the window frame.
- ADR 0001's width and padding percentages resolve against this work area.
- `location` picks the point on the work area and the panel anchors to it. No
  location means the exact center of the work area, as upstream does, instead
  of `NSWindow.center()`, which picks its own screen and sits above center. A
  separate `anchor` property is not supported: anchor equals location,
  upstream's default.
- The offsets are then added. AppKit's Y axis points up, so a positive offset
  moves the panel right and **down**: `origin.x += x`, `origin.y -= y`.
- `-xoffset` and `-yoffset` are integer points, parsed like upstream's `strtol`.
  Upstream marks both deprecated in favor of the `window` theme properties
  `x-offset` and `y-offset`. Those theme properties are not supported and warn
  as unsupported properties, like any other property outside ADR 0001.
- The existing clamp that keeps a screen-tall panel below the menu bar stays.
  Offsets are otherwise not clamped, matching upstream.

### 3. Resolve once, before rofi activates, and query only what the selector needs

- The frontmost app's pid is captured at launch, before
  `PanelApplicationDelegate` activates rofi. Capturing it later returns rofi
  itself.
- The work area is resolved once per process and reused across mode switches
  and row reloads, like upstream's `mon_cache`.
- Each selector reads only its own inputs:
  - `-5`, `-3`: screens and mouse point.
  - `primary`, `N`, name: screens only.
  - `-1`, `-4`: screens and the window list, except that with **one screen**
    they resolve to that screen without reading the window list.
  - `-2`: screens and the window list, on any number of screens.
- The default `-5` adds no measurable launch cost: about 0.07 ms on top of the
  screen list the panel already loads. Only `-2`, plus `-1` and `-4` with more
  than one screen, pay the 0.5-12 ms window-list read.

### 4. Placement requires no permission

- Selectors read only window bounds, owner pid and layer from CGWindowList.
  They never read `kCGWindowName`.
- Placement never calls `CGRequestScreenCaptureAccess`,
  `AXIsProcessTrustedWithOptions` or any AX API.
- No `-monitor` value, offset or location can trigger a TCC prompt or behave
  differently depending on grants.
- Window titles, raising and closing windows belong to the `window` mode
  decided in issue #75. That mode needs Screen Recording and Accessibility and
  is out of scope here.

### 5. Map click-to-exit to a click that reaches another app

macOS gives an unprivileged app no pointer grab. A click outside the panel is
delivered to another app.

- With `click-to-exit` true (the default), a global mouse-down monitor
  (`NSEvent.addGlobalMonitorForEvents` for left, right and other buttons)
  cancels the panel, exits 1 and prints nothing, like upstream `MENU_CANCEL`.
  Global monitors only see events delivered to other apps, so clicks inside the
  panel are unaffected. Mouse events need no permission; only key events
  require Accessibility.
- Losing key status does **not** cancel. During development, other apps
  activated themselves 0.4-2.4 s after launch with no user input. A resign-key
  rule cancelled the panel in those runs. With the click rule, the panel stays
  visible and gets the keyboard back when clicked.
- With `click-to-exit` false, no monitor is installed.
- `-click-to-exit` and `-no-click-to-exit` come from the command line only,
  like `-monitor`.

### 6. Keep the decision testable without multiple displays

The placement decision lives in RofiCore as a pure function. Its inputs are the
selector, screen frames and visible frames in order with their names, the mouse
point, the captured front window rect, location, offsets and panel size. Its
output is the panel origin. RofiAppKit only gathers the inputs and applies the
origin.

Tests cover each selector in the section 1 table, including:

- synthetic two- and three-screen layouts with negative origins (a screen left
  of or below the primary);
- each fallback;
- the single-screen shortcut, asserting that `-1` and `-4` do not read the
  window list.

## Consequences

### Positive

- The default matches upstream: rofi opens on the screen with the mouse, which
  fixes the current `NSScreen.main` behavior.
- No placement feature needs a permission, so scripts behave the same on every
  Mac whatever its TCC state.
- The common launch path adds no measurable cost.
- Selector logic is deterministic and testable on single-display machines and
  CI.

### Negative

- Real multi-display behavior cannot be checked in CI or on a single-display
  development Mac. Before issue #74 closes, a manual check on a two-display
  setup must cover `-5`, `-4`, `-2`, `primary`, `N` and a name, including a
  display arranged left of the primary.
- `-1` is an approximation, because Spaces have no public API.
- Without a grab, an app that steals focus also takes the keyboard until the
  user clicks the panel again. Upstream's grab prevents that.
- Monitor names differ from xrandr names, so configurations that name an X11
  output fall back to `primary` with a warning.
- `monitor`, `xoffset`, `yoffset` and `click-to-exit` in `config.rasi`, and the
  `x-offset`/`y-offset` theme properties, are not read yet.

### Compatibility intent

Scripts that pass `-monitor`, `-m`, `-xoffset`, `-yoffset`, `-location` or
`-no-click-to-exit` keep working, and placement follows upstream's rules
wherever macOS exposes the inputs. The rest of issue
#75 (the `window` mode, icon themes, paste and copy keys, screenshots and the
dropped X11 flags) is outside this ADR.
