# Spacewalker #32 PART A — version, update check, changelog, disclosure (APP SIDE)

Issue: https://github.com/blsmth/spacewalker/issues/32 (PART A OF TWO)
Base: main @ f8e2744. Branch: feat/version-and-update-check

## Decision already made — do not revisit
Brendan chose the **lightweight version check**, NOT Sparkle, for 0.1.
Do not add Sparkle. Do not add any third-party dependency. Do not write any
self-updating, auto-downloading, or auto-installing code path. The goal is the ability
to *reach* a stranded user, not to update them automatically.

Rationale, so you build the right thing: this app depends on private APIs Apple can
break in a point release. When macOS 16 breaks switching, users on an old build need to
find out. A version check that links to the Releases page achieves that with ~100 lines
and no key management. An auto-updater would add a signing keypair, an appcast to host,
and a self-modifying binary to an app that already carries enough risk.

## Scope — PART A (app side) only
1. **Single-source the version.** It is currently read in two places:
   `Sources/SpacewalkerApp/DiagnosticsCollector.swift:31-32` and
   `Sources/SpacewalkerApp/AppDelegate.swift:497-498`. Consolidate into one helper and
   have both call sites use it. #32 is the versioning issue, so this belongs here.
2. **Lightweight update check** — see requirements below.
3. **`SMAppService` login-item toggle** in the status menu (PLAN §5; README currently
   tells users to do it by hand).
4. **CHANGELOG.md** — start it, `0.1.0` as the first entry. Keep a Changelog format.
5. **README disclosure** — plainly state there is no auto-update, and state the
   multi-display limitation (see #23). #32's checkbox 5 asks for exactly this.

OUT of scope — PART B owns these, do not touch:
  `scripts/make-app.sh`, DMG packaging, GitHub Release artifacts, notarization,
  `docs/RELEASING.md`, anything under `.github/`.

## DO NOT TOUCH
- **`PLAN.md`** — it is in flight on an unmerged branch (`docs/plan-as-built`, PR #51).
  Editing it here creates a conflict. PLAN's Sparkle claims are already being handled
  there. Note in your PR body that PLAN §6's Sparkle mention will need a follow-up now
  that we've chosen a version check instead — but do not make that edit.
- `scripts/`, `.github/`, `App/Info.plist` version bumping (0.1.0 stays 0.1.0 here).

## Update-check requirements
- Endpoint: `https://api.github.com/repos/blsmth/spacewalker/releases/latest`.
  Unauthenticated. No telemetry, no analytics, no identifiers sent — a plain GET.
- **Respect the idle work already won.** PR #47 / issue #19 specifically gated this app's
  always-on timers so it can go idle. Do NOT add a recurring network poll that undoes
  that. Check at most once per launch, and no more than once per 24h (persist the last
  check time). A manual "Check for Updates…" menu item should always work on demand.
- **Fail silently and completely offline.** No network is the normal case for a menu-bar
  app on a laptop. No alert, no error dialog, no repeated retry on failure. Log via the
  existing `os.Logger` (`log` in `SpacewalkerApp`) and move on.
- **Version comparison must be correct**, not string comparison. `0.10.0` is newer than
  `0.9.0`; `0.1.0` is not newer than `0.1.0`. Handle a malformed or missing tag from the
  API without crashing. Write unit tests for the comparator — it is a pure function and
  is the easiest thing here to get subtly wrong.
- Never auto-open a browser. Surface a menu item the user chooses to click.

## `SMAppService` notes
- macOS 13+ only, which matches `Package.swift`'s `.macOS(.v13)` — no availability
  shim needed, but confirm.
- The toggle must reflect *actual* current status (`SMAppService.mainApp.status`), not a
  cached bool, so it stays correct if the user changes it in System Settings.
- Registration can throw; handle failure without crashing and log it.
- This only works from a properly bundled `.app`, not a bare `swift run` binary. Say so
  in the PR if you cannot fully exercise it.

## Constraints
- `swift build`, `swift test` pass. `xcrun swift-format lint -r Sources Tests` clean.
- Reuse the per-module `log` from `Sources/SpacewalkerApp/Logging.swift`. No new logging
  mechanism.
- Menu additions go in the existing construction around `AppDelegate.swift:242-276`.
- Archive your spec to `docs/specs/32a-<slug>.md` with a `## Deviations` section.

## Deliverable
Branch, commit (imperative mood), push, open PR against main with a Test Plan.
NOTE: this environment's shell wrapper mangles backticks in inline arguments — write the
PR body to a file and use `--body-file`.
Never use `git add -A` or `git add .`.

## Deviations

- **`parseRelease` on `UpdateChecker` is `internal`, not `private`.** Needed so
  `UpdateCheckerTests` can exercise malformed/missing-field GitHub responses directly as a
  pure-function table, rather than only indirectly through a full mocked-network round
  trip for every case. It is not part of any public API surface (the target is an
  executable, not a library product).
- **`UpdateChecker` takes an injectable `UserDefaults`, not just `URLSession`.** The spec
  only mentioned making the network layer testable; the 24h throttle is itself pure logic
  worth testing directly, and testing it against `UserDefaults.standard` would either
  pollute a developer's real preferences or make the test order-dependent. Each test gets
  its own throwaway suite, torn down afterward.
- **Manual "Check for Updates…" flashes a HUD message when it *finds* something new**, via
  `UpdateChecker.onUpdateFound`, using the existing `SwitchHUD.flashMessage` mechanism (the
  same non-modal HUD the rest of the app already uses for "Diagnostics copied…" etc.). Not
  explicitly requested, but the "on-demand check" requirement is otherwise silent about
  what a user who clicks it should see if there genuinely is an update — a HUD flash
  reuses an existing, already-idle-safe UI primitive rather than inventing an alert (which
  the "no alert" requirement is about the failure path, not a successful find).
- **README's "Launch it automatically at login" section was updated** in place (not just
  appended-to) to describe the new toggle, since the old text explicitly said "no built-in
  toggle yet" — leaving that sentence in place after adding the toggle would have been
  wrong, not merely incomplete. This is a feature-description edit, not a
  release/packaging edit, so it stays in scope for this PR.
- **`SMAppService` could not be exercised against a live launchd** in this environment: it
  requires a properly bundled, code-signed `.app` (see `scripts/make-app.sh`, owned by the
  parallel PART B agent) rather than a bare `swift build`/`swift run` binary, which has no
  bundle identifier for `SMAppService` to register. Verified instead: `swift build`
  succeeds, the throwing paths are exercised by hand-inspection (both `register()` and
  `unregister()` are wrapped in `do { } catch` and log rather than crash), and
  `SMAppService.mainApp.status` is read fresh on every call rather than cached, per the
  spec. Flagging this the same way the spec asked to.
- **PLAN.md was intentionally left untouched**, per the "DO NOT TOUCH" instruction. §6 still
  claims a Sparkle appcast; now that this PR establishes the lightweight-version-check
  approach instead, that section needs a follow-up edit once `docs/plan-as-built` (PR #51)
  merges. Flagged in the PR body rather than fixed here to avoid a conflict with that
  in-flight branch.
