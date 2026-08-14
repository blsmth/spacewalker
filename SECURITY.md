# Security Policy

## Why this file exists

Spacewalker requests **Accessibility** trust from macOS. That is one of the most
powerful permissions a Mac app can hold — it allows synthetic input and reading
UI content across every running application. An app that asks for it owes users
a clear disclosure of what it does with it, and a private channel for reporting
problems.

## What Spacewalker does with its permissions

| Permission | Used for |
|---|---|
| **Accessibility** | Synthesizing the ⌃←/⌃→/⌃1–9 Space-switch shortcuts, and a **listen-only** keyDown event tap used solely to blank a stale name from the switch HUD. |
| **Automation (System Events)** | Delivering those same shortcuts via AppleScript. macOS filters natively synthesized `CGEvent`s for Space switching, so this is the only path the system honors. |

The keyboard event tap is created with `.listenOnly` and returns every event
unmodified. It reads only the Control modifier flag, the virtual key code, and
the event timestamp. No keystroke content is read, logged, or written to disk.
See `Sources/SpacewalkerApp/SwitchKeyTap.swift`.

Spacewalker has no network code. It makes no outbound connections, and it
collects no telemetry or analytics of any kind.

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
public disclosure, and get in touch if that timeline does not work for your
situation.

## Scope

Particularly interested in reports covering:

- Ways another local process could inherit or abuse Spacewalker's Accessibility
  or Automation grants
- Weaknesses in the code-signing and distribution pipeline (`scripts/`)
- Data written to disk that is more readable than it should be
- Anything that causes Spacewalker to modify system state a user did not agree to

Known-weak areas are already tracked publicly in the issue tracker under the
`area:security` label. Those are not undisclosed vulnerabilities — they are open
work items on a pre-release project that has not yet been distributed.
