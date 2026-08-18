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
   *As built: the signing / hardened-runtime / notarize / staple half is real
   (`scripts/make-app.sh`). **Sparkle auto-update is planned, not built** — there is no Sparkle
   dependency in `Package.swift` and the app makes no network calls at all.*
2. **Fragility is the enemy.** Private APIs break between OS releases (the old
   `dado3212/spaces-renamer` needed SIP off and died on Apple Silicon at 14.4). So:
   - All private symbols live behind **one isolated `CGSPrivate` layer** with capability probes.
   - Everything above that layer is written against **our own protocols**, so when Apple shifts a
     symbol we patch one file, not the app.
   - We use the public `NSWorkspace.activeSpaceDidChangeNotification` for the one thing it can
     tell us: that the active Space changed.
     *As built this is a change **signal**, not a fallback, and there is **no degraded mode**.
     Every read of Space topology goes through CGS; if the symbols don't resolve,
     `displays()` returns `[]` (`SpacesAPI.swift:57-63`), the menu-bar title becomes
     "⚠︎ Spaces N/A" (`AppDelegate.swift:155-157`) and the menu says "Spaces API unavailable on
     this macOS" (`:193-195`) — nothing works. A genuine no-private-API path is
     **planned, not built**.*

### Key private symbols (from CGSInternal / alt-tab-macos / Amethyst prior art)
| Symbol | Purpose | As built |
|---|---|---|
| `CGSMainConnectionID()` | the connection handle everything needs | **resolved & called** (`SkyLightSymbols.swift:23`) |
| `CGSGetActiveSpace(cid)` | current Space ID (per active display) | **resolved & called** (`SkyLightSymbols.swift:29`) |
| `CGSCopyManagedDisplaySpaces(cid)` | **the important one** — full topology: displays → spaces, each space's `ManagedSpaceID` + `uuid` + type (user/fullscreen) | **resolved & called** (`SkyLightSymbols.swift:26`) |
| `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` / `CGSMoveWindowsToManagedSpace` | move a window to another Space | *prior-art reference only* — never resolved, never called; window move is unbuilt (§4.4) |
| `CGSCopySpacesForWindows` | which space(s) a window is on | *prior-art reference only* — never resolved |
| Space-change notifications (`CGSRegisterNotifyProc` / NSWorkspace) | react to switches | the NSWorkspace half only; `CGSRegisterNotifyProc` is *prior-art reference only* |

**Exactly three** private symbols resolve today. `SkyLightSymbols.swift` declares three
`@convention(c)` typealiases and three `load(...)` calls, and it is the only file in the tree that
touches a raw private symbol. The rest of the table is design intent and prior-art notes.

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

