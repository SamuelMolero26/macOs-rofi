# ADR 0001: Define the supported Rasi subset and AppKit mapping

## Status

Accepted — 2026-11-05

## Context

GitHub issue #73 adds configuration and theming to the native macOS port. The
port currently builds its AppKit panel from hard-coded geometry and system
colors. It does not load `~/.config/rofi/config.rasi`, an explicit `-config`, or
Rasi themes. The existing `PanelStyle` is the narrow shared seam used by both
dmenu and `-show` panels, so configuration must resolve before those panels are
built rather than being interpreted inside individual views.

Upstream Rasi is a large styling language. Its themes can describe arbitrary
widget trees, stateful selectors, images, calculations, media queries, and
backend-specific behavior. Reproducing that engine would couple the port to
X11/Wayland concepts that AppKit does not expose and would delay the useful
subset requested by issue #73.

The compatibility target is therefore behavioral, not parser-name-only: common
upstream themes must parse, supported declarations must produce predictable
native styling, and unsupported declarations must warn rather than make an
otherwise usable theme fail. Evidence for this boundary comes from upstream's
`doc/rofi-theme.5.markdown`, `doc/rofi.1.markdown`, default configuration, and
representative themes including `gruvbox-dark.rasi`, `sidebar.rasi`, and
`material.rasi`.

Issue #68 is proceeding in parallel through script-mode and row-icon work. Its
script protocol, row metadata, and icon behavior are not part of this ADR. The
shared panel integration must avoid depending on those changes.

## Decision

### 1. Own a tolerant, typed Rasi subset in RofiCore

RofiCore will parse source text into syntax values, resolve the supported
cascade into a typed configuration, and return diagnostics independently from
AppKit. AppKit receives only resolved values through shared `PanelStyle`; it
does not read files, parse Rasi, or resolve references.

The parser accepts UTF-8 with LF or CRLF newlines and the following syntax:

| Syntax | Supported behavior |
| --- | --- |
| Comments | `//` line comments and nested `/* ... */` block comments are ignored outside strings. |
| Selectors | `*`, `configuration`, and element paths made from names, optional leading `#`, whitespace or dot-separated states, and comma-separated selector lists are parsed. |
| Declarations | `name: value;` declarations are retained in source order. Later declarations for the same resolved slot win. |
| Variables | Declarations in `*` may use custom names and may be referenced as `@name`. References may chain. |
| References | `@name`, `var(name, fallback)`, and `inherit` are accepted. Cycles and missing values are diagnosed. |
| Imports | `@import`, optional `?import`, and `@theme` string directives are accepted. Their loading behavior is defined below. |
| Colors | CSS named colors (including `transparent`), `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(...)`, and `rgba(...)` are supported. Names are ASCII case-insensitive. |
| Numbers | Signed integers and real numbers are parsed so unsupported declarations can still be skipped accurately. |
| Dimensions | Unitless values, `px`, `em`, `ch`, and `%` are supported where a distance is expected. Unitless distances mean `px`. |
| Insets | One through four dimensions use CSS order: all; vertical/horizontal; top/horizontal/bottom; top/right/bottom/left. |
| Strings and booleans | Single-quoted or double-quoted strings and `true`/`false` are parsed where configuration values require them. |

The parser must consume syntactically valid declarations even when their
selector, property, or value type is not supported. This permits representative
upstream themes to contribute supported values without requiring their entire
widget model. Opaque arrays, function calls, and keyword sequences may be
retained only far enough to find the terminating semicolon and issue a precise
warning.

Within one theme source:

1. An imported file is evaluated at the `@import` directive's position.
2. Repeated selectors merge; the last declaration for a resolved slot wins.
3. Comma-separated selectors behave as if the declaration block appeared once
   for each selector.
4. `*` provides variable and property fallbacks; a supported element selector
   overrides the corresponding global property.
5. Selector state names are normalized for matching, but arbitrary descendant
   or widget-tree matching is not performed.
6. Reference resolution is lazy, so a supported declaration can refer to a
   variable declared later in the effective theme.

