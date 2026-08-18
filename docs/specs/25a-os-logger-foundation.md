# Spacewalker #25 PR-A — structured logging foundation

Issue: https://github.com/blsmth/spacewalker/issues/25 (PART A OF TWO)
Base: main @ 914b31c. Branch: feat/os-logger-foundation

## Why this is the top priority
Two failures on a live machine hid behind silence: a single NSLog lost under
AppKit chatter, and a script printing "Created identity" over an empty keychain.
It cost two rounds of guessing. For an app built on private APIs that Apple can
change without notice, diagnostics are how the project survives its first OS
release.

## SCOPE — PART A ONLY
IN scope:
  - Per-module `Logger(subsystem: "app.spacewalker", category: "<module>")`.
  - Replace ALL existing NSLog calls with structured Logger calls.
  - Log every SwitchResult outcome, every symbol-resolution failure in
    SkyLightSymbols.load, and every store read/write outcome.
OUT of scope (these are PR-B, a follow-up — do not build them):
  - "Copy Diagnostics" menu item
  - About item / version in UI
  - Uncaught-exception handler
Leave PR-B's surface unbuilt, but design the logging so B can harvest recent
entries later (i.e. consistent subsystem + categories).

## Targets needing a category
  CGSPrivate, SpaceModel, SpaceSwitching, SpaceService, SpacewalkerApp
Use a category per module, not per file.

## The issue's line numbers are STALE
It cites NSLog at AppDelegate.swift:101,257,342 — those are GONE (14 PRs merged
since). Current NSLog sites are in SpaceModel/SpaceStore.swift (6),
SpacewalkerApp/SwitchKeyTap.swift (1), SpaceSwitching/SystemPrefsBackup.swift (1).
Re-grep and fix what is actually there.

## Privacy annotations — do not skip
os.Logger redacts interpolated strings by default. Space names, file paths, and
display UUIDs are user data: choose `.public` vs `.private` deliberately per
interpolation. A diagnostics log that redacts the useful half is worthless; one
that leaks user data is worse. State your policy in the PR body.

## Constraints
- No behavior change. Logging only.
- SpaceModel is the "pure domain" target and must stay unit-testable without a
  WindowServer — `import os` is fine, but do not introduce AppKit or I/O.
- Do not add a third-party logging dependency. `import os` only.

## Deliverable
Branch, commit, push, open PR against main. Include a short Test Plan covering
how to actually SEE the output (the `log stream --predicate` invocation for this
subsystem) — that command is half the value of this PR. Do not `git add -A`.

## Deviations

- The three cited NSLog sites (`SpaceStore.swift`, `SwitchKeyTap.swift`,
  `SystemPrefsBackup.swift`) were confirmed still in place and replaced 1:1.
- "Store read/write outcome" was read to mean success as well as failure — added
  `.debug`/`.info` logs for first-launch (no file yet), successful load (record
  count), legacy-format migration, and successful persist, not just the failure
  paths that already had NSLog. Also added a load-failure log to
  `SystemPrefsBackup.load` (previously silent `nil` return) since it is a second
  read path in the same file whose write path already logged failures.
- `SwitchResult` logging in `SpaceService` is centralized through one new
  `complete(_:completion:)` helper that both `finish()` and every early-return
  completion call now go through, rather than scattering a log call at each of
  the ~6 call sites individually. Purely a routing change — no result, ordering,
  or timing is different from before.
