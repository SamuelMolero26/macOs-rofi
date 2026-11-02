# T5 CLI compatibility contracts

This corpus pins the remaining T5 command-line behavior to
`davatorium/rofi@1ad1df6b72d4c8b0e40e8ced1249ef8a8a6bc0ad`
(`2.0.0-dev`). The checkout was verified at that exact commit. The available
MacPorts executable is `rofi @1.7.4_0 (active)`, so it was excluded as an oracle.
Expected values come from the cited source and tests; the `strtol` edge cases
were also checked with a disposable system-C probe on Darwin arm64.

## Validate

From the repository root:

```sh
python3 Compatibility/T5CLI/validate.py
```

The command uses only the Python standard library, repository-relative paths,
and `manifest.json`. It validates the corpus itself; it does not make known
production gaps fail `make test`.

## Contracts

| Contract | Pinned behavior | Current Swift |
| --- | --- | --- |
| Raw argv | Argument lookup retains C `argv` bytes; one-byte `0xff` is a valid separator. | **Gap:** `CommandLine.arguments` replaces invalid UTF-8 before parsing. |
| `argv[0]` | Exact, case-sensitive basename `dmenu` enters dmenu mode without `-dmenu`. | **Gap:** `-dmenu` is mandatory. |
| `-sync` | Read all input before showing the dialog. Dump, select, no-custom, only-match, auto-select, and selected-row also force sync input. | Supported. |
| Matching names | `normal`, `regex`, `glob`, `fuzzy`, and `prefix`, matched ignoring ASCII case. The pinned loop reports an error when the fifth recognized name is added; duplicates count and later names are skipped. | Names supported; five-name limit quirk is a gap. |
| `\x...` character | `strtol(payload, NULL, 16)` followed by C `char` narrowing: whitespace/sign/`0x` work, trailing junk stops parsing, and overflow clamps before the low byte is retained. | Simple leading-hex and low-byte wrapping supported; extended `strtol` forms and overflow are gaps. |
| Negate character | Compare and remove exactly the first raw token byte. | ASCII case supported; a combining mark joined to `-` exposes the grapheme-vs-byte gap. |
| Invalid matching exit | With a working display, config validation shows the error and returns `EX_DATAERR` (65). Upstream returns 1 if display setup fails before validation. | **Policy:** native macOS validation should diagnose on stderr and return 65; display startup ordering is not part of the portable CLI contract. Current Swift returns 1. |

The exit policy deliberately preserves the semantic meaning of `EX_DATAERR`:
the user supplied invalid configuration data. It also keeps headless `-dump`
deterministic on macOS instead of making the status depend on GUI availability.
