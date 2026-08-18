# Spacewalker #20 — bound the subprocess waits

Repo: blsmth/spacewalker. Worktree: ~/code/personal/.spacewalker-worktrees/subprocess

## READ THIS FIRST — the issue is partly stale

The issue says these run on the main thread during launch. That is NO LONGER TRUE and
was fixed in the consent PR. Verify before you change anything:

- `SpaceService.start()` no longer calls either helper at all — system preferences are
  only touched via `SystemPrefsCoordinator` behind explicit user consent.
- `DesktopShortcuts.reloadSettingsAsync` and `MissionControlPrefs.restartDockAsync`
  already run their `Process` work on `DispatchQueue.global(qos: .utility)` and hop
  back to the main actor for the completion.

So the launch-blocking problem is gone. Confirm this yourself and say so in the PR.

## What genuinely remains

There is still NO bounded timeout. `waitUntilExit()` on a utility queue no longer
freezes the UI, but if `killall Dock` or the private `activateSettings` helper ever
hangs, the completion handler is never called at all. The consent flow then waits
forever with no result, no error, and no way for the user to tell that anything went
wrong — a silent hang instead of a visible freeze.

Required:
- Bound both subprocess waits with a deadline (e.g. `terminationHandler` plus a
  timeout, or a `DispatchGroup.wait(timeout:)`), so completion ALWAYS fires exactly
  once — success, failure, or timed-out.
- Pick a defensible timeout and justify it. A Dock restart is normally fast but can be
  slow under memory pressure; too aggressive is its own bug.
- On timeout, decide deliberately whether to terminate the process or leave it and
  report failure, and explain the choice.
- Make sure the completion cannot be invoked twice (timeout firing and then the
  process exiting is a real race).

## Also update the issue

Post a comment on #20 noting which parts were already resolved by the consent work
and what this PR finishes, so the record is accurate.

## Scope boundary

Stay inside `Sources/SpaceSwitching/DesktopShortcuts.swift` and
`Sources/SpaceSwitching/MissionControlPrefs.swift`. Other agents are concurrently
editing `SpaceModel`, `AppDelegate.swift`, `SpaceService.swift`,
`MissionControlOverlay.swift` and `AXUtil.swift`. Do not touch those.

## Constraints (all mandatory)

- Swift 6 strict concurrency. `swift build -Xswiftc -strict-concurrency=complete 2>&1
  | grep -c "warning:"` MUST print 0.
- `swift test` must pass. 54 tests exist; none may break.
- `xcrun swift-format lint -r Sources Tests` clean for files you touch.
- House style: doc comments explain WHY. Read `Sources/SpaceSwitching/SystemPrefsBackup.swift`.
- Add a unit test for the "completion fires exactly once" invariant if you can do it
  without spawning real processes — introduce a seam if that is cheap and clean,
  otherwise explain why not.
- Do NOT run the Spacewalker app. Do NOT run `killall Dock`. Do NOT execute
  `activateSettings`. Do NOT modify any system preference domain.
- Stage only files you changed. NEVER `git add -A` or `git add .`.
- Commit in imperative mood explaining WHY. Reference "Fixes #20".
- Push the branch and open a DRAFT PR against main. Do NOT merge.

## Deviations / notes

None from the spec's requirements. Implementation notes:

- The bounded-wait primitive (`SingleResolution<Result>`) and the shared
  `DesktopShortcuts.runProcessBounded(_:timeout:completion:)` helper are declared in
  `DesktopShortcuts.swift` and used by `MissionControlPrefs.swift` too, rather than in
  a third shared file — the scope boundary above restricted changes to exactly these
  two files. This is called out explicitly in both files' doc comments, along with a
  note that a future refactor extracting a standalone `SubprocessRunner` type would be
  reasonable once the scope constraint no longer applies.
- Chose a 5s timeout for both `activateSettings -u` and `killall Dock`. Both are
  lightweight operations (a local IPC call and a signal-and-return, respectively) that
  normally complete in well under a second; 5s gives generous headroom for scheduling
  delays under memory pressure without leaving a user watching the consent dialog long
  enough to conclude the app has hung.
- On timeout, the process is sent SIGTERM. Both `killall` and `activateSettings` only
  send a signal or make a short IPC call — there's no in-flight work worth letting
  finish once we've decided to stop waiting, and an abandoned hung subprocess is worse
  than one we deliberately killed.
- `SingleResolution` is unit tested directly (four tests in
  `SingleResolutionTests.swift`) without spawning any real `Process` — it's a generic,
  `Process`-free primitive by design specifically so the "exactly once" race can be
  exercised with synthetic concurrent `resolve()` calls instead of real subprocess
  timing.
