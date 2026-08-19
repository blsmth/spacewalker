# Spacewalker #15 — session-wide keystroke tap: disclosure, scoping, soundness comment

Issue: https://github.com/blsmth/spacewalker/issues/15
Base: main @ 9e121cf. Branch: fix/keystroke-tap-disclosure

## Read the issue carefully — it credits the current implementation
`SwitchKeyTap` is implemented conservatively and **is not a keylogger**. The issue itself
verifies: `.listenOnly` (`:86`), mask restricted to `keyDown` only (`:78`), callback
returns the event unmodified on every path (`:139`), reads only the Control flag, keycode,
and timestamp (`:127-131`), and no keystroke content is read, logged, or persisted. The
disabled-by-timeout path (`reenable()`) is also correctly handled, which many
implementations get wrong.

**Do not regress any of those properties.** The concern is the *standing capability* and
the fact that it is undisclosed — not current behaviour.

## The three checkboxes are NOT equally sound. Read this before coding.

### Checkbox 2 — disclosure (REQUIRED, do this first)
The README does not mention an event tap at all. This is the most invasive use of the
Accessibility grant and it must be disclosed. `README.md` now has a "Known limitations"
section (added in #53) that already discloses the update check as the app's only network
request — put the tap disclosure alongside it, in the same plain register.

Say what it is, why it's needed (⌃←/⌃→/⌃1–9 are symbolic hotkeys the WindowServer
intercepts upstream of Cocoa, so `NSEvent.addGlobalMonitorForEvents` never sees them —
verified empirically, see the `SwitchKeyTap` doc comment), and — with equal prominence —
what it does *not* do: listen-only, keyDown only, never modifies or swallows events, reads
only the Control flag + keycode + timestamp, and no keystroke content is read, logged, or
stored. An honest disclosure includes the mitigations; a scary one that omits them is its
own kind of inaccuracy.

### Checkbox 3 — soundness comment (REQUIRED, trivial)
Add a comment at `:122`/`:132` noting `MainActor.assumeIsolated` is sound **only because**
the run-loop source is added to `CFRunLoopGetMain()` at `:98`. Verify that is still true
before writing the comment.

### Checkbox 1 — "enable the tap only while the HUD feature is active" (ANALYZE FIRST — likely unsound as written)
**Do not implement this naively.** The tap's whole purpose is to detect the user's own
⌃←/⌃→/⌃1–9 presses, in order to (a) clear a stale HUD via `clearIfStale(asOf:)` and
(b) arm SpaceService's fast poll via `noteExternalSwitchKeySeen()` (issue #19). Those
presses can happen at *any* moment the user is at the keyboard. There is no "HUD is
active" window to scope to — **the tap is precisely what tells you a switch happened.**
Disabling it "when idle" would disable the very mechanism that detects non-idle, silently
reintroducing the "stale name lingers, then settles" bug this tap was built to fix.

So: analyze it honestly and pick one, stating your reasoning in the PR body.
- If you find a scoping that genuinely reduces standing capability **without** breaking
  detection, implement it.
- If you conclude the literal checkbox is unsound, **say so plainly and do not implement
  it.** Propose the defensible alternative instead — most likely a user preference to turn
  the HUD feature off entirely, with the tap only installed when it is on, so a user who
  doesn't want a system-wide tap can decline it. Note whether that preference exists today
  (it does not) and scope it as a follow-up rather than building it here.

A correct "this cannot be done as specified, here is why, here is the alternative" is a
better outcome than a plausible gate that breaks HUD blanking. This project has already
been burned by confident-but-wrong claims; do not add one.

## Ownership — stay in your lane
Two sibling agents are working in parallel.
- **You own `README.md`** this batch.
- **Do NOT touch** `DiagnosticsSnapshot.swift` / `DiagnosticsFormatter.swift` (#24 owns),
  `MissionControlOverlay.swift` (#22 owns), `SpacesAPI.swift` / `SkyLightSymbols.swift`
  (#24 owns), or `PLAN.md` (in flight on unmerged PR #51).

## Constraints
- `swift build`, `swift test` pass; `xcrun swift-format lint -r Sources Tests` clean.
- Reuse the per-module `log` in `Sources/SpacewalkerApp/Logging.swift`.
- Do not add a dependency.

## Deliverable
Branch, commit (imperative mood), push, PR against main. Archive spec to
`docs/specs/15-<slug>.md` with `## Deviations`. Write the PR body to a file and use
`--body-file`. Never `git add -A`.

## Deviations

- **Checkbox 1 (enable-only-while-active) was not implemented — confirmed unsound as
  literally specified.** The tap's sole reason to exist is to notice a Space-switch
  shortcut *the instant it's pressed*, so the HUD can be blanked before the slower
  `CGSGetActiveSpace` poll catches up. That press is the only signal that the HUD (or the
  fast poll) should now be "active" — there is no independent, cheaper signal that could
  gate the tap without re-derivation via... the tap. Any "disable while idle" scoping would
  disable exactly the mechanism that detects the transition out of idle, silently
  reintroducing the "stale name lingers, then settles" bug the tap exists to fix. No
  alternative scoping was found that reduces standing capability without breaking
  detection: the mask is already the narrowest useful one (`keyDown` only), the tap is
  already only installed once Accessibility trust exists (no earlier point at which it
  could be delayed), and there is no "app active"/foreground window to key off of — this is
  a menu-bar (`LSUIElement`) app with no window, and the shortcuts fire while some *other*
  app is frontmost. The literal checkbox is unsound and was not implemented.

  **Proposed alternative (not built here):** a user preference to turn the HUD-blanking /
  fast-switch-detection feature off entirely, with `SwitchKeyTap` installed only when that
  preference is on. A user who doesn't want a standing system-wide tap could decline it and
  accept graceful degradation back to the pre-tap behavior (Space names update only from
  the slower poll). This preference does not exist today; scoping it is left as a follow-up
  issue, not attempted in this PR.

- **README wording**: the disclosure was placed as a third bullet in the existing "Known
  limitations" section, alongside the update-check disclosure it's modeled on, rather than
  a new top-level section — matching the "same plain register" instruction and keeping one
  place in the README for "things the app does that aren't obvious from the feature list."