`@import` merges another file into the current theme. `@theme` discards the
visual theme accumulated so far, restores built-in visual defaults, and then
loads the named theme. It does not reset values in `configuration { ... }`.
This matches the useful upstream distinction between composing a theme and
starting a fresh one.

### 2. Resolve sources in one explicit precedence order

Sources are evaluated from lowest to highest precedence:

1. Built-in configuration and `PanelStyle` defaults.
2. Exactly one configuration file: the discovered default or the file named by
   `-config`.
3. The theme selected by the effective configuration or by `-theme`.
4. Every `-theme-str` value, in command-line occurrence order.
5. Direct CLI overrides already supported by the port.

The default configuration path is
`$XDG_CONFIG_HOME/rofi/config.rasi` when `XDG_CONFIG_HOME` is an absolute,
non-empty path; otherwise it is `~/.config/rofi/config.rasi`. A missing default
configuration is normal and produces no warning. `-config <path>` replaces
default discovery; the two files are never merged.

`-no-config` skips both default discovery and an explicit `-config`, including
imports reachable only from that file. When both flags are present,
`-no-config` wins and a warning says that `-config` was ignored. It does not
disable `-theme`, `-theme-str`, or direct CLI overrides.

Like upstream `@theme`, `-theme` starts a fresh visual theme rather than merging
with visual declarations from the configuration file. Nonvisual configuration
values remain in force. A configured theme is used only when the command line
does not provide `-theme`. Each repeatable `-theme-str` then merges into the
current visual theme, in argument order.

Direct command-line flags are the final authority. In the current port this
notably means dmenu `-l` overrides resolved `lines`, and `-b` overrides resolved
`location` with south/bottom-center placement. If `-location` is implemented as
a direct compatibility flag, it is more explicit than `-b` and wins when both
are present. Colors, font, width, padding, and border are overridden from the
command line through `-theme-str`; this ADR does not restore deprecated
upstream one-flag-per-theme-property options.

`-dump-config` resolves the same sources and overrides as a normal run, writes a
deterministic UTF-8 Rasi representation to stdout, and exits without opening an
AppKit window. Its output contains a canonical `configuration` block and
canonical selector blocks sufficient to round-trip every supported resolved
value. It excludes source paths, comments, unsupported declarations, and
diagnostics. Warnings still go to stderr.

### 3. Map the supported properties through shared PanelStyle

The resolver produces sRGB color values with alpha, a native font request,
logical dimensions, and edge values. `PanelStyle` is extended to carry these
resolved values for both dmenu and `-show`; neither mode owns a second theme
model.

The supported selector/property mapping is:

| Rasi source | Resolved `PanelStyle` concept | AppKit effect |
| --- | --- | --- |
| `window` or `*` `background-color` | `backgroundColor` | `NSPanel.backgroundColor`; opacity follows alpha. |
| `window` or `*` `text-color` | `textColor` | Default prompt, entry, message, switcher, and row foreground. |
| `element normal` `background-color` / `text-color` | `rowBackgroundColor` / `rowTextColor` | Normal table-row fill and text. |
| `element alternate normal` colors | `alternateRowBackgroundColor` / `alternateRowTextColor` | Alternating normal rows; absent values fall back to normal rows. |
| `element selected normal` colors | `selectedBackgroundColor` / `selectedTextColor` | Selected normal row fill and text. |
| `element ... active` colors | Active palette slots | Active rows, with selected and alternate variants falling back to the nearest active or normal slot. |
| `element ... urgent` colors | Urgent palette slots | Urgent rows, with selected and alternate variants falling back to the nearest urgent or normal slot. |
| `window`, `mainbox`, or `*` `border-color` | `borderColor` | Panel content-layer border color. |
| `window` or `*` `font` | `font` | Base `NSFont` used by prompt, entry, message, switcher, and rows. |
| `window` or `*` `width` | `width` | Panel frame width before screen clamping. |
| `listview` or `configuration` `lines` | `fixedRows` | Requested visible result-row count. |
| `window` or `configuration` `location` | `location` | Panel placement in the visible frame. |
| `window`, then `mainbox`, then `*` `padding` | `contentInsets` | Edge constraints around panel content. The first defined selector in that order wins. |
| `window`, then `mainbox`, then `*` `border` | `borderWidths` | Per-edge panel border widths. The first defined selector in that order wins. |

