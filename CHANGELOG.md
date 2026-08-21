# Changelog

All notable changes to Spacewalker are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project intends to follow
[Semantic Versioning](https://semver.org/) once tagged releases begin.

## [0.1.0] - 2026-08-21

Initial public release. **Source-only** — there is no prebuilt download for this tag. Building it
yourself needs a Swift 6 toolchain; see the README. A signed, notarized binary needs a Developer ID
certificate, which this release does not have.

### Added

- Name, icon-, and color-tag every Space; the current Space's name lives in the menu bar.
- Quick Switcher (⌘0): fuzzy-search and jump to any Space, with a Jump Back row for the
  previous/current pair.
- Direct ⌃1…⌃9 desktop jumps and ⌃←/⌃→ walks, both routed through the same switch-result handling
  so every failure (permissions, a Space that no longer exists, a switch that silently didn't take)
  surfaces real feedback instead of failing silently.
- Space names painted directly onto Mission Control's thumbnails.
- An instant heads-up display (HUD) flash on every switch, app-initiated or external.
- First-run onboarding for Accessibility/Automation permissions and a ⌘0-conflict alert, with a
  background watcher that self-heals once permission is granted.
- Optional, consent-gated management of the system's ⌃1…⌃9 / move-space keyboard shortcuts and
  Mission Control's "automatically rearrange Spaces" setting, with backup/restore.
- "Copy Diagnostics" — a redaction-safe snapshot (no Space names, no absolute paths) for pasting
  into a public GitHub issue.
- Idle-aware polling: the active-Space watcher and Mission Control overlay both back off to a slow
  interval when nothing is happening, rather than polling at a fixed rate forever (#19).
- A lightweight update check against GitHub Releases (#32): at most once per launch, throttled to
  once per 24h, plus an on-demand "Check for Updates…" menu item. No auto-download, no
  auto-install — see the README's "Updates" section for why.
- A `SMAppService`-backed "Launch at Login" toggle in the menu (#32), replacing the manual
  Login Items instructions.
- Single-sourced app version/build reporting, used by both "About Spacewalker" and
  "Copy Diagnostics" (#32).
- An application icon, generated reproducibly from a committed script rather than checked in as an
  opaque binary, and applied to both the app bundle and the disk image (#58).
- Quick Switcher height clamping and scrolling, so the panel stays on screen and every row stays
  reachable with many Spaces (#29).
- Continuous integration: `swift build`, `swift test`, and `swift-format lint` on every pull
  request, running the whole suite with nothing skipped (#27).
- `scripts/dump-mc-ax.swift` — dumps Mission Control's accessibility tree, which is how several
  otherwise-unverifiable layout assumptions in this release were turned into measurements.

### Known limitations

- **Multi-display support is incomplete and largely unverified.** Switching across displays is not
  supported, and direct ⌃1…⌃9 jumps are disabled entirely whenever more than one display is
  attached, falling back to the slower ⌃←/⌃→ walk. A narrower same-display gate was written and then
  deliberately reverted: its safety precondition turned out not to hold, and the failure mode would
  have been silently switching the wrong display's Space (#23).
- The Mission Control overlay now creates one window per attached screen rather than covering only
  the primary display, but **this has never been exercised on real multi-display hardware** — it was
  developed and tested on a single display. Whether Mission Control renders a separate Spaces Bar per
  display is still an open question (#23).
- Spaces occupied by a fullscreen app are excluded from the internal index but still appear as
  Mission Control thumbnails, so with a fullscreen app open the overlay can attach names to the
  wrong thumbnails (#65).
- `SpaceStore` never removes entries, so metadata for deleted Spaces accumulates with no expiry and
  no UI to review or clear it (#33).
- No auto-update. See the README.
- Developed and verified on macOS 15 (Apple Silicon). The package targets macOS 13+, but macOS 13,
  macOS 14, and Intel Macs are untested.
