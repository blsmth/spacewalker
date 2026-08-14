# Spacewalker — a native macOS Spaces manager

> Goal: name/icon/color your macOS Spaces, a fast Quick Switcher, custom names
> **inside Mission Control**, and move windows between Spaces.
>
> Target: macOS 13+ (build/dev on macOS 15 / Apple Silicon). Native Swift. Menu-bar app.
> ~single-binary, small footprint. **Direct-download & notarized** (not Mac App Store).

---

## 1. The one thing that decides the whole architecture

macOS has **no public API for Spaces / Mission Control**. Apple has refused one for 15+ years.
Every feature here rides on **private CoreGraphics `CGS…` (SkyLight) symbols** plus the
Accessibility API. Two consequences we design around from day one:

1. **No Mac App Store.** Private symbols = automatic rejection. We ship a **Developer ID–signed,
   notarized** app via direct download + Sparkle auto-update.
2. **Fragility is the enemy.** Private APIs break between OS releases (the old
   `dado3212/spaces-renamer` needed SIP off and died on Apple Silicon at 14.4). So:
   - All private symbols live behind **one isolated `CGSPrivate` layer** with capability probes.
   - Everything above that layer is written against **our own protocols**, so when Apple shifts a
     symbol we patch one file, not the app.
   - We keep a **no-private-API fallback** path for the few things NSWorkspace can do
     (`activeSpaceDidChangeNotification`), so the app degrades instead of dying.

### Key private symbols (from CGSInternal / alt-tab-macos / Amethyst prior art)
| Symbol | Purpose |
|---|---|
| `CGSMainConnectionID()` | the connection handle everything needs |
| `CGSGetActiveSpace(cid)` | current Space ID (per active display) |
| `CGSCopyManagedDisplaySpaces(cid)` | **the important one** — full topology: displays → spaces, each space's `ManagedSpaceID` + `uuid` + type (user/fullscreen) |
| `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` / `CGSMoveWindowsToManagedSpace` | move a window to another Space |
| `CGSCopySpacesForWindows` | which space(s) a window is on |
| Space-change notifications (`CGSRegisterNotifyProc` / NSWorkspace) | react to switches |

Switching to a Space. Strategy (**settled after live testing on macOS 15 / Apple Silicon, SIP on**):

**What we ruled out (both empirically dead on Sequoia):**
- ❌ `CGEvent` keystroke synthesis to the HID tap — the OS ignores it for space switching; the
  events leaked into the focused app as raw keys (`^[[1;5C` in the terminal).
- ❌ `CGSManagedDisplaySetCurrentSpace` — a **phantom**: it mutates the WindowServer's internal
  "current space" pointer (so `CGSCopyManagedDisplaySpaces` *reports* the new space) but performs
  **no visual switch**. Do not validate a switch by re-reading this API — it self-confirms a lie.
  Reliable direct-set is what the SIP-**disabled** scripting-addon tools (yabai, instantspaces) use.

**What works (✅ confirmed live — screen actually moved):**
- **Key synthesis through the Accessibility / System Events keypath.**
  `osascript -e 'tell application "System Events" to key code 124 using control down'` performed a
  real, animated space switch. A real hardware Ctrl+→ also works. The differentiator vs the failed
  `CGEvent`: System Events emits the **Control modifier as its own `flagsChanged` event** before
  the arrow; the WindowServer's symbolic-hotkey handler requires that. Requires Accessibility perm.

**Switch primitive design:**
1. **Adjacent moves** (Jump Back, neighbor): synthesize **Ctrl+←/→** (symbolic hotkeys 79/81, on by
   default — verified present on this machine) through **System Events (`NSAppleScript`)**.
   ✅ **Micro-spike result:** a properly-sequenced native `CGEvent` (Control as its own event, both
   `.cgSessionEventTap` and `.cghidEventTap`) **did NOT switch** — macOS filters synthetic HID/session
   events out of Space switching. Only the **Apple Events / Accessibility path** (System Events) is
   honored. So: reuse a **pre-compiled `NSAppleScript`** per direction and run it (fast, <50ms).
   Cost: adds an **Automation permission** ("Spacewalker wants to control System Events") on top of
   Accessibility — handle in onboarding.