For color declarations on `entry`, `prompt`, `message`, `button`, or
`mode-switcher`, the resolver may fill a more specific `PanelStyle` color slot
when one exists; otherwise it warns and leaves the shared default. This keeps
the model extensible without pretending to implement arbitrary widgets.

The value conversions are:

- Rasi `px` is one AppKit logical point. AppKit then handles backing scale.
- `em` uses the resolved font's line height; `ch` uses the width of the `0`
  glyph; `%` uses the relevant visible-screen dimension.
- Width percentages use visible-screen width. Horizontal inset percentages use
  visible-screen width; vertical inset percentages use visible-screen height.
- Width is clamped to the visible frame after conversion. Negative width,
  padding, or border values are invalid and ignored with a warning.
- `lines` is a nonnegative integer. Zero is a deliberate request for no result
  rows rather than an unset value.
- `location` accepts `center`, `north`, `north east`, `east`, `south east`,
  `south`, `south west`, `west`, and `north west`. The legacy numeric mapping
  `0...8` is accepted in `configuration`, matching upstream's 3-by-3 positions.
- A font string is interpreted as family, optional traits, and size. AppKit
  performs family fallback; an unavailable family warns and retains the
  built-in font rather than changing metrics unpredictably.
- Border line style may be omitted or `solid`. `dash` is parsed but unsupported
  and warns; its width is retained as a solid border only when doing so is
  explicitly reported by the warning.

Supported colors are converted to calibrated sRGB rather than AppKit semantic
colors so `-dump-config` and screenshots remain stable across appearance modes.
Built-in defaults may still originate from semantic system colors, but dumping
serializes their resolved sRGB values for that run.

### 4. Separate warnings from malformed input

Diagnostics include source identity and line/column when available and are
written to stderr with a stable `rofi: warning:` prefix. The implementation may
deduplicate the same unsupported selector/property pair per source to avoid
flooding stderr, but it must not silently drop the first occurrence.

These conditions warn and continue:

- A syntactically valid but unsupported selector or property.
- A supported property with an unsupported value type or unit.
- An invalid value for a supported property, including an unresolved reference
  or reference cycle; only that declaration is ignored.
- A missing optional `?import`.
- A recognized approximation described by this ADR, such as a dashed border
  rendered solid.

Custom variable declarations do not warn merely because their names are not
known properties. They warn only when they cannot resolve a supported value or
are otherwise used as unsupported declarations.

Malformed structure is different from unsupported semantics. Invalid UTF-8,
an unterminated string or comment, unbalanced braces, a declaration missing
its colon or semicolon, a malformed import directive, or an import cycle is a
fatal configuration error. Resolution is transactional: no partially resolved
configuration reaches AppKit, the process reports the error on stderr, and it
exits nonzero without opening a window. The same rule applies to malformed
`-theme-str` input and to `-dump-config`.

A missing or unreadable explicit `-config`, `-theme`, or required `@import` is
also fatal. A valid source containing only unsupported declarations is not
fatal; it produces warnings and leaves the previous supported values intact.

### 5. Constrain file and import handling

Configuration loading is local-data parsing only. It never executes commands,
loads plugins, expands values through a shell, evaluates scripts, fetches URLs,
or follows network schemes.

Paths follow these rules:

1. `-config` and path-like `-theme` values may be absolute or relative to the
   process working directory. A leading `~` expands only to the current user's
   home directory; `~other-user` is not supported.
