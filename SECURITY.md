# Security Policy

## Why this file exists

Spacewalker asks macOS for **Accessibility** trust and **Automation** (Apple
Events) access. Accessibility is one of the most powerful permissions a Mac app
can hold: it allows synthesizing input and reading UI content across every
running application. An app that asks for it owes you a specific account of what
it does with it — not a reassuring paragraph — and a private channel for
reporting problems.

So this file names every call site. Links go to the file on `main`; the quoted
snippets are the real code.

## Summary

| Permission | Why it's needed | Where |
|---|---|---|
| **Accessibility** | Posting the Space-switch shortcuts through System Events | [`KeySynth.swift`](Sources/SpaceSwitching/KeySynth.swift) |
| **Accessibility** | A listen-only `keyDown` tap, to notice ⌃←/⌃→/⌃1–9 pressed outside the app | [`SwitchKeyTap.swift`](Sources/SpacewalkerApp/SwitchKeyTap.swift) |
| **Accessibility** | Reading the Dock's accessibility tree to find Mission Control's thumbnails | [`AXUtil.swift`](Sources/SpacewalkerApp/AXUtil.swift), [`MissionControlOverlay.swift`](Sources/SpacewalkerApp/MissionControlOverlay.swift) |
| **Automation** (System Events) | Delivering the shortcut keystrokes — the only path macOS honors | [`KeySynth.swift`](Sources/SpaceSwitching/KeySynth.swift) |

There are exactly three uses of the Accessibility grant. Each is below.

---

## 1. Switching Spaces

macOS has no public API for switching Spaces, and it *filters* synthetic
`CGEvent`s for this specific purpose — posting ⌃← to the HID or session tap
does nothing at all (measured; see [PLAN.md](PLAN.md) §1). The only route the
system honors is an Apple Event to System Events, which requires both
Accessibility trust and Automation consent.

That's why the app can't do this the boring way.
[`KeySynth`](Sources/SpaceSwitching/KeySynth.swift) is the whole surface:

```swift
public init() {
  // key code 123 = Left arrow, 124 = Right arrow; Ctrl+arrow = "Move left/right a space".
  leftScript = NSAppleScript(
    source: #"tell application "System Events" to key code 123 using control down"#)!
  rightScript = NSAppleScript(
    source: #"tell application "System Events" to key code 124 using control down"#)!
```

Direct ⌃1–9 jumps compile the same one-line script with a different key code.
Every Apple Event the app will ever send goes through a single method,
`KeySynth.run(_:)` — nothing else in the codebase talks to System Events, and
the app never sends Apple Events to any other target.

The trust check is also there:

```swift
/// True once the process holds Accessibility trust (required for System Events to post keys).
public static var hasAccessibility: Bool { AXIsProcessTrusted() }
```

The Automation prompt you see comes from this string in
[`App/Info.plist`](App/Info.plist):

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Spacewalker switches Spaces by sending the ⌃← / ⌃→ shortcut through System Events.</string>
```

and the matching entitlement in
[`App/Spacewalker.entitlements`](App/Spacewalker.entitlements) —
`com.apple.security.automation.apple-events`, which is mandatory under the
hardened runtime the release build uses.

## 2. The keyboard tap

This is the most invasive thing Spacewalker does, so here it is in full.

A listen-only `CGEventTap` is installed at launch and stays live for the app's
entire lifetime ([`SwitchKeyTap.install()`](Sources/SpacewalkerApp/SwitchKeyTap.swift)):

```swift
let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

guard
  let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: Self.callback,
    userInfo: selfPtr)
```

**Why it exists.** ⌃←/⌃→/⌃1–9 are *symbolic hotkeys*: the WindowServer
intercepts them upstream of Cocoa's event dispatch, so
`NSEvent.addGlobalMonitorForEvents` never sees them. A tap is the only way to
notice that you switched Spaces by keyboard rather than through Spacewalker,
which is what lets the app clear a stale name from the HUD immediately instead
of waiting for the slower Space-change poll.

**What it reads.** Three fields, and only from `keyDown`:

```swift
let hasControl = event.flags.contains(.maskControl)
let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
```

The consumer then discards even those unless the key code is one of the nine
Space-switch keys. No key content is read, logged, or written to disk anywhere.

**What it cannot do.** The tap is `.listenOnly`, so the WindowServer will not
accept a modified or swallowed event from it. Both return paths hand the event
straight back:

```swift
// Listen-only: always hand the event back unmodified.
return Unmanaged.passUnretained(event)
```

There is no `return nil` and no mutation of `event` anywhere in the file.

**Turning it off.** There's no separate toggle today — revoking Accessibility
trust disables the tap along with Space switching itself. A preference to
disable HUD-blanking independently doesn't exist yet.

## 3. Reading the Dock for the Mission Control overlay

Painting names onto Mission Control's thumbnails means finding those thumbnails,
and the only way to do that is to read the Dock process's accessibility tree
cross-process ([`AXUtil`](Sources/SpacewalkerApp/AXUtil.swift)):

```swift
static func string(_ element: AXUIElement, _ attribute: String) -> String? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
  else { return nil }
  return value as? String
}
```

**Scope.** Only the Dock (`AXUIElementCreateApplication(dockPID)`) — no other
process is inspected. Per element it reads five attributes and nothing else:
role, title, identifier, position, size. The walk is depth-capped.

**Frequency.** This polls for the app's entire lifetime: every 1.0s while idle,
every 0.15s while Mission Control is open
([`MissionControlOverlay`](Sources/SpacewalkerApp/MissionControlOverlay.swift)).
There is no cheaper way to notice Mission Control opening without an
`AXObserver`.

**Worth knowing:** because Mission Control's thumbnails are UI elements, the
titles read during this walk can include the titles of your open windows. Those
strings are used in-memory for row matching and are never persisted and never
logged — the overlay has no logging calls at all. But it is a real read of
on-screen content, and it would be dishonest to describe this grant as
"switching only."

---

## What Spacewalker does not do

- **No input synthesis outside the switch shortcuts.** The app never posts a
  `CGEvent` and never moves the cursor. (`scripts/dump-mc-ax.swift`, a
  developer-only script, does both — `make-app.sh` never copies it into the
  bundle.)
- **No telemetry, analytics, or identifiers.** None, anywhere.
- **No reading of other apps' content** beyond the bounded Dock walk above.
- **No auto-update.** Nothing downloads or executes itself.

## Network

One request, ever. An unauthenticated `GET` for the update check
([`UpdateChecker.swift`](Sources/SpacewalkerApp/UpdateChecker.swift)):

```swift
static let releasesEndpoint = URL(
  string: "https://api.github.com/repos/blsmth/spacewalker/releases/latest")!
