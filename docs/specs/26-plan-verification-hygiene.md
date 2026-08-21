# Spacewalker #26 — PLAN.md verification-claim hygiene

Issue: https://github.com/blsmth/spacewalker/issues/26
PR: https://github.com/blsmth/spacewalker/pull/51 (`docs/plan-as-built`)
Base at start of this pass: `docs/plan-as-built` @ cbb7a1c, rebased onto `main` @ 298a31b.

## Problem

PR #51 fixed the *factual* divergences between PLAN.md and the code (targets, symbol
counts, metadata shape, etc.) but deliberately left a "Bucket 4" of ~17 **verification**
claims untouched — things PLAN.md asserts were checked live ("confirmed live", "verified
present on this machine", specific timings, spike-era observations) with no test, log, or
benchmark backing them, and in several cases stale line-number citations pointing at code
that had moved since PR #51 was opened.

Brendan's brief: re-run and confirm what's cheap to confirm; keep what passes; requalify
honestly (not delete) what can't be safely re-run. Also finish PR #51's own remaining
work — rebase, re-verify its existing correction table against current `main`, rewrite the
PR description.

## What was done

1. **Rebase.** `git rebase origin/main` was clean (no conflicts) — `main` had moved from
   914b31c to 298a31b (icon, CI, Quick Switcher scrolling) without touching PLAN.md.
2. **Re-verified PR #51's existing correction table** against current source. Several of
   its own citations had already drifted again post-rebase (file line numbers shift as
   other PRs land) and needed a second correction pass — see the file-by-file citation
   fixes throughout PLAN.md's diff.
3. **Applied the four corrections already made to issue #26** (do not re-fix, just make
   sure PLAN.md reflects them): `SMAppService` login item is built (§5), Sparkle is a
   non-goal not a plan (§1/§5/§6), the capability probe checks all three symbols plus
   `TopologyValidator` shape validation (§7), and the `CGSGetActiveSpace` ground-truth
   switch verification is a shipped, tested feature (§4.2).
4. **Bucket 4, claim by claim** — see PLAN.md's own new top-of-file legend
   (`[confirmed in source/tests: ...]` / `[measured <date>]` /
   `[historical, not re-verified since ...]`). Live probes actually run on this machine
   (macOS 15.0.1, arm64, SIP on, 2026-08-20), each read-only or immediately reversible:
   - `CGSGetActiveSpace` via `dlsym`, before/after posting a properly-sequenced
     `CGEventPost` Control+Right-arrow sequence to both `.cghidEventTap` and
     `.cgSessionEventTap` — active Space's `id64` unchanged (`8` → `8`), reconfirming the
     "CGEvent does not switch Spaces" spike finding on current macOS. No permission
     needed, nothing moved.
   - `CGSCopyManagedDisplaySpaces` via `dlsym` — this machine's live topology still has
     exactly one Space with an empty `uuid` (`managed=1, id64=1`), reconfirming the §2
     empty-uuid spike finding.
   - `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys` — ids `79`/`81`
     (move-space) still `enabled = 1`; ids `118`–`126` (Switch to Desktop N) are *also*
     now `enabled = 1` on this machine, contradicting the spike-era "NOT present" claim.
     Traced (via `SystemPrefsConsent` being unset in this machine's `defaults`) to *not*
     be Spacewalker's own consent-gated writer — recorded as an honest machine-specific
     caveat, not a changed OS default.
   - An isolated `NSAppleScript` compile-once/execute-many timing loop (200 iterations, no
     cross-process Apple Event, so no Automation permission needed) to get a real number
     for the OSA dispatch overhead behind the unsupported "<50ms" claim: mean 0.0027ms.
     The full switch latency (Apple Event IPC + WindowServer handling) remains
     **unmeasured** — the "<50ms" figure is dropped rather than repeated unverified.
   - `swift test` — 193 tests, 5 test targets, confirming the task's stated baseline and
     correcting PLAN.md's stale "(81 passing tests)" M1 claim.
   - Read (never wrote) this machine's TCC database (`kTCCServiceAppleEvents`) to find
     `app.spacewalker.menubar` was granted Automation access to `com.apple.systemevents`
     on 2026-08-11 — real corroborating evidence the System-Events switch path has
     actually worked in practice on this OS build, cited as such rather than claimed as
     a fresh live re-run.
   - Read (never wrote) this machine's real `spaces.json` (8 custom-named Spaces) as
     corroborating, non-invasive evidence for the persistence-survives-relaunch claim,
     instead of forcing an actual reboot.
5. **What was deliberately *not* attempted live**, and why: triggering an actual
   System-Events-mediated Space switch or Mission-Control AX walk from a throwaway probe
   process, which would require granting that probe its own fresh, interactive macOS
   Automation/Accessibility permission — not completable non-interactively, and risks
   leaving an unresolved system consent dialog on screen. Also skipped: re-running the
   `CGSManagedDisplaySetCurrentSpace` "phantom" call, since it's documented to desync the
   WindowServer's internal current-Space pointer from what's on screen, and this machine
   has a real, in-use Spacewalker instance running against real Spaces — not worth the
   risk for a documentation check. Both are tagged `[historical, not re-verified]` with
   the reasoning inline, not silently dropped.

## Constraints honored

- Current Space was noted before any live probe (`id64 == 8`) and confirmed unchanged
  after every probe that touched the WindowServer.
- No system preference was written; every live check was a `defaults read`, a `dlsym`
  read-only call, or an in-process `NSAppleScript`/`CGEventPost` that provably didn't
  move anything (verified via before/after ground truth).
- Scratch probes lived in `/tmp/sw-probe/`, never committed.
- Only `PLAN.md` (and this spec file) were staged; no `git add -A`.

## Deviations

- **Added a spec file for #26** even though the task description came as direct
  instructions rather than an injected spec-store document, to match this repo's existing
  `docs/specs/<N>-<slug>.md` convention (see `docs/specs/24-capability-probe-shape.md` for
  precedent) and because PR #51 never added one for #26.
- **Fixed several PLAN.md line-number citations beyond the Bucket 4 list itself**
  (e.g. `SkyLightSymbols.swift` symbol declarations, `QuickSwitcher.swift`'s borderless
  panel setup, `MissionControlOverlay.swift`'s shielding level, `SpaceStore.swift`'s
  persistence helpers, `make-app.sh`'s signing/notarization steps). These weren't in
  Bucket 4's list, but PR #51 had already baked specific line numbers into PLAN.md's
  prose, and those had drifted again as later PRs landed — leaving them wrong would
  undercut the exact "citation hygiene" goal of this pass.
- **Corrected the §3 target-layout tree**: it claimed "5 targets + 3 test targets" and
  listed only 3 of the 5 test directories. `Tests/` actually has 5
  (`CGSPrivateTests`, `SpaceModelTests`, `SpaceSwitchingTests`, `SpaceServiceTests`,
  `SpacewalkerAppTests`) — not a Bucket 4 item, but a plain factual error found while
  re-verifying the surrounding table.
