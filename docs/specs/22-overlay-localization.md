# Spacewalker #22 — Mission Control overlay is dead on non-English systems

Issue: https://github.com/blsmth/spacewalker/issues/22
Base: main @ 9e121cf. Branch: fix/overlay-localization

## Problem
The overlay locates Dock elements by comparing against **English display strings**:
  `MissionControlOverlay.swift:46` — title == "Mission Control"
  `:62` — title: "Spaces Bar"
  `:76` — title.hasPrefix("Desktop ")
These are localized display titles, not stable identifiers. German reports
"Missionssteuerung" / "Schreibtisch N"; Japanese "ミッションコントロール" / "デスクトップ N".

## Impact
On any non-English system `tick()` never finds the Mission Control group, `desktopRects`
stays empty, `render` is never called, and the app's headline differentiator (PLAN §4.3)
**silently does nothing**. No banner, no log, no indication it is unsupported. This is
present today, not hypothetical.

## Required fix
- [ ] Locate elements by AX `role`/`subrole` and structural position rather than English
      literals. Use `AXIdentifier` if the Dock exposes one — check whether it does before
      assuming either way.
- [ ] Match desktop buttons by role plus a trailing numeric pattern, independent of any
      "Desktop " prefix. Note the number itself may be localized in some scripts — prefer
      structural index over parsing the digit where you can.
- [ ] **At minimum**, detect the failure and surface it rather than doing nothing
      silently. Silent nothing is the worst outcome here and the whole point of the issue.

## Be honest about what you can verify
You are almost certainly running on an English system, so you cannot directly confirm the
fix works in German or Japanese. **Do not claim you verified non-English behaviour.**
State plainly in the PR which parts you exercised and which are reasoned-but-unverified.
If you can construct a test that does not depend on the host language — e.g. asserting the
matcher logic against synthetic AX-like fixtures rather than a live Dock — that is far
more valuable than a live test that only proves English still works. Confirm English is
not regressed, since that is what actually ships today.

This project has already been bitten by confident claims over unverified steps (a script
printing "✓ Created identity" over an empty keychain). Do not add another.

## Ownership — stay in your lane
Two sibling agents are working in parallel.
- **Do NOT touch** `DiagnosticsSnapshot.swift` or `DiagnosticsFormatter.swift` — the #24
  agent owns them this batch. If overlay-language support belongs in the diagnostics dump
  (it probably does), say so in your PR body as a follow-up rather than editing those files.
- **Do NOT touch** `README.md` or `SwitchKeyTap.swift` (#15 owns), `SpacesAPI.swift` or
  `SkyLightSymbols.swift` (#24 owns), or `PLAN.md` (in flight on unmerged PR #51).
- Surface the unsupported state via the existing per-module `log` in
  `Sources/SpacewalkerApp/Logging.swift`, and any UI affordance that lives inside the
  overlay's own code path.

## Constraints
- `AXUtil` was just hardened in #49 — its accessors return `nil` rather than trapping on
  unexpected values. Preserve that; do not reintroduce force-casts or force-unwraps.
- The overlay's polling was deliberately gated for idle in PR #47 (0.15s while Mission
  Control is open, 1.0s idle). Do not undo that.
- `swift build`, `swift test` pass; `xcrun swift-format lint -r Sources Tests` clean.

## Deliverable
Branch, commit (imperative mood), push, PR against main with a Test Plan. Archive spec to
`docs/specs/22-<slug>.md` with `## Deviations`. Write the PR body to a file and use
`--body-file`. Never `git add -A`.

## Deviations

- **Kept `title == "Mission Control"` semantics but swapped the predicate to role.** Rather
  than a from-scratch redesign, `missionControlGroup(in:)` keeps the exact same traversal
  shape as before (`AXUtil.children(dock).first(where:)`, first direct child of the Dock's
  `AXApplication` element) and only swaps the English-title equality check for
  `role == kAXGroupRole`. This is the minimal, lowest-risk change that satisfies "role, not
  title" — it doesn't add a new AXObserver-based detection path (explicitly out of scope
  per the `tick()` doc comment, since this environment can't open a live Mission Control to
  verify one).

- **`AXIdentifier` was checked, not used.** The spec says "use `AXIdentifier` if the Dock
  exposes one — check whether it does." I checked: on this system's idle Dock, no element
  (the `AXApplication`, the persistent `AXList`, or any `AXDockItem`) exposes a non-nil
  `AXIdentifier`. I could not get Mission Control to actually open in this sandboxed
  environment (see below), so I could not check whether the Mission Control group or
  Spaces Bar buttons expose one while open. Since I have no confirmed identifier string to
  match against, I did not add speculative `AXIdentifier` matching — inventing an unverified
  "known-good" identifier constant would be exactly the kind of unearned-confidence claim
  the spec warns against. This is a documented follow-up, not a silent gap: see
  `missionControlGroup(in:)`'s doc comment.

- **Introduced a new file, `MissionControlMatching.swift`, plus a plain `AXNode` value
  type**, not called for explicitly in the spec. This wasn't strictly required, but it's
  what makes the "synthetic AX-like fixtures independent of host language" testing the spec
  asks for possible at all — `AXUIElement` is an opaque CF type that can't be hand-built in
  a unit test, so the pure role/structure/row-shape matching logic needed a seam. Kept in
  the same `SpacewalkerApp` target (no new module) since the spec didn't ask for a layering
  change and this issue's scope is one file's worth of logic.

- **Widened the DFS depth budget from 6 to 12.** The old implementation was *two*
  separately-bounded searches from the Mission Control group to a button:
  `AXUtil.firstDescendant(missionControl, title: "Spaces Bar")` (`depth < 12`) then
  `collectDesktops` from there (`depth < 6`) — up to 18 levels of combined reach. Collapsing
  both into one DFS (no more separate "find the bar by title" step) at the smaller of the
  two old bounds would have been a real regression for any Dock tree nested deeper than 6
  levels below the MC group. Caught this via a depth-cap test while writing the test suite
  (`testDesktopRectsRespectsTraversalDepthCap`) and widened it to 12 (the larger of the two
  old bounds) rather than removing the cap outright, keeping the traversal bounded and cheap.

- **Removed `AXUtil.firstDescendant(_:title:role:)`** rather than leaving it dead. It had
  exactly one call site (the old `"Spaces Bar"` lookup, now gone) and its entire purpose —
  find-by-English-title — is the anti-pattern this issue removes; leaving it around invites
  a future feature to reach for it again.

- **Added an in-overlay "unsupported" notice pill**, not just a log line. The spec's "at
  minimum" bar was a log; `renderUnsupportedNotice()` also paints a small pill inside the
  overlay's own window/render path (reusing the existing pill chrome, refactored into
  `makePill(borderColor:)` to avoid duplicating it) so a user sees *something* even without
  checking `log show`. Rate-limited to one `log.warning` per Mission-Control-open session via
  `hasLoggedDetectionFailure`, given the 0.15s active poll rate (PR #47).