2. **Direct jump to any Space N** (Quick Switcher number keys): use **"Switch to Desktop N"**
   shortcuts (Ctrl+1..9, symbolic hotkeys 118+). ⚠️ **These are NOT present on this machine** — so
   onboarding must **enable them** (write `com.apple.symbolichotkeys` + reload, or guide the user
   through System Settings ▸ Keyboard ▸ Shortcuts ▸ Mission Control).
   Then synthesize Ctrl+N. Map "desktop N" via our ordered model (skip fullscreen spaces).
   - Fallback if desktop-N shortcuts can't be enabled: **walk** Ctrl+←/→ `|Δ|` times (animates
     through intermediates; fine for small Δ, slower for far jumps).

> The **spike** (`/spike`) de-risked exactly this. Detection ✅. Switching: keyboard-synth via the
> Accessibility keypath ✅, `CGEvent`-to-HID ❌, direct CGS set ❌ phantom. **Foundation viable —
> proceed to M1**, with the switch primitive as the one piece carrying an onboarding dependency
> (enabling Ctrl+Number) rather than a technical unknown.

---

## 2. Space identity — the subtle correctness problem

Space **order and OS IDs are not stable**: OS reindexes when you add/remove Spaces, reboot, or
plug in a display. If we key our names by index we mislabel everything after the first reorder.

**Solution:** key our metadata by the **OS-provided Space `uuid`** from
`CGSCopyManagedDisplaySpaces` (stable per Space for its lifetime), stored per display.
We keep an ordered model but the *identity* is the uuid.

> ⚠️ **Spike finding:** the first Space's dict can come back with an **empty `uuid`**
> (observed `uuid="", managed=1, id64=1`). So identity = `uuid` **falling back to `id64` /
> `ManagedSpaceID`** when uuid is blank. `SpaceIdentity` must encapsulate this — never key on
> uuid alone. (Verified on macOS 15 / Apple Silicon; see `/spike`.)

```
SpaceMeta { spaceUUID: String, name: String, icon: SFSymbol|emoji, colorHex: String,
            displayUUID: String, createdAt, orderHint }
```

Persist in `~/Library/Application Support/Spacewalker/spaces.json` (+ iCloud-off by default).
On every topology change we reconcile: new uuids get a default name ("Desktop N"), vanished
uuids are tombstoned (kept 30 days so a replug restores names).

---

## 3. Module / target layout (SwiftPM + Xcode app target)

```
Spacewalker/
├── Package.swift                 # library targets, testable
├── Sources/
│   ├── CGSPrivate/               # C shim + Swift wrappers for all private symbols  ← isolation layer
│   │   ├── include/CGSPrivate.h  #   @_silgen_name / bridging of SkyLight symbols
│   │   └── SpacesAPI.swift       #   safe Swift API: enumerate/active/move/switch + capability probe
│   ├── SpaceModel/               # SpaceMeta, topology reconciliation, JSON persistence (NO private API)
│   ├── SpaceService/             # observes changes, owns current state, publishes via Combine
│   ├── Switcher/                 # Quick Switcher window + fuzzy filter + hotkey handling
│   ├── MissionControlOverlay/    # transparent click-through HUD painting names over MC thumbnails
│   ├── WindowMover/              # move-window-to-space (drag + menu)
│   └── AppKitApp/                # NSApplication, menu-bar (NSStatusItem), Settings, permissions UX
├── App/                          # Xcode target: Info.plist, entitlements, icon, Sparkle, packaging
└── Tests/                        # unit tests for SpaceModel reconciliation (pure logic)
```

Why a library + thin app target: the pure logic (identity reconciliation) is unit-testable
without a running WindowServer; the private-API and UI bits are thin.

---

## 4. Feature designs

### 4.1 Naming (menu bar)
- `NSStatusItem` shows the **current Space's name + icon/color**. Click → popover listing all
  Spaces (grouped by display), inline rename, icon/color picker, drag to reorder (orderHint).
- Name also rendered wherever we can: menu bar (easy), Switcher (easy), Mission Control (§4.3, hard).