2. A bare theme name is searched as `.rasi`, then `.rasinc`, in the active
   configuration directory's `themes` child, the configuration directory
   itself, `$XDG_CONFIG_HOME/rofi/themes`, `$XDG_CONFIG_HOME/rofi`,
   `$XDG_DATA_HOME/rofi/themes`, and bundled application theme resources, in
   that order. The XDG roots use their standard `~/.config` and
   `~/.local/share` fallbacks when unset.
3. `@import` and `@theme` first resolve relative to the including file, then use
   the same theme search roots. A directive inside `-theme-str` has no including
   directory and therefore uses only the theme search roots.
4. Only regular local files are accepted. Directories, devices, sockets, and
   FIFOs are rejected before reading.
5. Resolved paths are standardized and symlinks are resolved before identity,
   duplicate, and cycle checks. Symlinks to regular local files are allowed.
6. One file is limited to 1 MiB, one resolution may read at most 128 distinct
   files, and import depth is limited to 32. Exceeding a bound is fatal.

The resolver opens each canonical file once per resolution and parses the bytes
it read from that handle. It must not preflight with one path check and then
reopen a different target, which would create a time-of-check/time-of-use gap.
Diagnostics display a useful path but never include file contents beyond the
offending source line.

### 6. Keep explicit exclusions visible

This ADR does not implement:

- Arbitrary widgets, `children` layout trees, general descendant matching, or
  custom widget creation.
- Plugins, script execution, command interpolation, or remote theme loading.
- X11/Wayland-only semantics such as window IDs, compositor transparency,
  monitor selectors, grabs, DPI backends, or layer-shell placement.
- Images, gradients, cursors, media queries, environment-value functions,
  `calc(...)`, animation, rounded corners, shadows, or physical `mm` units.
- Color syntaxes beyond the named, hex, `rgb`, and `rgba` forms listed above,
  including HSL, HWB, and CMYK.
- Unsupported Rasi properties merely because the parser can tokenize them.
- Full Pango font-description parity; AppKit font matching is authoritative.
- `-dump-theme`, `-rasi-validate`, a theme selector UI, or system-wide
  `/etc/rofi.rasi` discovery.
- Issue #68 row-icon behavior, script-protocol headers, script mode lifecycle,
  or any other row metadata work.

Future support requires a new ADR or an amendment when it changes the syntax,
cascade, security boundary, or `PanelStyle` contract. Adding a property that
maps directly into an existing slot may be an ordinary compatible change with
tests and documentation.

## Consequences

### Positive

- Users get a useful upstream-compatible configuration path without importing
  an X11/Wayland widget engine into the native AppKit architecture.
- Parser and resolver behavior is deterministic and testable without launching
  a window.
- Both dmenu and `-show` receive one shared `PanelStyle`, preventing visual
  behavior from diverging by mode.
- Representative upstream themes can be used as parser fixtures even when only
  part of their visual intent maps to AppKit.
- Warnings make compatibility gaps visible while preserving supported values.
- Transactional malformed-input handling prevents half-applied configuration
  and makes `-dump-config` a reliable debugging boundary.

### Negative

- Many upstream themes will render only approximately because arbitrary widget
  layout and backend-specific properties are intentionally excluded.
- Mapping Rasi `px` to AppKit points favors stable native sizing over literal
  physical pixels on Retina displays.
- Warning output can be noisy for large themes, even with per-source
  deduplication.
- Supporting imports requires explicit resource limits, canonical-path checks,
  and more diagnostics than a single-file parser.
- A malformed automatic config fails startup instead of silently falling back;
  users must fix it or use `-no-config`.

### Compatibility intent

The supported subset should preserve upstream source order, theme replacement,
repeatable `-theme-str`, common color/reference behavior, and visible geometry
closely enough that users can reuse ordinary theme fragments. Compatibility is
not a claim that every valid upstream Rasi program has identical output.
Unsupported properties remain forward-compatible warnings, and the canonical
`-dump-config` output defines this port's effective supported contract.

Implementation proceeds in the following work units after this ADR: the
parser/resolver, configuration and CLI loading, then shared `PanelStyle`
integration. Issue #68 continues independently and is not a prerequisite for
the parser or loader layers.
