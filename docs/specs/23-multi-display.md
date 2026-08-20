# Issue #23 — multi-display: task brief

Archived verbatim (lightly reformatted) from the task brief this branch was scoped from, per
this repo's "archive the spec" convention. See the PR body for what was actually verified vs.
reasoned, and the `## Deviations` section below for where the implementation diverged.

## Issue #23, as corrected

`gh issue view 23`'s body was corrected in place (2026-08-20 pre-public-release audit). Of the
three originally-reported "broken places," place 1 was already fixed on `main` before this branch
started: `.crossDisplayUnsupported` surfaces a HUD flash ("Can't switch across displays yet") and
a `log.notice`. The README's "Known limitations" section already discloses all three symptoms.

Still open going into this branch:

1. `SpaceService.swift:422` — `let singleDisplay = displays.count == 1` disabled direct ⌃N
   entirely whenever more than one display was attached, degrading all multi-display switching to
   the 220ms-per-hop ⌃←/⌃→ walk, even for a switch that never left the current display.
2. `MissionControlOverlay` was primary-screen-only: one window sized to the primary screen, and
   `cocoaRect(fromAX:primary:)` converted using the primary screen's height, so any label for a
   Space on a secondary display was positioned wrong even if it rendered.
3. The "Displays have separate Spaces" system setting (`com.apple.spaces spans-displays`) was
   never read anywhere in the repo. Whether `CGSCopyManagedDisplaySpaces` still reports one
   topology entry per physical display when it's off was (and remains) unverified.
4. Menu annotation was half-done: a disabled "Display N" header appeared when `displays.count > 1`,
   but cross-display Space items themselves were not disabled.

## Constraint

This machine has exactly one display (3440x1440) — multi-display behavior cannot be fully
verified here. The task explicitly warned against writing speculative multi-display code and
describing it as fixed, since a previous "manual QA matrix on 1 + 2 displays" had been claimed but
never actually run.

## Prioritized approach given to this branch

- (a) Read `spans-displays` and expose it through the topology layer (`SpacesReading`), with unit
  tests via the existing `FakeSpacesReading` seam.
- (b) Fix the ⌃N gate to depend on "target Space shares a display with the active one," not on
  total display count — narrowing to the correct-by-construction precondition rather than guessing
  at unverified cross-display symbolic-hotkey semantics.
- (c) Disable cross-display menu items rather than leaving them silently actionable.
- (d) Refactor the Mission Control overlay's coordinate conversion into a pure, per-screen function
  with unit tests against synthetic multi-screen frames (matching the technique PRs #59/#61 used
  for `QuickSwitcherGeometry`/`SwitchHUDTiming`), and give it one overlay window per screen — or,
  if that's judged too risky to land unverified, ship the pure geometry + tests alone and leave the
  window plumbing as a documented follow-up.

## Requirements

- `swift build` clean, `swift test` passing (193 baseline, more expected), `swift-format lint`
  clean.
- Stage only files actually changed.
- Open a PR against `main` referencing #23, explicitly stating what was verified live on one
  display, what's covered only by synthetic-geometry unit tests, and what remains genuinely
  unverified for lack of a second display.
- Update README's "Multi-display is incomplete" section to match whatever is actually true after
  the change.

## Deviations

