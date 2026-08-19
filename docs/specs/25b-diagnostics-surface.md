# Spacewalker #25 PR-B — user-facing diagnostics surface

Issue: https://github.com/blsmth/spacewalker/issues/25 (PART B OF TWO)
Base: main (PR-A merged as 8b788f4). Branch: feat/diagnostics-surface
Builds directly on PR-A, which landed the logging foundation:
`Logger(subsystem: "app.spacewalker", category: "<Module>")` in each of the five
targets, via a `Logging.swift` per module. That subsystem is your harvesting surface.

## Scope — the three remaining #25 checkboxes
1. **"Copy Diagnostics" menu item** — dumps OS version, app version+build, symbol
   availability, permission states, display topology, and recent log entries to the
   clipboard.
2. **About item** — shows version + build. Currently `CFBundleShortVersionString`
   (0.1.0) lives only in `App/Info.plist:16` and is surfaced nowhere in the UI.
3. **Uncaught-exception handler** — writes a breadcrumb before dying.

The app is `LSUIElement` (menu-bar only), so both menu items belong in the
`NSStatusItem` menu built in `AppDelegate` (see the existing menu construction around
`AppDelegate.swift:178-250`).

## THE CRITICAL DESIGN CONSTRAINT — read before writing any code
The entire purpose of "Copy Diagnostics" is that a user pastes the result into a
**public GitHub issue**. Therefore the output must be safe to paste in public.

- **MUST NOT include:** Space names, custom symbol/colour choices, window titles,
  usernames, home-directory paths, or full filesystem paths.
- **MUST include:** macOS version + build, app version + build, CPU architecture,
  which of the three CGS symbols resolved (`CGSMainConnectionID`,
  `CGSCopyManagedDisplaySpaces`, `CGSGetActiveSpace`), Accessibility trust state,
  display count and per-display Space *counts*, and whether the symbolic-hotkey
  bindings are present.
- Paths, if genuinely needed, must be abbreviated (`~/Library/...`) — never absolute.
- Space **counts** are fine; Space **names** are not.

Note the tension with PR-A: its `os.Logger` calls deliberately mark paths and errors
`.private`, so they render as `<private>` when read back. Do not defeat that by
re-reading logs and pasting raw values. If a redacted entry is useless in the dump,
omit the entry rather than un-redacting it.

## Recent log entries — verify before relying on it
Use `OSLogStore` (macOS 12+; the package targets macOS 13, so it is available) scoped
to the current process, filtered to `subsystem == "app.spacewalker"`.
`OSLogStore` access can fail at runtime depending on entitlements and hardened-runtime
configuration. **Verify it actually returns entries in this app's signed configuration**
(`scripts/make-app.sh` builds with hardened runtime). If it does not work, say so
explicitly in the PR and fall back to including the exact `log show` / `log stream`
command the user can run instead — do not ship a section that silently returns empty.

## Uncaught-exception handler — be honest about what it does NOT catch
`NSSetUncaughtExceptionHandler` catches **Objective-C** exceptions only. It does **not**
catch Swift runtime traps — `fatalError`, force-unwrap of nil, array out-of-bounds, or
the force-cast class of bug that issue #21 just fixed (merged as 407d6e0). Since
private-API breakage is the failure mode this app most fears, and that class of failure
is largely Swift traps, the handler is a narrow win.

Therefore:
- Implement it, but do **not** describe it as "crash reporting" in code comments, the
  menu, or the PR body. It is a breadcrumb for one specific class of failure.
- The breadcrumb must be written with a **signal-safe-ish, minimal** code path — an
  exception handler is not a good place for heavy work. Log via the existing
  `os.Logger` and, if you persist anything, keep it to one small append.
- State the ObjC-only limitation plainly in the PR body.

## Constraints
- No third-party dependencies. `import os` / AppKit / Foundation only. No PLCrashReporter.
- No behaviour change to switching, the overlay, or the store.
- Reuse PR-A's per-module `log` — do not introduce a second logging mechanism.
- `swift build` and `swift test` must pass. Run `xcrun swift-format lint -r Sources Tests`.
- Follow repo convention: archive your spec to `docs/specs/25b-<slug>.md` with a
  `## Deviations` section (see `docs/specs/25a-os-logger-foundation.md`).

