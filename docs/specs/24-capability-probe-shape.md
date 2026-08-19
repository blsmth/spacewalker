# Spacewalker #24 — validate the shape of what the private APIs return

Issue: https://github.com/blsmth/spacewalker/issues/24
Base: main @ 9e121cf. Branch: fix/capability-probe-shape

## Problem
`SpacesAPI.isAvailable` (`Sources/CGSPrivate/SpacesAPI.swift:49-51`) checks only that
`dlsym` resolved the pointers, and only 2 of 3 symbols — `getActiveSpace` is excluded
despite `resolvedCurrent()` and the poll both depending on it.

Nothing validates the *shape* of the returned data. `SpacesAPI.swift:66-77` reads
`"Display Identifier"`, `"Current Space"`, `"ManagedSpaceID"`, `"Spaces"`, `"type"`,
`"uuid"`, `"id64"` out of an untyped `[String: Any]` with silent defaults on every miss
(`?? -1`, `?? ""`, `?? "Main"`). Those silent defaults are the bug.

## Why this is worse than a crash
If a future macOS renames or nests these keys, every Space resolves to `id64 == -1` and
`uuid == ""`, so `SpaceIdentity.key` collapses every Space on every display to the single
string `"id64:-1"` — the exact collision its own doc comment says must never happen. The
UI shows one merged Space, switching targets the wrong desktop, and nothing flags it as a
compatibility problem. On a new macOS release day this looks like an ordinary app bug.

PLAN.md §7 promises "if a symbol is missing or returns garbage, disable that feature…
instead of crashing." Garbage currently does not crash — it quietly manufactures
colliding identities. Make the promise true.

## Required fix
- [ ] Include `getActiveSpace` in the `isAvailable` check.
- [ ] After parsing, sanity-check the result. No two `RawSpace`s within a display may
      share a resolved `SpaceIdentity.key`; `id64` values must be distinct and
      non-negative. Decide deliberately whether an empty `uuid` is still acceptable —
      per PLAN §2 an empty uuid is a REAL, expected observation on macOS 15, not an
      error, so do not reject it blindly.
- [ ] Replace the silent-default parsing with explicit failure. A missing key must be
      distinguishable from a legitimately-absent value.
- [ ] On validation failure, flip availability and surface a "needs update for macOS X"
      state rather than proceeding with corrupt identities.
- [ ] Document at `SkyLightSymbols.swift:17` that the `GetActiveSpace` return width
      (`UInt64`) was confirmed empirically, not from a header — so a future ABI change
      presents as "space matching randomly fails" rather than a crash.