- Went further than "pure geometry + tests, window plumbing as follow-up" for (d): implemented the
  one-window-per-screen plumbing as well (`MissionControlOverlay`'s `windowsByFrameKey`), since it
  turned out to be a mechanical extension of the pure geometry (each screen's own borderless
  window, subviews placed in that window's local coordinates) rather than requiring anything
  unverifiable. What's deliberately *not* attempted: `MissionControlMatching.bestButtonRow` still
  locates only a single "best" row of desktop buttons — if Mission Control renders a separate
  Spaces Bar per physical display, only one display's Spaces get labeled regardless of this
  change. That's a second, independent gap discovered during this work, called out in the PR body
  and the README rather than silently left unaddressed.
- Added an injectable `desktopShortcutsSatisfied` seam to `SpaceService` (defaulting to
  `DesktopShortcuts.allEnabled`) so the direct-jump gate change could be covered by a deterministic
  unit test instead of depending on this machine's real `com.apple.symbolichotkeys` state — not
  explicitly requested, but required to keep `SpaceServiceTests` hermetic once the gate no longer
  short-circuits on `displays.count == 1`.
- Also threaded `spansDisplays` through to `DiagnosticsCollector`/`DiagnosticsSnapshot`/
  `DiagnosticsFormatter` ("Copy Diagnostics"), beyond the minimum "expose it" ask, since it's a
  direct analog of the existing `displaySpaceCounts`/`topologyShapeValid` diagnostics fields.

## Deviations, round 2 — PR #63 code review rework (2026-08-20)

A review of the opened PR found the ⌃N gate change and the cross-display menu-disable change
both unsafe, plus a pre-existing, unrelated crasher (`MissionControlOverlay`, filed as
[#64](https://github.com/blsmth/spacewalker/issues/64)) that the overlay work in this branch could
never actually exercise on real multi-display hardware. This branch was reworked on top of that
review rather than opening a new PR:

- **Reverted (b) and (c) above in full.** The ⌃N gate is back to `displays.count == 1`, and the
  cross-display menu-item-disable logic in `AppDelegate.swift` is gone — both exactly as they were
  before this branch started. The review's finding: `targetDisplay.spaces.first(where:
  { $0.isCurrent })` (the guard the new gate leaned on as its "already proven same-display" fact)
  succeeds for *every* display once "Displays have separate Spaces" is on, since `isCurrent` is
  computed per-display (`Reconciler.swift`). So the new gate's stated precondition never actually
  held, and the walk's relative step-count math (safe regardless of which display "current" landed
  on) is not the same guarantee as the direct jump's absolute per-display desktop number. Reverting
  to the blanket `displays.count == 1` gate is over-conservative but not unsound. Same reasoning
  killed the menu-disable change: it compared against `service.current?.displayID`, which has no
  reliable source for the display that's actually focused (`resolvedCurrent()` prefers the primary
  display's active Space, or falls back to the first display in the topology array) — so it
  disabled the wrong display's items, backwards from the intent.
  `Fixture.crossDisplay()`/`SpaceServiceDirectJumpGateTests` (added to test the reverted code) were
  deleted rather than rewritten with a "realistic" topology, since a topology where every display
  legitimately has its own current Space also defeats the *existing*, pre-#23 crossDisplayUnsupported
  detection — which is real, but is issue #23's now-explicit prerequisite, not something this pass
  introduced or could respectably paper over with a test.
- (a) and the diagnostics wiring are unchanged, aside from fixing `spansDisplays()`'s preference
  domain (`kCFPreferencesAnyHost`, not `kCFPreferencesCurrentHost` — the previous domain was
  demonstrably empty of this key regardless of the real setting; see `SpacesAPI.swift`'s doc
  comment). Re-measured after the fix: the key is still absent on this machine.
- **New scope, not in the original brief:** fixed issue #64 (`MissionControlOverlay` crashing via
  `Dictionary(uniqueKeysWithValues:)` on any duplicate-`userIndex` topology, which two or more
  displays always produce). The lookup is now display-aware, not just non-trapping: rows of
  detected desktop buttons are matched to the physical display they structurally belong to (via
  `ScreenDisplayIdentity`, using the public `CGDisplayCreateUUIDFromDisplayID` API — verified live
  on this machine's one display against a real `CGSCopyManagedDisplaySpaces` read, not assumed) and
  a button's structural index is only ever looked up within that display's own Spaces.
  `MissionControlMatching.bestButtonRow`'s single-best-row limitation is partially addressed too:
  `allButtonRows`/`desktopRows` can now return more than one row (needed for a genuine per-display
  Spaces Bar), and `uniformRow` now rejects buttons that share a y but aren't x-contiguous, so a
  same-y merge across two physical screens can't win the row-selection tiebreak the way it could
  before. Neither of those is verified against a real second monitor.

## Deviations, round 3 — PR #63 code review rework #2: fixing regressions the rework itself introduced (2026-08-20)

A second review confirmed round 2's crash fix held (no input traps the old code did, and the old
shape still traps standalone) but found the *same PR* had regressed the single-display overlay —
this app's headline feature — worse than the crash it fixed: three blockers/high findings (F1,
F2, F3), one architectural gap (F4), and one factually wrong doc comment (F5). This pass fixes all
five without reopening the ⌃N gate or menu-predicate changes, which stay reverted per round 2.

- **F1 (blocker, fixed, live-verified).** `MissionControlOverlayGeometry.screenFrame(containing:among:)`
  required a rect's *center* to land inside a screen's frame. Mission Control's Spaces Bar rests
  **collapsed above the physical screen's top edge** as its normal, steady state — not an edge
  case — so that requirement silently dropped every row, every tick, turning the overlay into a
  permanent no-op on a single display. Fixed with a three-tier resolution: strict center
  containment first (still needed to disambiguate two screens whose horizontal spans overlap,
  e.g. one stacked above another), then **x-overlap** with a screen's horizontal span (what
  actually fixes the collapsed-bar case — screens tile left/right, and MC's collapse/expand
  animation only ever moves a row vertically), then nearest-by-distance as a last resort so this
  is never `nil` except when there are no screens at all. Live-verified: `scripts/dump-mc-ax.swift`
  captured the real AX rect for a collapsed "Desktop 1" button — `(1338, -32, 65, 24)` on this
  machine's one 3440x1440 display — and that exact geometry is now a regression test in
  `MissionControlOverlayGeometryTests` and `MissionControlRowResolutionTests`.
- **F2 (blocker, fixed).** CGS reports the literal string `"Main"`, not a UUID, for the active
  display's own topology entry whenever "Displays have separate Spaces" is off — confirmed two
  ways: this machine's own `com.apple.spaces.plist` has a `"Display Identifier" = Main` entry, and
  Hammerspoon's `hs.spaces` has mapped `"Main"` to the main screen's UUID for years, gated on the
  same setting. `ScreenDisplayIdentity.candidateDisplayIDs(uuid:isMainScreen:)` (pure, tested) now
  offers the UUID first, then `"Main"` for the menu-bar screen specifically, and
  `MissionControlRowResolution.resolve` tries each candidate against the topology in order instead
  of assuming one form. This is a global toggle, so it affects single-display machines too.
- **F3 (high, fixed, live-verified for the single-button decoy shape).** `allButtonRows`'s
  geometric fallback accepted a row of one button, so an incidental window whose title happened to
  end in a digit (a real title from this machine, `"agentctl · personal · brandon:2"`) could be
  promoted to a bogus "Spaces Bar" and painted over with a custom Space name. Fixed by requiring
  at least 2 aligned buttons before the geometric fallback runs at all — the identifier match
  (F5) doesn't need this, since it's already authoritative. This does **not** close every decoy
  shape (two *aligned* multi-button window clusters with numeral-ending titles would still pass;
  see `testAllButtonRowsCanStillBeConfusedByTwoAlignedNumericWindowDecoysWithoutTheIdentifier`,
  kept as a documented residual) — F5's identifier match is the real closing fix for a live Dock.
- **F4 (architectural gap, fixed).** Two independent mutations of `render(_:)`'s composition
  itself — bypassing display attribution, and reintroducing the flat, trapping
  `Dictionary(uniqueKeysWithValues:)` — both passed the full test suite, because no test exercised
  the composition, only the pure helpers it called. Extracted that composition into
  `MissionControlRowResolution.resolve(rows:allSpaces:anchorScreenHeight:screenFrames:
  displayIDCandidates:)`, a pure function with screen frames and the display-ID mapping injected,
  and pointed `render(_:)` at it exclusively. `MissionControlRowResolutionTests` pins the #64
  crash shape, F1's collapsed-row case, and F2's `"Main"` fallback, all through this one function.
- **F5 (doc correction + real fix).** A previous comment claimed Mission Control exposed no
  `AXIdentifier` on any element — false, and never actually checked with Mission Control open.
  `scripts/dump-mc-ax.swift`'s live capture shows stable identifiers on every element that
  matters: `mc`, `mc.display`, `mc.windows`, `mc.spaces`, `mc.spaces.list`, `mc.spaces.add`.
  `MissionControlMatching` now matches `mc.spaces.list` directly as its primary path, falling back
  to the geometric heuristic only when no such identifier is found anywhere — locale-independent
  by construction and immune to the F3 decoy shape by construction, not just by the ≥2-button
  filter. **`mc.display` did not, in the end, give structural per-display attribution**: only one
  `mc.display` group was observed on this single-display machine (consistent with either "one per
  display" or "one, shared" — this machine can't distinguish the two), so
  `MissionControlRowResolution` still resolves a row's display via screen geometry +
  `ScreenDisplayIdentity`, not via `mc.display`. If `mc.display` is later confirmed to multiply per
  physical display on real multi-monitor hardware, it would let display attribution skip UUID/
  `"Main"` resolution entirely — noted here as a stronger follow-up, not attempted speculatively.

**What's now live-verified, not synthetic-fixture-only:** the real captured Mission Control AX
tree shape while open (`mc`/`mc.display`/`mc.windows`/`mc.spaces`/`mc.spaces.list`/`mc.spaces.add`
identifiers, and the closed-Dock shape), the exact collapsed-Spaces-Bar geometry F1's fix and
regression tests use, and the specific F3 decoy title/frame pair used in its regression test — all
via `scripts/dump-mc-ax.swift`, landed as a permanent repo diagnostic rather than a throwaway
script.

**What attempted live re-verification but could not complete this pass:**
`LiveMissionControlVerificationTests` (opt-in via `SPACEWALKER_LIVE_MC_VERIFY=1`, skipped
otherwise) runs the exact same production code (`MissionControlMatching.desktopRows`,
`MissionControlOverlayGeometry.screenFrame`) against a freshly-opened Mission Control. Earlier in
this same session, `scripts/dump-mc-ax.swift` (a standalone compiled binary) successfully opened
Mission Control and captured the tree quoted throughout this document. A later attempt to reopen
it — both via the same script and from inside the opt-in XCTest — did not actually reopen Mission
Control (`AXIsProcessTrusted()` was still `true`, and the Dock's own AX tree was still readable;
this looks like session/focus state, not a permissions problem). The test is kept as real,
runnable infrastructure for whenever it can complete, rather than removed; its result on this
exact machine on this exact day is itself unconfirmed, which is exactly why the regression tests
above pin the *already-captured* live geometry instead of depending on a fresh reopen.

**Still genuinely unverified:** everything F1–F5 already say is unverified without a second
monitor (whether Mission Control renders one Spaces Bar per display, whether `mc.display`
multiplies per screen, whether `ScreenDisplayIdentity`'s UUID mapping survives a display
attach/detach), plus a new, separately-filed, deliberately-not-fixed-here issue —
[#65](https://github.com/blsmth/spacewalker/issues/65): fullscreen Spaces appear as tiles in the
real Spaces Bar but are excluded from `userIndex` by `Reconciler.resolve`, so a structural
desktop-button index `N` may not equal `userIndex` `N-1` as soon as a user has any fullscreen app
— plausible, not confirmed (no fullscreen Space exists on this machine to check), pre-existing on
`main` before this branch. Filed separately rather than fixed speculatively here.