## Tests
Test what is testable without a live WindowServer: the diagnostics *formatting* function
should be a pure function over an injected snapshot struct, so you can assert that a
snapshot containing a Space name or an absolute path never appears in the rendered
output. That redaction test is the most valuable test in this PR — write it.

## Deliverable
Branch, commit (imperative mood), push, open PR against main with a Test Plan.
Include in the PR body: a **verbatim sample of the diagnostics output** (from your own
machine, with anything genuinely sensitive replaced by a clearly-marked placeholder), so
the redaction policy can be reviewed by reading it rather than by reading the code.
Never use `git add -A` or `git add .`. Do not amend existing commits.

## Deviations

- **`OSLogStore` verification (done, not assumed):** built a standalone Swift binary,
  signed it with the same `Spacewalker Dev` identity and `--options runtime` (hardened
  runtime) `scripts/make-app.sh` uses, and confirmed `OSLogStore(scope:
  .currentProcessIdentifier)` returns entries with no extra entitlement needed. Also
  confirmed a `.private`-annotated interpolation reads back as the literal string
  `<private>` even from the same process — this is what makes it safe to surface
  `os.Logger` output verbatim in the dump. Then verified end-to-end in the real signed
  `Spacewalker.app` bundle via UI-scripted clicks: a "Copy Diagnostics" run picked up the
  *previous* run's own `.notice`-level log line, and a later run picked up a real
  `Switch result: ok` entry — see the PR body for the exact transcript. One real finding:
  `.debug`-level entries (most of the app's routine logging) are not retained by the
  unified log by default, so "Copy Diagnostics" run immediately after a quiet launch can
  legitimately show "(none captured)" — this is expected, not a bug, and is why the
  fallback command is always shown as a footer regardless of whether entries were found.
- **Symbol availability plumbing:** added a small public `SkyLightSymbolAvailability`
  struct to `CGSPrivate` (`SymbolAvailability.swift`) exposing the three booleans the
  spec asks for. `SkyLightSymbols` itself stays `internal` and untouched — nothing above
  `CGSPrivate` gained access to a raw symbol pointer.
- **Redaction is a two-layer design, not one regex trying to do everything:**
  1. `DiagnosticsSnapshot`'s fields are all counts/booleans/short version strings by
     construction — there is no field typed to hold a Space name, custom symbol/color,
     window title, or username. A `Mirror`-based test
     (`testSnapshotHasNoUndocumentedStringField`) acts as a tripwire against a future
     refactor quietly adding one.
  2. The one free-text field, `recentLogs`, is sourced from `OSLogStore`, whose
     `.private` annotations (verified above) already keep paths/errors out of what comes
     back. `DiagnosticsRedactor.redactPaths` is an additional backstop applied to every
     harvested line in `DiagnosticsFormatter.render` — it collapses `/Users/<name>/...`
     to `~/...` and masks any other absolute path with `<path>`, and is proven not to
     touch non-path slashes ("and/or", "1/2") or to re-expand an already-redacted
     `<private>` marker.
  - Explicitly **not** implemented: a generic "strip anything that looks like a quoted
    user string" pass, considered as a way to also catch a hypothetical leaked Space
    name in free text. Rejected because real AppleScript error messages this app already
    logs `.public` (e.g. `Can't get application "System Events".`) legitimately contain
    quoted text, and a blanket quote-strip would reduce their diagnostic value for a risk
    that (per the grep in the PR body) doesn't currently exist: no log call site in the
    codebase interpolates a Space name at all.
- **Log-harvest window/cap:** last 15 minutes, capped to the 40 most recent entries, to
  keep a pasted dump bounded — not specified in the issue, chosen as a reasonable default.
- **Failure reason string:** `LogHarvest.unavailable(reason:)` is always populated with a
  fixed, developer-authored literal (`"log store access failed on this build"`), never
  the caught `Error`'s own description, so a future `OSLogStore` failure mode can't smuggle
  arbitrary text into the dump via its error message.