static let minimumCheckInterval: TimeInterval = 24 * 60 * 60
```

At most once per launch, throttled to once per 24 hours, plus whenever you click
**Check for Updates…**. No headers, no auth, no identifiers are attached; GitHub
sees an ordinary anonymous API request. Nothing else in the app touches the
network, and the app is fully functional offline.

> Earlier versions of this file claimed Spacewalker had no network code at all.
> That stopped being true when the update check landed, and the claim is
> corrected here.

## System settings it can change

With your explicit consent, Spacewalker writes three things — worth disclosing
because they alter system state outside the app:

| Domain | Key | Change |
|---|---|---|
| `com.apple.symbolichotkeys` | ids 118–126 | Bind ⌃1…⌃9 to "Switch to Desktop 1–9" |
| `com.apple.symbolichotkeys` | ids 79 / 81 | Bind ⌃←/⌃→ to "Move left/right a space" |
| `com.apple.dock` | `mru-spaces` | Set to `false` (stop auto-rearranging Spaces) |

Applying these restarts the Dock (`/usr/bin/killall Dock`) and runs
`activateSettings -u`; both are bounded by a timeout. The consent prompt is
shown once, only if something actually needs changing, and is remembered.
Shortcuts you've deliberately rebound are never clobbered — they're reported as
conflicts and left alone. The pre-existing values are snapshotted before the
first write, and **Restore System Settings…** in the menu puts them back
(including removing keys that didn't exist before). See
[`SystemPrefsCoordinator.swift`](Sources/SpaceSwitching/SystemPrefsCoordinator.swift)
and [`SystemPrefsBackup.swift`](Sources/SpaceSwitching/SystemPrefsBackup.swift).

## Data on disk

Everything lives in `~/Library/Application Support/Spacewalker/`:

| File | Contents |
|---|---|
| `spaces.json` | Your Space names, symbol names, and color hexes |
| `spaces.backup.json` | Previous revision of the above |
| `system-prefs-backup.plist` | Pre-Spacewalker values of the settings above |

Written atomically with default file permissions — no explicit POSIX mode or
data-protection class is set, so these inherit your umask. Nothing is
encrypted, because nothing here is a secret; if you consider your Space names
sensitive, note that they are plain text.

**Copy Diagnostics** puts a snapshot on your clipboard for pasting into a public
issue. It deliberately excludes Space names, symbol and color choices, window
titles, usernames, and absolute paths, with a regex scrub as a second layer.
See [`DiagnosticsFormatter.swift`](Sources/SpacewalkerApp/DiagnosticsFormatter.swift)
and [`DiagnosticsRedactor.swift`](Sources/SpacewalkerApp/DiagnosticsRedactor.swift).
Diagnostics never touch disk.

---

## Supported versions

Spacewalker is pre-1.0. Only the latest release receives security fixes.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it through
[GitHub private vulnerability reporting](https://github.com/blsmth/spacewalker/security/advisories/new),
which notifies the maintainer privately.

Please include the affected version, your macOS version, what an attacker could
achieve, and reproduction steps if you have them.

You can expect an acknowledgement within 7 days. Because this is a personal
project maintained in spare time, please allow up to 90 days for a fix before
public disclosure — and get in touch if that timeline doesn't work for your
situation.

## Scope

Reports in these areas are especially welcome:

- Ways another local process could inherit or abuse Spacewalker's Accessibility
  or Automation grants
- Weaknesses in the code-signing and distribution pipeline (`scripts/`)
- Data written to disk that is more readable than it should be
- Anything that makes Spacewalker modify system state you didn't agree to
- Anything in the Dock accessibility walk that reads more than described above

Known-weak areas are already tracked publicly under the
[`area:security`](https://github.com/blsmth/spacewalker/issues?q=is%3Aissue+label%3Aarea%3Asecurity)
label. Those aren't undisclosed vulnerabilities — they're open work items on a
pre-release project.
