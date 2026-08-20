# Spacewalker #27 — GitHub Actions CI + SwitchHUD state machine tests

Issue: https://github.com/blsmth/spacewalker/issues/27
Base: main @ 3668bf3. Branch: ci/github-actions-and-hud-tests

## Problem

Issue #27 originally flagged the test suite as covering "the safest 5%" of the codebase.
Most of its checklist has since been closed by other PRs — the repo now has 166 passing
tests, `FakeSpacesReading` exists, and `SpaceService`/`SpaceStore`/`DesktopShortcuts` are
all tested. Two items remained:

1. No `.github/` directory at all — no CI on a repo about to go public as a source-only
   0.1 release, whose whole pitch is engineering care.
2. `Sources/SpacewalkerApp/SwitchHUD.swift` (~207 lines) — the trickiest async code in the
   app, carrying ~20 lines of its own commentary explaining an easy-to-get-wrong
   generation-token invariant — completely untested.

## Task

### 1. GitHub Actions workflow

Create `.github/workflows/ci.yml`:
- Triggers: pull requests to `main`, pushes to `main`.
- macOS runner, with the runner image and Xcode version chosen deliberately —
  `Package.swift` declares `swift-tools-version:6.0` (needs Xcode 16+); check what
  `macos-14`/`macos-15` runners actually default to rather than assuming.
- Steps: `swift build`, `swift test`, `xcrun swift-format lint -r Sources Tests`.
- Audit every test target for anything touching live system state
  (`CGSCopyManagedDisplaySpaces`, `NSScreen`, `CFPreferences` writes, `killall Dock`,
  `NSAppleScript`, AX APIs) before claiming the whole suite runs headless. Gate or scope
  out anything that can't actually pass on a runner with no display, no Accessibility
  grant, and no logged-in GUI session — and say so explicitly, in the workflow and the PR
  body. A green badge that silently skips the interesting tests is worse than an honest
  partial one.
- Cache `.build` keyed on `Package.swift`/`Package.resolved` if straightforward.
- Add a CI badge to `README.md` only if the workflow genuinely covers build + tests.

### 2. SwitchHUD state machine tests

Read `SwitchHUD.swift` and its doc comments carefully. Prior knowledge not to rediscover
or "fix":
- `hideWork?.cancel()` only stops a *pending* fade. Once `panel.animator().alphaValue` is
  in flight, cancelling is a no-op, and assigning `alphaValue` directly does not stop it —
  the animator keeps interpolating and fades new content back out. The code supersedes
  with a zero-duration animation group on the same property and gates fade completion
  handlers on a generation token. Test that this invariant holds.
- Target sequence to cover: flash -> failure -> clear.
- If the state machine isn't testable without refactoring, extract the pure decision logic
  (what should be shown; whether a completion handler is stale per its generation token)
  into testable functions, leaving the AppKit animation calls as a thin shell — the same
  shape PR #59 used for QuickSwitcher geometry. Do not restructure the animation behavior
  itself.
- Deterministic tests only — no real sleeps racing wall-clock.

## Audit result (what actually runs in CI)

Every existing test file was read end to end. All of them drive fixtures, fakes
(`FakeSpacesReading`, `FakeKeySynth`, `DeferredScheduler`, `MockURLProtocol`), or hand-built
`AXNode`/`AXValue` trees — none call a live `CGS*` symbol, write real `CFPreferences`, spawn
real `osascript`/`NSAppleScript`, run `killall Dock`, or require a granted Accessibility/
Automation permission. `swift test` runs the whole suite unmodified on the CI runner; the
workflow's `Test` step doc comment says so explicitly rather than silently.

## Fix

- [x] `.github/workflows/ci.yml`: PR-to-`main` + push-to-`main` triggers, `macos-15`
      runner, `maxim-lobanov/setup-xcode` pinned to Xcode 16.2 (explicit — the macos-14
      default is Xcode 15.4, too old for `swift-tools-version:6.0`, and the macos-15
      default has already moved past 16.x), `.build` cache keyed on
      `Package.swift`/`Package.resolved`, `swift build` / `swift test` / `swift-format
      lint` steps.
- [x] CI badge added to `README.md`.
- [x] Extracted `SwitchHUDTiming` (rapid-succession debounce threshold, clear-request
      staleness) and `FadeGenerationTracker` (fade generation token) into
      `Sources/SpacewalkerApp/SwitchHUDTiming.swift` — pure, no AppKit dependency.
      `SwitchHUD.swift` now delegates to them instead of inlining the comparisons; the
      animation/AppKit calls themselves are untouched.
- [x] `Tests/SpacewalkerAppTests/SwitchHUDTimingTests.swift`: 11 new tests covering the
      rapid-succession threshold boundary, `clearIfStale`'s staleness check, the
      generation-token invariant (`FadeGenerationTrackerTests`), and the explicit
      flash -> failure -> clear sequence from the issue.

## Deviations

None from the injected task. `SwitchHUD` itself (the `NSPanel`/`NSAnimationContext` shell)
remains untested by design, per the "thin shell" instruction — its real animation timing
is wall-clock-based and not worth making deterministic at the cost of a live-window
dependency in CI.
