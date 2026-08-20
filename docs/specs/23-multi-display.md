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
