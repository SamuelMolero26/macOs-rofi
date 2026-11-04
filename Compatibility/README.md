# Compatibility baseline

This directory turns upstream rofi behavior into a reviewable contract for the
native macOS implementation. The baseline is pinned to
[`davatorium/rofi@1ad1df6b`](https://github.com/davatorium/rofi/commit/1ad1df6b72d4c8b0e40e8ced1249ef8a8a6bc0ad);
it is evidence, not a promise that Linux internals will be copied to macOS.

## Quick workflow

1. Find the capability in [`matrix.yaml`](matrix.yaml).
2. Read the listed source and test evidence at the pinned upstream revision.
3. Add a focused oracle capture only when the matrix calls for one; add a
   native spike only for platform uncertainty.
4. Implement the smallest contract and cite the Swift source and test paths.
5. Update the matrix status, divergence, and evidence in the same review.

The current Swift baseline has T1–T5 complete, byte-oriented row ingestion, an
executable `rofi -dmenu -dump` path, and an interactive AppKit dmenu panel with
asynchronous input, every flag `dmenu.c` reads, multi-select, and row metadata
and Pango markup rendering. Non-dmenu invocations still fail through the
unsupported stub path. Remaining dmenu gaps include custom-accept key bindings,
match highlighting, score ordering, row icons, and configuration files.

## Compatibility classes

| Class | Meaning |
| --- | --- |
| `exact` | Inputs, outputs, ordering, exit status, and other observable contract details must match the pinned upstream behavior. |
| `semantic` | The user-visible workflow must match, while platform-specific storage, process, or integration details may differ explicitly. |
| `native` | macOS provides the equivalent capability through native APIs and conventions rather than Linux display or desktop internals. |
| `deferred` | Compatibility is intentionally postponed until a named tradeoff or prerequisite is resolved. |
| `unsupported` | The upstream capability will not be implemented; invocation must fail or degrade explicitly rather than pretend to work. |

Classes describe the target contract. Status describes delivery: `complete`,
`partial`, `next`, `planned`, `deferred`, or `unsupported`.

## Evidence classes

| Evidence | Use |
| --- | --- |
| `upstream-source` | Primary evidence: implementation, headers, defaults, and protocol definitions at the pinned commit. |
| `upstream-test` | Executable upstream expectations and edge cases. Tests strengthen source evidence but do not replace it. |
| `oracle` | A focused, non-interactive observation from the pinned upstream executable when source and tests leave behavior ambiguous. |
| `native-spike` | A disposable macOS feasibility probe for AppKit, Accessibility, process, filesystem, or other platform behavior. |
| `swift-contract` | Landed Swift production code and tests that demonstrate the current compatibility state. |

`oracle_need` and `spike_need` use `none`, `targeted`, or `required`. A need is
not evidence until its captured artifact is reviewed.

## Update rules

- Keep all upstream paths relative to the upstream repository and verify them
  against the exact revision in the manifest.
- Cite only landed Swift files. An empty `swift_evidence` list means no native
  contract exists yet.
- Record known divergence next to the capability; do not hide it in a fixture
  or implementation comment.
- Prefer source and upstream tests. Use an oracle for ambiguity, not as a bulk
  snapshot generator.
- Keep fixtures environment-neutral according to the pinned manifest: no home
  directories, host paths, locale-dependent text, timestamps, or unordered
  filesystem output.
- Change a class only with an explicit compatibility decision. Change a status
  only with implementation and verification evidence in the same review.
- Keep native C plugins `deferred` while preserving rofi's GLib/Cairo ABI would
  either import the non-native stack or require an unsafe compatibility shim.

## Reviewing an upstream revision bump

An upstream bump is a compatibility review, never an in-place fixture refresh:

1. Create `Compatibility/rofi-<new-short-revision>/manifest.json`; keep the old
   baseline intact.
2. Diff every listed source/test area between the old and new commits.
3. Re-run only affected fixture generators and required non-interactive
   oracles under the new manifest policy.
4. Review fixture changes as behavior changes, update affected matrix rows, and
   explain accepted divergences.
5. Switch the matrix revision only after the new manifest and evidence land in
   the same review.

A changed upstream hash with silently regenerated fixtures is invalid evidence.
