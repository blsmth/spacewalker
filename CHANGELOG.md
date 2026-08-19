# Changelog

All notable changes to Spacewalker are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project intends to follow
[Semantic Versioning](https://semver.org/) once tagged releases begin.

## [0.1.0] - Unreleased

Initial public release candidate. Date to be filled in when this is tagged.

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

### Known limitations

- Multi-display support is incomplete: switching across displays falls back to a slower walk, direct
  ⌃N jumps are disabled entirely with more than one display attached, and the Mission Control name
  overlay only draws on the primary display (#23).
- No auto-update. See the README.