> The **spike** ([`/spike`, archived at the `spike-archive`
> tag](https://github.com/blsmth/spacewalker/tree/spike-archive/spike) — the package was moved out
> of `main` in `302cbf5`) de-risked exactly this. Detection ✅. Switching: keyboard-synth via the
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
> uuid alone. (Verified on macOS 15 / Apple Silicon; see the
> [archived `/spike` package](https://github.com/blsmth/spacewalker/tree/spike-archive/spike).)

As designed:

```
SpaceMeta { spaceUUID: String, name: String, icon: SFSymbol|emoji, colorHex: String,
            displayUUID: String, createdAt, orderHint }
```

As built (`SpaceModel/SpaceMetadata.swift`) — the metadata payload holds *only* user-set values, so
an unnamed Space has no record at all and falls back to a positional default:

```
SpaceMetadata { name: String?, symbolName: String?, colorHex: String? }
```

Identity sits on the persisted record alongside the metadata rather than inside it: every record in
`spaces.json` carries **both** `uuid` and `id64` (`SpaceModel/SpaceStore.swift`). `createdAt`,
`displayUUID` and `orderHint` were never built — nothing needed them (there is no reordering UI, and
display grouping is read live from the WindowServer).

Persist in `~/Library/Application Support/Spacewalker/spaces.json`. **There is no iCloud sync and no
iCloud toggle** — the earlier "iCloud-off by default" note described an option that does not exist,
in either direction. On every topology change we reconcile: new uuids get a default name
("Desktop N"); vanished uuids are **kept indefinitely — not tombstoned on a 30-day timer**. See §9
for why keeping them forever turned out to be the better call.

---

## 3. Module / target layout (SwiftPM only — no Xcode project)

As built, against `Package.swift`: **five** targets plus three test targets.

```
Spacewalker/
├── Package.swift                 # 5 targets + 3 test targets, all testable
├── Sources/
│   ├── CGSPrivate/               # the private-symbol isolation layer
│   │   ├── SkyLightSymbols.swift #   runtime dlsym resolution — NOT a C shim / @_silgen_name;
│   │   │                         #   there is no include/CGSPrivate.h. See §9.
│   │   └── SpacesAPI.swift       #   read-only Swift API: displays() / activeSpaceID(), plus an
│   │                             #   isAvailable capability probe. No move, no switch.
│   ├── SpaceModel/               # SpaceMetadata, SpaceIdentity, Reconciler, SpaceStore, FuzzyMatch
│   │                             #   (imports CGSPrivate for RawSpace/RawDisplay value types only;
│   │                             #   calls no private symbol — see Package.swift:16-18)
│   ├── SpaceSwitching/           # NOT anticipated by this plan (see §9): switch step planner,
│   │                             #   System Events key synthesis, and every symbolic-hotkey /
│   │                             #   system-prefs write behind consent + backup + restore (§4.7)
│   ├── SpaceService/             # observes changes, owns current state, verifies switches took
│   └── SpacewalkerApp/           # executable target. Switcher / MissionControlOverlay / AppKitApp
│                                 #   are FILES here, not targets: QuickSwitcher.swift,
│                                 #   MissionControlOverlay.swift, AppDelegate.swift, SwitchHUD.swift,
│                                 #   Onboarding.swift, HotKey.swift, SwitchKeyTap.swift, AXUtil.swift
├── App/                          # Info.plist + Spacewalker.entitlements. That is all: there is no
│                                 #   .xcodeproj, no app icon, no Sparkle, no packaging assets.
├── scripts/                      # dev-cert.sh (stable dev signing), make-app.sh (bundle/sign/notarize)
└── Tests/                        # SpaceModelTests, SpaceSwitchingTests, SpaceServiceTests
```

There is no `WindowMover/` target — window move is unbuilt (§4.4). `SpaceService` publishes via plain
closure callbacks (`onChange` / `onSpaceChanged` / `onSwitchDetected`), not Combine.

Why a library + thin app target: the pure logic (identity reconciliation) is unit-testable
without a running WindowServer; the private-API and UI bits are thin.

---

## 4. Feature designs

### 4.1 Naming (menu bar)
- `NSStatusItem` shows the **current Space's name + icon/color**. *As designed:* click → popover
  listing all Spaces (grouped by display), inline rename, icon/color picker, drag to reorder
  (orderHint).
- **As built** (`AppDelegate.swift:178-250`): a plain `NSMenu`, not a popover. It does list every
  Space grouped by display and switches on click, and adds Quick Switcher / Jump Back / Rename
  Current Space… / Restore System Settings…. Rename is a modal `NSAlert` for the *current* Space
  (`:466-485`), not inline per row. The **icon/color picker UI and drag-to-reorder are planned, not
  built** — `symbolName`/`colorHex` are persisted and rendered in the menu and overlay, but nothing
  in the app sets them, and `orderHint` does not exist anywhere in the tree.
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

- Borderless floating `NSPanel`, centered, blur background. As built:
  `styleMask: [.borderless]` with `level = .floating` and **explicitly NOT `.nonactivatingPanel`**
  (`QuickSwitcher.swift:56-62`) — the earlier "(`.nonactivatingPanel`, `.floating`)" bullet here
  contradicted the gotcha box directly above it; the gotcha box is the one that matches the code.
- Global hotkey via a small Carbon `RegisterEventHotKey` wrapper. ⌘0 is **hardcoded**
  (`AppDelegate.swift:134`) — **rebinding is planned, not built**: no settings storage, no rebind
  UI, no Settings window exists. (If another app already owns ⌘0 the registration fails and
  onboarding tells the user — #18.)
- Type-to-filter (fuzzy match on name), rows numbered 1–9 → number key jumps directly.
- Enter = switch to highlighted; Esc = dismiss; a **"Jump Back" row = previous Space**.
  ⌘0 again does *not* jump back — it is a plain show/hide toggle that just hides the panel
  (`AppDelegate.swift:135` → `QuickSwitcher.toggle()` → `hide()`).
- "Previous Space" tracked in `SpaceService` — **one slot, not a 2-deep stack**
  (`SpaceService.swift:16`, `previousSpaceKey: String?`).
- Switch executes via synthesized Ctrl+N / Ctrl+Arrow through the Accessibility keypath (§1,
  confirmed live). Direct jumps depend on "Switch to Desktop N" shortcuts being enabled (onboarding).

### 4.3 Mission Control overlay — **FEASIBILITY CONFIRMED (spike)** ✅
> All three unknowns resolved live on macOS 15 / Apple Silicon, SIP on (see
> [`MissionControlProbe` at the `spike-archive`
> tag](https://github.com/blsmth/spacewalker/blob/spike-archive/Sources/SpacewalkerApp/MissionControlProbe.swift)
> — it was removed from `main` in `441d83a` because its AX dump wrote every window title on every
> Space to a world-readable `/tmp` file):
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
  *Superseded by the spike box above — as built the level is `CGShieldingWindowLevel()`, not
  `.screenSaver` (`MissionControlOverlay.swift:277`), the collection behavior also carries
  `.fullScreenAuxiliary`, the window covers the **primary screen only** (`:274`, `:293-295`), and
  only Spaces with a **custom name** get a label (`:232`). See §9.*
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

### 4.4 Move window between Spaces — **planned, not built** (M3)
None of this exists in the tree: no window-move code path, no `WindowMover` target, and
`CGSMoveWindowsToManagedSpace` is neither resolved nor called anywhere (see the symbol table in §1).
Design as it stands:
- From the menu: "Move focused window → [Space]". Would use `CGSMoveWindowsToManagedSpace`
  with the focused window's `CGWindowID` (via AX `kAXWindowsAttribute` → number).
- Shift-drag in the Switcher: drag a window row onto a Space row → same call.

### 4.5 Automations (v-later) — **planned, not built**
Nothing here exists yet; this is a sketch, not a description of shipped behavior.
On entering a Space, run actions: toggle Focus, Dark Mode, Dock autohide, launch apps, run an
Apple Shortcut. Driven off the same switch event; each action a small adapter.

---

### 4.6 Dev signing (learned the hard way)
TCC (Accessibility/Automation) grants are keyed to the app's **code identity**. **Ad-hoc signing
changes identity every rebuild**, so grants never stick and you re-authorize on every build. Fix:
sign dev builds with a **stable self-signed cert** (`scripts/dev-cert.sh` — its own keychain, known
password, so signing never prompts). Then grant once; it survives rebuilds. Gotchas: the `.p12`
export flag depends on which openssl is first on `PATH` — Homebrew's OpenSSL 3 defaults to
AES-256-CBC, which `security import` rejects, so it needs `-legacy`; macOS's own LibreSSL already
defaults to the older scheme and has **no `-legacy` flag at all** (passing it prints usage and
writes no `.p12`). `dev-cert.sh:130-149` detects the flavor rather than assuming. A self-signed
cert is usable by `codesign --sign` even though `security find-identity -v` lists it as
"0 valid" (not policy-trusted). Also required for the Automation prompt to ever appear: `NSAppleEventsUsageDescription`
(Info.plist) + `com.apple.security.automation.apple-events` entitlement; without them the Apple
Event is denied silently (-1743) and no toggle shows in Settings.

### 4.7 System settings Spacewalker manages (real consent flow — fixed by issue #2)
An earlier pass wrote these unconditionally from `SpaceService.start()` on every launch with no
prompt and no undo — see issue #2. `SystemPrefsCoordinator` is now the only place these are
touched, gated behind an explicit first-run consent dialog ("Enable" / "Not Now", sticky either
way — see `SystemPrefsCoordinator.Consent`). Before the first write it snapshots prior state to
`~/Library/Application Support/Spacewalker/system-prefs-backup.plist` via `SystemPrefsBackup`, and
a menu-bar "Restore System Settings…" item puts it back exactly. `SpaceService` itself never
touches system preferences — declining leaves switching fully functional via the ⌃←/⌃→ walk path;
only direct ⌃N jumps depend on the shortcut being enabled.
- **⌃1–9 "Switch to Desktop N"** (`com.apple.symbolichotkeys`) — enables direct jumps; applies live
  via `activateSettings -u`. Writes are non-clobbering: an entry already rebound by the user to
  something else is left alone and reported as a conflict rather than overwritten. See
  `DesktopShortcuts.plan`.
- **Auto-rearrange Spaces OFF** (`com.apple.dock` `mru-spaces=false`) — with it on (the default),
  macOS reshuffles Spaces by recency, so positions / "Desktop N" numbers / ⌃N mappings churn
  unpredictably. Requires a **Dock restart**, so we only act when it's currently on. See
  `MissionControlPrefs`. (Named Spaces keep their names regardless — identity is the UUID — but
  order stability matters for the switcher and number keys.)

## 5. Permissions & first-run UX
- **Accessibility** (required: hotkeys, switching, window AX): guided prompt +
  `AXIsProcessTrustedWithOptions`, deep-link to the Settings pane. *As built there is no persistent
  "granted ✓" indicator anywhere in the UI: `Onboarding.swift:110-132` polls `AXIsProcessTrusted()`
  every 2s and, the first time it flips true, fires a one-shot "Accessibility permission granted"
  alert and stops polling. A live grant-state view is planned, not built.*
- **Screen Recording** — *only if* we ever need pixel readback for overlay rects (try to avoid).
  Never needed; never requested.
- No network permission needed except Sparkle update checks — and Sparkle is **planned, not built**,
  so today the app makes no network calls at all.
- Login-item toggle via `SMAppService` — **planned, not built**. README documents the manual Login
  Items workaround in the meantime.

## 6. Distribution
- Developer ID Application signing, **hardened runtime**, **notarization** (`notarytool`), stapled.
  **Built:** `scripts/make-app.sh` signs with `--options runtime` (`:83`), submits via
  `notarytool submit --wait` and staples (`:106-109`).
- `.dmg` (create-dmg) + **Sparkle** appcast for auto-update — **planned, not built.** `make-app.sh`
  produces a `.app` plus a zip purely as the notarization submission payload (`:103`); there is no
  dmg step, `create-dmg` is not used, and no Sparkle dependency exists in `Package.swift`.

## 7. Testing & resilience
- Unit tests: topology reconciliation (add/remove/replug/reboot reindex scenarios) — all against
  fixture data, no WindowServer.
- Manual QA matrix per macOS release: detect / switch / move / overlay on 1 + 2 displays —
  **planned, not built**; no such matrix exists in the repo. Two of its cells also do not apply
  yet: *move* is unbuilt (§4.4), and **switching to a Space on another display is explicitly
  unsupported** — `SpaceService.swift:360-363` returns `.crossDisplayUnsupported` and the HUD says
  "Can't switch across displays yet" (`AppDelegate.swift:308`). See §9.
- **Capability probe on launch**: each private call wrapped; if a symbol is missing or returns
  garbage, disable that feature + show a "needs update for macOS X" banner instead of crashing.
  *As built, the wrapping is real — `SkyLightSymbols` yields `nil` for anything it cannot resolve
  and every call site guards, so a missing symbol never crashes. The **per-feature disable, the
  garbage-return check, and the "needs update for macOS X" banner are planned, not built**: today
  it is one app-wide `isAvailable` and a "⚠︎ Spaces N/A" menu-bar title.*

---

## 8. Milestones

- **M0 — Spike:** ✅ **DONE.** Enumerate spaces, active space, notifications, switching all probed
  on macOS 15 / Apple Silicon. Detection solid; switching viable via the Accessibility keypath.
- **M1 — Model + menu bar:** ✅ **DONE.** CGSPrivate isolation layer, identity/reconciliation +
  JSON persistence (81 passing tests), `NSStatusItem` showing the current Space name/icon, rename
  dialog. Verified live: names show, update on switch, rename works, **survives reboot**. Icon/color
  pickers still TODO (metadata + rendering already in place).
- **M2 — Quick Switcher:** ✅ **DONE.** ⌘0 floating panel (local-monitor key handling), fuzzy
  filter, number-key direct jumps, arrows/Return, Jump Back. Switch primitive via System Events
  keypath (native CGEvent dead), direct ⌃N jumps with auto-enabled Desktop shortcuts, focus-yield
  fix for dropped shortcuts. Stable dev-signing so TCC grants persist. Verified live end-to-end.
- **M3 — Window mover:** ⏳ **planned, not built.** Move focused window to a chosen Space
  (menu + drag). Nothing in the tree implements it — see §4.4.
- **M5 — Mission Control overlay:** ✅ **BUILT & RENDERING.** `MissionControlOverlay` polls the Dock
  AX (0.15s ≈ 7Hz, but **only while Mission Control is open** — it idles at 1.0s since PR #47 /
  issue #19), reads Spaces Bar `Desktop N` rects, maps to Space names, and paints colored name pills
  via the shielding-level overlay — labels ride onto the thumbnails as the bar expands. Also a
  **Switch HUD** (eye-level flash naming the Space you switched to). Remaining polish: collapsed-bar
  behavior (hide-until-expanded), optionally show unnamed Spaces, AX-observer instead of polling.
- **M6 — Polish & ship:** ⏳ **partly built.** Signing, hardened runtime, notarization+stapling and
  the license are done; permissions UX exists as first-run onboarding. The **login item
  (`SMAppService`), the DMG and Sparkle are planned, not built** — see §5 and §6.

Order deliberately front-loads the tractable, high-value pieces (M1–M3) and isolates the
riskiest, maintenance-heaviest piece (M5) so it can slip without blocking a shippable app.

## 9. As-built vs as-designed

This document is a design diary, so it records what was *planned* as well as what shipped. In seven
places the code deliberately diverged from the plan and the shipped thing is better. Those are
course corrections worth keeping the reasoning for, not drift to be quietly papered over.

1. **`dlsym` at runtime, not a C shim.** §3 designed `include/CGSPrivate.h` with `@_silgen_name`
   bridging. Shipped: `SkyLightSymbols.swift` resolves each symbol with `dlsym`. Better because a
   missing symbol becomes a `nil` we can detect instead of a link-time dependency on a private
   `.tbd` that either fails to build or crashes at launch. It also searches the two absolute,
   SIP-protected framework paths **before** `RTLD_DEFAULT` (PR #42), so a symbol shadowed by
   `DYLD_INSERT_LIBRARIES` or a hijacked plugin cannot become the app's view of Space topology.
2. **`CGShieldingWindowLevel()`, not `.screenSaver`.** §4.3's own spike box already recorded this;
   only the older design bullet at the bottom of §4.3 still said `.screenSaver`. The shielding
   level is what actually renders above Mission Control (`MissionControlOverlay.swift:277`).
3. **Records kept forever, not tombstoned for 30 days.** §2 designed a 30-day tombstone. Shipped:
   records are never deleted, and identity is hardened instead — each record carries both `uuid`
   and `id64`, a Space that starts reporting a real uuid self-heals onto it
   (`SpaceStore.swift:118-131`), a recycled `id64` is blocked from inheriting a dead Space's name
   (`:25-29`), a corrupt file is quarantined rather than overwritten (`:260-271`), a rolling backup
   is written before every persist (`:179-184`), and the envelope is schema-versioned (`:283-286`).
   Better because a 30-day timer silently loses names for a display you unplug over a long break,
   and the failure it was guarding against (stale records) costs a few bytes of JSON.
4. **`SpaceSwitching` is a target this plan never anticipated.** §3 had switching living inside
   `Switcher/`. It grew into its own library: step planner, System Events synthesis, symbolic-hotkey
   read/write, and the consent/backup/restore machinery — 9 files with its own test target. Better
   because the switch planning and the hotkey plists are pure logic, and pulling them out of the app
   target is what makes them unit-testable at all (`Tests/SpaceSwitchingTests`).
5. **Switch verification is a shipped feature, not a QA step.** §4.2 used `CGSGetActiveSpace` as a
   manual check. Shipped: `SpaceService` takes a baseline before synthesis (`:377`) and re-reads
   after (`verifyAndFinish`, `:430-446`); if the Space did not move it returns `.switchDidNotTake`
   (`:341`) and the app opens a dialog pointing at the exact Keyboard Shortcuts pane
   (`AppDelegate.swift:344-362`). Better because the most likely real-world failure — the user's
   ⌃N shortcut being off or rebound — now self-diagnoses instead of looking like a silent no-op.
6. **Consent + backup + one-click restore for symbolic-hotkey writes.** The plan just said
   onboarding would "write `com.apple.symbolichotkeys` + reload". Shipped: `SystemPrefsCoordinator`
   is the only writer, gated behind a first-run consent dialog, snapshotting prior state via
   `SystemPrefsBackup` and exposing "Restore System Settings…" in the menu (§4.7). Better because
   the app mutates the user's global keyboard configuration, and doing that unprompted and
   irreversibly was a real bug (issue #2).
7. **Idle/energy gating** (PR #47, issue #19) — not in this plan at all. Both always-on timers now
   arm on demand and back off: `SpaceService`'s 33Hz active-Space poll is armed for a bounded window
   around a switch and self-invalidates, and the overlay's Dock AX poll idles at 1.0s and only ramps
   to 0.15s once Mission Control is confirmed open. Both tear down on sleep and resume on wake.
   Better because the original design left the process permanently disqualified from App Nap and
   trickling cross-process XPC into the Dock forever.

And one place the code is honestly **narrower** than the plan, recorded here rather than quietly
dropped: **cross-display switching is unsupported.** If the target Space is on a display other than
the active one, `SpaceService.swift:360-363` returns `.crossDisplayUnsupported` and the HUD says
"Can't switch across displays yet" — walking there with ⌃←/⌃→ is not reliable. §7's "1 + 2 displays"
QA matrix assumes a capability that does not exist yet.

## 10. Prior art to mine (all use these private APIs)
- `NUIKit/CGSInternal` — the header reference for CGS symbols.
- `lwouis/alt-tab-macos` — battle-tested private-API usage, space handling.
- `ianyh/Amethyst` — space throwing / window-to-space moves.
- `dado3212/spaces-renamer` — the (now-broken-on-AS) MC-label approach; cautionary reference.
- `Schachte/space-monitor-rs`, `bigbearlabs/SpaceSwitcher` — active-space monitoring patterns.