### 4.2 Quick Switcher — ⌘0
> ⚠️ **Two hard-won gotchas (fixed):**
> - **Key capture:** a borderless HUD panel must actually take focus (NOT `.nonactivatingPanel`) or
>   the keystrokes never arrive after the first switch. Drive keys from a **local event monitor**
>   (`addLocalMonitorForEvents`) — the responder chain would system-beep and drop number keys.
> - **Dropped ⌃N:** synthesizing the switch shortcut *while our app is grabbing focus* makes the
>   WindowServer silently drop it (`switchTo` returns ok but the Space doesn't move — "works once
>   then not"). Fix: on pick, `hide()` → `NSApp.deactivate()` → fire the switch after ~120ms so
>   focus settles. Verified with before/after `CGSGetActiveSpace` ground truth (changed=true every time).

- Borderless floating `NSPanel` (`.nonactivatingPanel`, `.floating`), centered, blur background.
- Global hotkey via a small Carbon `RegisterEventHotKey` wrapper (⌘0 default, rebindable).
- Type-to-filter (fuzzy match on name), rows numbered 1–9 → number key jumps directly.
- Enter = switch to highlighted; Esc = dismiss; ⌘0-again or a "Jump Back" row = previous Space.
- "Previous Space" tracked in `SpaceService` (a 2-deep stack).
- Switch executes via synthesized Ctrl+N / Ctrl+Arrow through the Accessibility keypath (§1,
  confirmed live). Direct jumps depend on "Switch to Desktop N" shortcuts being enabled (onboarding).

### 4.3 Mission Control overlay — **FEASIBILITY CONFIRMED (spike)** ✅
> All three unknowns resolved live on macOS 15 / Apple Silicon, SIP on (see `MissionControlProbe`):
> 1. **Draw above Mission Control** — a window at `CGShieldingWindowLevel()` with
>    `[.canJoinAllSpaces, .stationary]` renders on top of MC. ✅
> 2. **Detect MC is open** — the Dock's AX tree gains an `AXGroup 'Mission Control'` only while MC
>    is open (poll or observe the Dock via `AXUIElementCreateApplication(dockPID)`). ✅
> 3. **Locate each Space** — under `Mission Control → 'Spaces Bar' → AXList` there's an
>    `AXButton 'Desktop N'` per Space with an exact rect (evenly spaced across the top, in desktop
>    order → maps to our `userIndex = N-1`). ✅
>
> **Mechanism:** watch Dock AX for the Mission Control group → read Spaces Bar rects → map Desktop N
> to our Space name → paint labels via the shielding-level overlay. Coordinate note: the Spaces Bar
> reports `y≈-32` (it peeks above the screen top until hovered) — read expanded, or anchor to the
> stable x-centers. This is the headline trick, now known-buildable.

Original design notes (still the plan):

The old "rewrite the label in MC" trick is dead on Apple Silicon. Modern approach = **overlay**:
- A transparent, full-screen, **click-through** `NSWindow`:
  `level = .screenSaver` (above MC), `ignoresMouseEvents = true`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`, `backgroundColor = .clear`.
- **Detect Mission Control is active**: watch the Dock's `com.apple.exposelaunchd` / a Dock process
  MC state, or observe the WindowServer via CGS; simplest reliable signal = AX observation of the
  Dock process + `CGSCopyManagedDisplaySpaces` layout deltas. (Spike v2 will nail the trigger.)
- **Position labels**: when MC opens, compute each Space thumbnail's on-screen rect. MC lays
  thumbnails in a predictable strip; derive rects from screen geometry + space count, or read them
  via AX from the Dock's MC UI element tree (preferred — exact rects, resilient to layout).
- Paint each Space's name/icon/color as a rounded label over its thumbnail; fade in/out with MC.
- **Fallback if we can't get exact rects:** show a top-of-screen legend ("1 ▸ Email · 2 ▸ Build …")
  while MC is open — still useful, less magical.

> Risk mgmt: build overlay behind a feature flag; if the trigger/rect detection proves unstable on
> a given OS, the legend fallback keeps the feature alive. This is the piece most likely to need
> maintenance per macOS release.

### 4.4 Move window between Spaces
- From the menu popover: "Move focused window → [Space]". Uses `CGSMoveWindowsToManagedSpace`
  with the focused window's `CGWindowID` (via AX `kAXWindowsAttribute` → number).
- Shift-drag in the Switcher: drag a window row onto a Space row → same call.

### 4.5 Automations (v-later)
On entering a Space, run actions: toggle Focus, Dark Mode, Dock autohide, launch apps, run an
Apple Shortcut. Driven off the same switch event; each action a small adapter.

---

### 4.6 Dev signing (learned the hard way)
TCC (Accessibility/Automation) grants are keyed to the app's **code identity**. **Ad-hoc signing
changes identity every rebuild**, so grants never stick and you re-authorize on every build. Fix:
sign dev builds with a **stable self-signed cert** (`scripts/dev-cert.sh` — its own keychain, known
password, so signing never prompts). Then grant once; it survives rebuilds. Gotchas: Homebrew
OpenSSL 3 needs `-legacy` on the `.p12` export for `security import`; a self-signed cert is usable
by `codesign --sign` even though `security find-identity -v` lists it as "0 valid" (not policy-
trusted). Also required for the Automation prompt to ever appear: `NSAppleEventsUsageDescription`
(Info.plist) + `com.apple.security.automation.apple-events` entitlement; without them the Apple
Event is denied silently (-1743) and no toggle shows in Settings.

### 4.7 System settings Spacewalker manages (user opted in)
Managed idempotently on launch so behavior is stable:
- **⌃1–9 "Switch to Desktop N"** (`com.apple.symbolichotkeys`) — enables direct jumps; applies live
  via `activateSettings -u`. See `DesktopShortcuts`.
- **Auto-rearrange Spaces OFF** (`com.apple.dock` `mru-spaces=false`) — with it on (the default),
  macOS reshuffles Spaces by recency, so positions / "Desktop N" numbers / ⌃N mappings churn
  unpredictably. Requires a **Dock restart**, so we only act when it's currently on. See
  `MissionControlPrefs`. (Named Spaces keep their names regardless — identity is the UUID — but
  order stability matters for the switcher and number keys.)

## 5. Permissions & first-run UX
- **Accessibility** (required: hotkeys, switching, window AX): guided prompt +
  `AXIsProcessTrustedWithOptions`, deep-link to the Settings pane, live "granted ✓" state.
- **Screen Recording** — *only if* we ever need pixel readback for overlay rects (try to avoid).
- No network permission needed except Sparkle update checks.
- Login-item toggle via `SMAppService`.

## 6. Distribution
- Developer ID Application signing, **hardened runtime**, **notarization** (`notarytool`), stapled.
- `.dmg` (create-dmg) + **Sparkle** appcast for auto-update.

## 7. Testing & resilience
- Unit tests: topology reconciliation (add/remove/replug/reboot reindex scenarios) — all against
  fixture data, no WindowServer.
- Manual QA matrix per macOS release: detect / switch / move / overlay on 1 + 2 displays.
- **Capability probe on launch**: each private call wrapped; if a symbol is missing or returns
  garbage, disable that feature + show a "needs update for macOS X" banner instead of crashing.

---

## 8. Milestones

- **M0 — Spike:** ✅ **DONE.** Enumerate spaces, active space, notifications, switching all probed
  on macOS 15 / Apple Silicon. Detection solid; switching viable via the Accessibility keypath.
- **M1 — Model + menu bar:** ✅ **DONE.** CGSPrivate isolation layer, identity/reconciliation +
  JSON persistence (5 passing tests), `NSStatusItem` showing the current Space name/icon, rename
  dialog. Verified live: names show, update on switch, rename works, **survives reboot**. Icon/color
  pickers still TODO (metadata + rendering already in place).
- **M2 — Quick Switcher:** ✅ **DONE.** ⌘0 floating panel (local-monitor key handling), fuzzy
  filter, number-key direct jumps, arrows/Return, Jump Back. Switch primitive via System Events
  keypath (native CGEvent dead), direct ⌃N jumps with auto-enabled Desktop shortcuts, focus-yield
  fix for dropped shortcuts. Stable dev-signing so TCC grants persist. Verified live end-to-end.
- **M3 — Window mover:** move focused window to a chosen Space (menu + drag).
- **M5 — Mission Control overlay:** ✅ **BUILT & RENDERING.** `MissionControlOverlay` polls the Dock
  AX (~7Hz), reads Spaces Bar `Desktop N` rects, maps to Space names, and paints colored name pills
  via the shielding-level overlay — labels ride onto the thumbnails as the bar expands. Also a
  **Switch HUD** (eye-level flash naming the Space you switched to). Remaining polish: collapsed-bar
  behavior (hide-until-expanded), optionally show unnamed Spaces, AX-observer instead of polling.
- **M6 — Polish & ship:** permissions UX, login item, sign/notarize/DMG/Sparkle, license.

Order deliberately front-loads the tractable, high-value pieces (M1–M3) and isolates the
riskiest, maintenance-heaviest piece (M5) so it can slip without blocking a shippable app.

## 9. Prior art to mine (all use these private APIs)
- `NUIKit/CGSInternal` — the header reference for CGS symbols.
- `lwouis/alt-tab-macos` — battle-tested private-API usage, space handling.
- `ianyh/Amethyst` — space throwing / window-to-space moves.
- `dado3212/spaces-renamer` — the (now-broken-on-AS) MC-label approach; cautionary reference.
- `Schachte/space-monitor-rs`, `bigbearlabs/SpaceSwitcher` — active-space monitoring patterns.
