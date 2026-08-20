# Spacewalker #29 — Quick Switcher panel has unbounded height and no scrolling

Issue: https://github.com/blsmth/spacewalker/issues/29
Base: main @ 4b5d853. Branch: fix/quick-switcher-scrolling

## Problem
`QuickSwitcher.swift:294-295` computes panel height as `header + rows*46 + gaps + footer`,
with **no screen clamp and no scroll view**.

macOS allows up to 16 desktops per display. Across two displays `allSpaces`
(`SpaceService.swift:176-178`) flattens to 32 rows → a ~1,600pt panel taller than any
screen, with rows physically unreachable. Number badges also stop at 9 (`:411`), so rows
10+ are arrow-key-only — and arrowing moves the selection off-screen with nothing
scrolling it back into view.

## Why this matters more than its severity label suggests
The Quick Switcher is the app's headline feature (⌘0). It degrades precisely for the
target audience — power users with many Spaces. Someone with 12 desktops downloads this
app *because* they have 12 desktops, and the marquee feature is where it breaks. This is
one of the last user-visible bugs before a public release.

## Required fix
- [x] Wrap `stack` in an `NSScrollView`.
- [x] Clamp panel height to `screen.visibleFrame.height * 0.8`.
- [x] Scroll the selection into view in `move(_:)` — arrowing must never strand the
      selection off-screen.
- [x] Handle rows 10+. Badges stop at 9 today; decide deliberately what rows 10+ show and
      make sure they remain reachable and visibly selectable. Do not leave a silent cliff
      at row 10.

## Scope judgement — read before choosing an approach
The issue suggests "consider replacing the manual stack with an `NSTableView`", noting it
would also fix `render()` (`:360-375`) tearing down and rebuilding every row view on every
keystroke.

**Prefer the smaller change.** This is the headline feature, days before a first public
release, and a full `NSTableView` rewrite carries real regression risk on ⌘0 — the most
exercised path in the app. Do the scroll view + clamp + scroll-into-view + row-10 fix
first, and only reach for `NSTableView` if you find it genuinely *simpler* than retrofitting
the existing stack rather than merely more elegant.

If you conclude the rebuild-every-keystroke behaviour is a real performance problem at 32
rows, measure it rather than assuming, and report the number. If it is a problem, say so
and propose `NSTableView` as a follow-up issue — do not fold a rewrite into this fix.

## Constraints
- Do not regress existing keyboard behaviour: ⌘0 toggle, arrow navigation, number-key
  selection for 1-9, Return to switch, Escape to dismiss. Verify each still works.
- `QuickSwitcher.swift:56` deliberately uses `[.borderless]` and explicitly NOT
  `.nonactivatingPanel` — there is a comment saying so. Do not "fix" that; it is
  intentional and PLAN.md's contradicting bullet is being corrected separately.
- There is a known pre-existing `swift-format` warning in `QuickSwitcher.swift` that every
  recent PR has left alone. You may fix it since you are in this file anyway — but if you
  do, keep it in a separate commit so it does not obscure the real change.
- Multi-display note: `allSpaces` flattening across displays is what produces 32 rows.
  Cross-display *switching* is unsupported (`SpaceService.swift:360-363`) — do not change
  that here; it is #23's territory.
- `swift build`, `swift test` pass; `xcrun swift-format lint -r Sources Tests` clean.
- Reuse the per-module `log` in `Sources/SpacewalkerApp/Logging.swift`.

## Tests
Panel-height computation and the scroll-into-view index math should be pure functions where
possible, so they can be tested without a live panel. At minimum, test the height clamp
against a synthetic screen height with row counts of 1, 9, 16, and 32, and assert the
result never exceeds the clamp.

## Manual verification you should actually do
You can build a bundled app with `./scripts/make-app.sh` (it skips dmg for dev builds).
State clearly in the PR which of these you exercised and which you could not:
- panel with few Spaces (unchanged behaviour)
- panel with enough Spaces to exceed the clamp
- arrowing past the visible region in both directions

## Deliverable
Branch, commit (imperative mood), push, PR against main with a Test Plan. Archive spec to
`docs/specs/29-<slug>.md` with `## Deviations`. Write the PR body to a file and use
`--body-file` (the shell wrapper mangles backticks inline). Never `git add -A`.

## Deviations

- **Approach:** implemented the smaller fix as instructed — `NSScrollView` retrofit, height
  clamp, scroll-into-view, and deliberate row-10+ handling — rather than an `NSTableView`
  rewrite. Did not measure `render()`'s rebuild-per-keystroke cost; at the row counts
  actually reachable on the test hardware (≤7 real Spaces) there was no perceptible
  jank, and 32 synthetic rows wasn't something I could safely fabricate live (see below).
  If this needs measuring at scale, it should be a follow-up issue, not folded in here.