## Ownership — you own the diagnostics surface for this batch
Two sibling agents are working in parallel (#22 overlay localization, #15 keystroke tap).
**You own `DiagnosticsSnapshot.swift` and `DiagnosticsFormatter.swift`** — they are
instructed not to touch them. Add whatever availability/validation state belongs in the
diagnostics dump. Respect the existing redaction rule: no Space names, no absolute paths.
Space counts are fine.

## Do not touch
`Sources/SpacewalkerApp/MissionControlOverlay.swift` (#22 owns), `SwitchKeyTap.swift`
and `README.md` (#15 owns), `PLAN.md` (in flight on unmerged PR #51).

## Constraints
- Keep private-symbol knowledge inside `CGSPrivate` — that isolation is the target's
  entire purpose. Validation logic that needs no private symbol may live in `SpaceModel`.
- `SpaceModel` must stay unit-testable without a WindowServer.
- Do not regress the legitimate empty-uuid handling that `SpaceStore` and `SpaceIdentity`
  already implement (self-healing when a Space starts reporting a uuid, and refusing to
  let a recycled `id64` inherit a dead Space's name).
- `swift build`, `swift test` pass; `xcrun swift-format lint -r Sources Tests` clean.
- Reuse the per-module `log` from each target's `Logging.swift`.

## Tests
This is the most testable issue in the batch — the validator should be a pure function
over parsed `RawSpace`/`RawDisplay` values. Write fixtures for: the healthy case, all
keys renamed (the total-garbage case), duplicate `id64`, negative `id64`, and the
legitimate empty-uuid case that must still pass. Assert the collapse-to-`"id64:-1"`
scenario is now caught.

## Deliverable
Branch, commit (imperative mood), push, PR against main with a Test Plan. Archive spec to
`docs/specs/24-<slug>.md` with `## Deviations`. Write the PR body to a file and use
`--body-file` (the shell wrapper mangles backticks inline). Never `git add -A`.

## Deviations

- **`isAvailable` was left symbol-resolution-only; the "flip on shape failure" lives one
  layer up, in `SpaceService`.** `CGSSpacesAPI` (in `CGSPrivate`) is a stateless,
  effectively-`Sendable`-by-construction type today. Adding a sticky "shape went bad"
  flag to it would have required a lock (`OSAllocatedUnfairLock`/`@unchecked Sendable`)
  purely to satisfy `SpacesReading: Sendable`, for state that has nothing to do with
  private-symbol isolation. Instead: `CGSPrivate.displays()` does per-call explicit-
  failure dict parsing (`parseDisplay`/`parseSpace`) and returns `[]` on a shape it
  can't parse — no persistent state, still fully isolated. The pure, per-display
  sanity checks (duplicate/negative `id64`, collapsed `SpaceIdentity.key`) live in a
  new `SpaceModel.TopologyValidator`, since that check needs `SpaceIdentity` (defined
  in `SpaceModel`, which already depends on `CGSPrivate` — the dependency can't run the
  other way). `SpaceService.refresh()` runs the validator on every raw read and owns
  the sticky `topologyShapeInvalid` flag (mirroring `SpaceStore.persistenceBlocked`'s
  existing "no path clears this within a run" precedent); `SpaceService.isAvailable`
  combines `api.isAvailable && !topologyShapeInvalid`. Net effect is identical to what
  the issue asks for — `isAvailable` (the property the UI actually reads) flips and
  stays flipped — just assembled across the layers that already own each piece of it.

- **No new user-facing banner string.** `AppDelegate` already shows "⚠︎ Spaces N/A" /
  "Spaces API unavailable on this macOS" whenever `service.isAvailable` is false; wiring
  the new sticky flag into `isAvailable` makes that existing banner also cover a shape
  failure, so no new copy was needed. The more specific "needs an update for macOS X"
  detail is surfaced instead in the `log.error` at the point of failure and in the new
  "Shape validation: FAILED — …" line in Copy Diagnostics, rather than in the menu-bar
  UI text itself, to keep this change out of `AppDelegate`'s user-facing strings (owned
  by no one in particular, but reformatting them wasn't asked for and adds review
  surface for no behavior change).

- **Added a `duplicateID64` problem distinct from `duplicateIdentity`.** The issue's
  fix list treats "no two `RawSpace`s share a `SpaceIdentity.key`" and "`id64` values
  must be distinct" as two clauses of the same bullet, but they're not the same check:
  `SpaceIdentity.key` prefers `uuid` when present, so two Spaces sharing an `id64` but
  reporting two different real uuids would pass the key-collision check while still
  violating "id64 values must be distinct." `TopologyValidator.Problem` has a separate
  `duplicateID64` case for this so it doesn't silently pass; a test
  (`testDuplicateID64WithDistinctUUIDsIsInvalid`) pins it down.

- **Added a `CGSPrivateTests` target** (none existed before). It only needs to exist to
  unit-test the new explicit-failure `parseDisplay`/`parseSpace` dictionary parsing —
  pure functions over `[String: Any]`, no `dlsym`/WindowServer involved — via
  `@testable import CGSPrivate`. Not called for explicitly in the spec, but the "explicit
  failure vs. silent default" fix is exactly the kind of thing that regresses silently
  without a test pinning the missing-key behavior, and `CGSPrivate` was otherwise the
  only target with zero test coverage.