- **Row 10+ handling:** chosen behavior is to show every row's real sequential number
  (previously rows past 9 showed a bare "·"). Only 1–9 still work as number-key jump
  shortcuts (an inherent limit of single-digit keys), but no row is visually anonymous or
  unreachable — arrow keys plus the new scroll-into-view logic reach every row.
- **Geometry extraction:** added a new `QuickSwitcherGeometry` enum (`panelHeight`, `rowTop`,
  `scrollOffset(toReveal:)`) as pure, AppKit-free functions per the spec's testability
  requirement, plus a small `FlippedClipView` so the scroll math's top-down coordinate
  convention (offset 0 = top of the list) matches AppKit's actual scroll position directly.
- **Manual verification gap (disclosed in the PR):** the test machine's single display is
  3440×1440 — tall enough that even the OS maximum of 16 real desktops on one screen never
  exceeds the 0.8 height clamp, and no second display was available to reproduce the
  issue's 32-row case. I did not fabricate ~20+ real desktops on a live, actively-used
  multi-agent dev machine to force the clamp visually; the clamp and scroll-into-view math
  are instead covered by unit tests against a synthetic screen height (rows 1, 9, 16, 32).
  This means live testing confirms *no regression* for the common case but does not visually
  confirm the clamp firing. Digit-key jump / Return completing an actual Space switch was
  also not exercised live, since it changes the system-wide active Space on a shared machine
  with other agent sessions running concurrently — that code path (`pick()`/`onPick`) is
  unmodified by this diff.

## Deviations (review follow-up)

Code review of the PR found the panel's clamped height (0.8H) combined with the pre-existing
+0.12H upward positioning bias always overflows the top of the screen by 0.02H once the
clamp fires, plus two scroll-geometry tests that were tautological against mutation testing.

- **Blocker (top overflow):** extracted the origin/frame computation into a new pure
  `QuickSwitcherGeometry.panelFrame(width:height:visibleFrame:verticalBias:)`, which computes
  the same biased position as before but clamps the resulting frame fully inside
  `visibleFrame` via a private `clamped(_:into:)` helper — a frame clamp by construction
  rather than re-tuning the `0.8`/`0.12` constants against each other, per the review's
  preferred fix. `QuickSwitcherController.layoutContent` now calls this instead of computing
  the origin inline; the bias itself is now a named `Constants.verticalBias` instead of an
  inline magic number.
- **Test coverage for the blocker:** `testPanelFrameIsAlwaysContainedInVisibleFrame` sweeps
  row counts (0, 1, 7, 12, 16, 20, 32) across three real screen heights (860 — a 13" laptop,
  1080, and 1415 — this machine's 3440×1440 ultrawide) and asserts containment, plus separate
  tests pinning the no-overflow (bias preserved), single-edge-clamp, and both-edges-pinned
  cases.
- **Tautological scroll tests:** the two tests that derived their expected value by calling
  `QuickSwitcherGeometry.rowTop` (the function under test) now assert literal numbers instead
  (346 and 100). Added `testRowTopReturnsLiteralOffsets` pinning `rowTop(0) == 0`,
  `rowTop(1) == 50`, `rowTop(10) == 500` — the `50` (`rowHeight` + `rowGap`) is called out as
  load-bearing in the doc comment.
- **Clamp coverage gap:** renamed `testScrollOffsetClampsToTheEndOfTheDocumentForTheLastRow`
  to `testScrollOffsetAlignsBottomEdgeForTheLastRow` since it only exercises the
  bottom-alignment branch's arithmetic, not the `min(..., maxOffset)` clamp (the clamp never
  binds for any in-range index, by construction). Added
  `testScrollOffsetClampBindsWhenRevealingPastTheLastRow`, which reveals an
  out-of-range index (`rowCount`, one past the last row) to force the unclamped result past
  `maxOffset`, so deleting the clamp fails this test. The `totalHeight` `rowCount - 1` gaps
  mutant (using `rowCount` gaps instead) is also caught by this test's literal expected value.
- **Not independently verified live:** this machine still has only the single 3440×1440
  display noted above; the 32-row / two-display overflow case, and the corrected top-clamp
  behavior at that row count, are verified by the geometry unit tests above, not by visually
  confirming a live panel against the menu bar. Everything else (build, existing manual
  verification of few-Spaces/arrow-key behavior) is unaffected by this change since the
  panel's *natural* (non-overflowing) position is unchanged.
