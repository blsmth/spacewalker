import AppKit
import ApplicationServices
import SpaceModel

/// Pure geometry for placing a Mission Control desktop-button label on the correct physical
/// screen (issue #23). Kept free of `NSScreen`/`NSWindow`/any live AX call so it's directly
/// unit-testable against synthetic multi-screen frames — see `MissionControlOverlayGeometryTests`
/// — the same technique #59 (`QuickSwitcherGeometry`) and #61 (`SwitchHUDTiming`) used.
///
/// Verified live only on this machine's single display; the multi-screen cases below are
/// exercised solely by synthetic `CGRect` fixtures, never against a real second monitor — see the
/// PR body for exactly what that does and doesn't prove.
enum MissionControlOverlayGeometry {

  /// AX global space (top-left origin, y-down) → Cocoa global space (y-up), anchored to the
  /// **main** screen specifically — not whichever physical screen `axRect` happens to visually
  /// sit on. This is correct for a rect on any screen, not just the main one: AX's global
  /// coordinate space and Cocoa's global coordinate space are both defined relative to the main
  /// screen (macOS always places `NSScreen`'s "main" screen — the one with the menu bar — at
  /// Cocoa origin `(0, 0)`, with every other screen's `frame` positioned relative to it). Passing
  /// any other screen's height here would misplace every rect that isn't on that other screen.
  static func cocoaGlobalRect(fromAX axRect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
    CGRect(
      x: axRect.origin.x,
      y: mainScreenHeight - axRect.origin.y - axRect.height,
      width: axRect.width, height: axRect.height)
  }

  /// Which of `screenFrames` (each already in Cocoa global coordinates, e.g. `NSScreen.frame`)
  /// `rect` actually belongs on. Three tiers, in order (PR #63 review, finding F1):
  ///
  /// 1. **Strict center containment** — `rect`'s center is actually inside a screen's frame. This
  ///    is the only tier the previous version of this function had, and stays first because it's
  ///    the one case that correctly disambiguates two screens whose *horizontal* spans overlap
  ///    (e.g. one stacked above another) — see `testScreenFrameFindsTheContainingScreenAmongSeveral`.
  /// 2. **x-overlap** — falls back to whichever screen's horizontal span contains `rect`'s center
  ///    x, ignoring y, if no screen's frame strictly contains the center. This is what actually
  ///    fixes issue F1: Mission Control's Spaces Bar rests **collapsed above the physical
  ///    screen's top edge** as its normal, steady state (measured live — see
  ///    `scripts/dump-mc-ax.swift` and the PR body — an AX rect of `(1338, -32, 65, 24)` on a
  ///    3440x1440 display converts to a Cocoa-global rect whose center y is 1460, twelve points
  ///    past the screen's own 1440pt height), not some rare edge case. Requiring strict
  ///    containment made every screen's `contains(center)` fail for that entirely normal rect, so
  ///    `render(_:)` silently dropped every row, every tick — the headline overlay feature became
  ///    a permanent no-op on a single display, which is worse than the crash (issue #64) this PR
  ///    otherwise fixes. x-overlap is still the correct signal for *which* screen: screens tile
  ///    left-to-right (or occasionally top-to-bottom), but Mission Control's own collapse/expand
  ///    animation only ever moves a Spaces Bar row vertically, never sideways onto a different
  ///    display.
  /// 3. **Nearest by squared distance** — only if `rect`'s x doesn't overlap *any* screen either
  ///    (shouldn't happen for a real Spaces Bar button, but keeps this total rather than silently
  ///    dropping a row outright).
  ///
  /// `nil` only when `screenFrames` itself is empty — the y-clamp in
  /// `makeLabel(space:over:screenSize:)` (kept from before #23) is what keeps an overflowing rect
  /// like the one above on-screen once it's attributed to the right display.
  static func screenFrame(containing rect: CGRect, among screenFrames: [CGRect]) -> CGRect? {
    guard !screenFrames.isEmpty else { return nil }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    if let containing = screenFrames.first(where: { $0.contains(center) }) {
      return containing
    }
    if let overlapping = screenFrames.first(where: { $0.minX <= center.x && center.x < $0.maxX }) {
      return overlapping
    }
    return screenFrames.min(by: {
      squaredDistance(from: rect, to: $0) < squaredDistance(from: rect, to: $1)
    })
  }

  /// Squared Euclidean distance from `rect`'s center to the nearest point of `screen` — zero if
  /// the center is already inside `screen`. Used only as `screenFrame(containing:among:)`'s
  /// tie-break when no screen's x-span overlaps `rect` at all; squared (not the real distance) is
  /// enough for a `min(by:)` comparison and avoids the `sqrt` call.
  private static func squaredDistance(from rect: CGRect, to screen: CGRect) -> CGFloat {
    let dx = max(screen.minX - rect.midX, rect.midX - screen.maxX, 0)
    let dy = max(screen.minY - rect.midY, rect.midY - screen.maxY, 0)
    return dx * dx + dy * dy
  }

  /// `rect` (Cocoa global) translated into `screenFrame`'s local origin — the coordinates to use
  /// for a subview of a window whose own frame is exactly `screenFrame`.
  static func localRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
    CGRect(
      x: rect.origin.x - screenFrame.origin.x,
      y: rect.origin.y - screenFrame.origin.y,
      width: rect.width, height: rect.height)
  }

  /// Buckets `allSpaces` first by `displayID`, then by `userIndex` within that display (issue
  /// #64) — the lookup `render(_:)` uses to turn a Mission Control row's (displayID, structural
  /// index) into the `ResolvedSpace` it names. `Dictionary(grouping:)` and
  /// `Dictionary(_:uniquingKeysWith:)` never trap, unlike the single flattened
  /// `Dictionary(uniqueKeysWithValues: allSpaces.map { ($0.userIndex, $0) })` this replaces, which
  /// crashed the instant two displays' `userIndex`es collided — which is *always*, the moment
  /// there's more than one display: `Reconciler.resolve` restarts `userIndex` at 0 per display
  /// (see its doc comment), so `[0, 1, 0, 1]` for two 2-Space displays is normal, not corrupt
  /// data. Pure and free of any live AX/NSScreen call, so a synthetic multi-display fixture can
  /// exercise the exact shape that used to crash — see `MissionControlOverlayGeometryTests`.
  static func spacesByDisplayAndIndex(
    _ allSpaces: [ResolvedSpace]
  ) -> [String: [Int: ResolvedSpace]] {
    Dictionary(grouping: allSpaces, by: \.displayID).mapValues { spaces in
      Dictionary(spaces.map { ($0.userIndex, $0) }, uniquingKeysWith: { first, _ in first })
    }
  }
}

/// Paints custom Space names **inside Mission Control** — the headline feature.
///
/// Mechanism (proven in the spike): poll the Dock's AX tree; while the `Mission Control` group
/// exists, read each `Desktop N` button rect from the `Spaces Bar`, map N → our Space, and draw a
/// name label over it via a window at `CGShieldingWindowLevel()` (which renders above MC).
@MainActor
final class MissionControlOverlay {

  private let spaces: () -> [ResolvedSpace]
  private var timer: Timer?
  /// One borderless overlay window per physical screen (issue #23), keyed by that screen's
  /// `frame.debugDescription` — `CGRect` isn't `Hashable`, and this is a simple, exact key for
  /// "same frame as last time" without needing to track `NSScreen` identity across reconnects.
  /// A screen's window is created on first use and reused as long as that exact frame keeps
  /// reappearing in `NSScreen.screens`; `pruneWindows(currentFrameKeys:)` tears down the rest.
  /// This key is opaque rather than self-documenting — a small `Hashable` struct, or the screen's
  /// `CGDirectDisplayID` (from `deviceDescription`), would say more. Note also that mirrored
  /// displays legitimately share one identical `frame` and therefore collapse to one window
  /// under this key; that's benign, since mirrored content is identical by definition, not a bug
  /// this key introduces.
  private var windowsByFrameKey: [String: NSWindow] = [:]
  /// The interval `timer` was last created with, so `scheduleTimer(for:)` only tears down and
  /// recreates it when the desired rate actually changes, instead of on every tick.
  private var currentInterval: TimeInterval?
  /// Cached so `tick()` doesn't re-run `NSRunningApplication.runningApplications` and rebuild the
  /// AX wrapper on every fire (#19) — only cleared when the Dock actually restarts, via
  /// `dockTerminationObserver` below.
  private var dockPID: pid_t?
  private var dockTerminationObserver: NSObjectProtocol?
  private var sleepWakeObservers: [NSObjectProtocol] = []
  /// True once a tick has actually found the Mission Control AX group — drives which of
  /// `Constants.activeInterval`/`idleInterval` the timer runs at (#19).
  private var isMissionControlOpen = false
  /// #22: true once this MC-open session has already logged a structural-detection failure
  /// (Mission Control confirmed open but no desktop button row found) — reset whenever MC
  /// closes, so a real failure is surfaced once per session rather than once per 150ms tick.
  private var hasLoggedDetectionFailure = false

  private enum Constants {
    /// Rate while Mission Control is confirmed open — fast enough to track the Spaces Bar rects
    /// smoothly as MC animates and the user drags between desktops. Unchanged from before #19.
    static let activeInterval: TimeInterval = 0.15
    /// Rate while idle (MC not open) — this fires for the app's entire lifetime, so it must stay
    /// cheap. Each tick is still a real cross-process AX round-trip into the Dock either way;
    /// there's no cheaper way to notice MC opening without an `AXObserver`, and this app can't be
    /// run here to verify one — see the doc comment on `tick()`. Trading a bit of detection
    /// latency for a ~7x cut in idle XPC traffic (0.15s → 1s) instead of eliminating it outright.
    static let idleInterval: TimeInterval = 1.0
    /// #22: shown in Mission Control itself when it's confirmed open but the desktop button row
    /// couldn't be located structurally — see `renderUnsupportedNotice()`.
    static let unsupportedMessage = "Spacewalker: Space names unavailable here"
  }

  private static let bg = NSColor(srgbRed: 0.06, green: 0.04, blue: 0.10, alpha: 0.92)
  private static let border = NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 0.85)
  private static let text = NSColor(srgbRed: 0.97, green: 0.96, blue: 1.0, alpha: 1)
  private static let lime = NSColor(srgbRed: 0.67, green: 0.93, blue: 0.29, alpha: 1)

  init(spaces: @escaping () -> [ResolvedSpace]) {
    self.spaces = spaces
  }

  func start() {
    guard timer == nil else { return }
    installDockTerminationObserver()
    installSleepWakeObservers()
    scheduleTimer(for: Constants.idleInterval)
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    currentInterval = nil
    if let dockTerminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(dockTerminationObserver)
    }
    dockTerminationObserver = nil
    for observer in sleepWakeObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    sleepWakeObservers = []
    dockPID = nil
    isMissionControlOpen = false
    hasLoggedDetectionFailure = false
    hide()
    // `hide()` only orders every window out — without this, N per-screen windows survive for the
    // rest of the app's life (leaked, though harmless: ordered-out, ignoring mouse events, and
    // never drawn to again unless `start()` reuses the same screen frame). Drop the references so
    // a `stop()`/`start()` cycle rebuilds fresh windows instead of accumulating stale ones.
    windowsByFrameKey.removeAll()
  }

  // MARK: Poll

  /// (Re)creates `timer` at `interval`, but only if it isn't already running at that rate — most
  /// ticks want to stay at whichever rate they're already at, so this is a no-op far more often
  /// than not.
  private func scheduleTimer(for interval: TimeInterval) {
    guard currentInterval != interval else { return }
    timer?.invalidate()
    let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
    currentInterval = interval
  }

  /// #19: rather than a flat ~7Hz poll for the app's entire life, only run that fast once Mission
  /// Control is actually open (confirmed below by finding the Mission Control AX group);
  /// otherwise poll at `Constants.idleInterval`.
  ///
  /// This is the documented minimum fallback (see the issue), not the `AXObserver`
  /// (`kAXCreatedNotification`/`kAXUIElementDestroyedNotification`) approach PLAN.md §8 M5 lists
  /// as the ideal. PR #63's second review did confirm this shell can actually open Mission
  /// Control and read the Dock's AX tree while it's up (`scripts/dump-mc-ax.swift`) — the earlier
  /// version of this comment claiming that was impossible was wrong, and is corrected on
  /// `missionControlGroup(in:)`'s doc comment. What's still not attempted here is specifically the
  /// `AXObserver` notification path itself: this change didn't wire one up and verify it actually
  /// fires for a system-owned process's internal MC group (as opposed to one of its own windows,
  /// the well-documented common use of these notifications) across an open/close cycle. Shipping
  /// an unverified observer risks silently disabling the overlay outright — this app's headline
  /// feature — with no fallback if it turns out unreliable on some macOS version. A reduced-but-
  /// nonzero idle poll that is trivially correct by inspection is the safer trade here; a future
  /// pass that verifies the observer against a live Dock across real open/close cycles should
  /// attempt it and only keep this poll as the fallback path if it proves unreliable.
  private func tick() {
    guard let dock = dockElement(), let mc = missionControlGroup(in: dock) else {
      isMissionControlOpen = false
      hasLoggedDetectionFailure = false
      scheduleTimer(for: Constants.idleInterval)
      hide()
      return
    }
    isMissionControlOpen = true
    scheduleTimer(for: Constants.activeInterval)
    let rows = desktopRows(in: mc)
    guard !rows.isEmpty else {
      // #22: MC is genuinely open (confirmed above by role, not by a localized title) but no
      // desktop button row could be located structurally. macOS always has at least one desktop
      // space when MC is open, so this can never be a legitimate "nothing to draw" — it's always
      // a detection failure. Surface it instead of doing nothing silently.
      renderUnsupportedNotice()
      return
    }
    hasLoggedDetectionFailure = false
    render(rows)
  }

  /// Locates the Mission Control overlay group by AX role and structural position, not by its
  /// localized display title (#22 — the previous `title == "Mission Control"` check went dark on
  /// any non-English system). PLAN.md §4.3's spike found the Dock gains exactly one `AXGroup` as
  /// a *direct* child of its top-level `AXApplication` element while (and only while) Mission
  /// Control is open, alongside the permanent `AXList` of dock items.
  ///
  /// **Now re-verified live** (PR #63's second review) with Mission Control actually open —
  /// `scripts/dump-mc-ax.swift`'s captured tree confirms both the closed-Dock shape (one
  /// `AXList`, no `AXGroup`) and this open-Dock shape: a top-level `AXGroup` identified `"mc"`
  /// containing exactly one `AXGroup` identified `"mc.display"`, which in turn contains
  /// `"mc.windows"` and `"mc.spaces"` (title `"Spaces Bar"`, containing the `"mc.spaces.list"`
  /// `AXList` of `Desktop N` buttons and a sibling `"mc.spaces.add"` button) — exactly the shape
  /// `MissionControlMatching` was already written to expect, this time measured rather than
  /// reasoned from the old spike.
  ///
  /// Correction to a previous version of this comment: it claimed "the Dock did not expose an
  /// `AXIdentifier` on any element I could inspect" — **false**, corrected after actually opening
  /// Mission Control on this machine and reading its tree. Every element that matters exposes a
  /// stable `AXIdentifier` (`mc`, `mc.display`, `mc.windows`, `mc.spaces`, `mc.spaces.list`,
  /// `mc.spaces.add`), which is what `MissionControlMatching` now matches on first, geometry only
  /// as documented fallback — see its doc comment (finding F5). One thing this single-display
  /// machine still cannot confirm: whether `mc.display` appears once *per physical display* for a
  /// genuine per-display Spaces Bar layout, or is shared — only one `mc.display` was observed,
  /// which is consistent with either theory on one screen. If it does multiply per display, it
  /// would give structural (UUID-free) display attribution; until that's confirmed on real
  /// multi-display hardware, `MissionControlRowResolution` still resolves a row's display via
  /// screen geometry + `ScreenDisplayIdentity`, not via `mc.display`.
  private func missionControlGroup(in dock: AXUIElement) -> AXUIElement? {
    AXUtil.children(dock).first(where: { AXUtil.string($0, kAXRoleAttribute) == kAXGroupRole })
  }

  /// Cached (pid, element) pair for the Dock — see `dockPID`'s doc comment. Re-resolved only when
  /// the Dock isn't cached yet or `dockTerminationObserver` cleared the cache.
  private func dockElement() -> AXUIElement? {
    if let dockPID {
      return AXUtil.dockElement(forPID: dockPID)
    }
    guard let pid = AXUtil.dockPID() else { return nil }
    dockPID = pid
    return AXUtil.dockElement(forPID: pid)
  }

  /// The Dock can restart (a user `killall Dock`, or this app's own "Restore System Settings…"
  /// flow via `MissionControlPrefs.restartDockAsync` — see PLAN.md §4.7); its old pid becomes
  /// invalid at that point. Without this, the cached `AXUIElement` above would keep pointing at a
  /// dead process forever, `children(_:)` would keep silently returning `[]` (indistinguishable
  /// from "Dock is alive but MC isn't open"), and the overlay would never work again until the
  /// app itself relaunched.
  private func installDockTerminationObserver() {
    dockTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier == "com.apple.dock"
      else { return }
      MainActor.assumeIsolated { self?.dockPID = nil }
    }
  }

  /// Suspend ticking entirely while asleep/display-off (#19) — there's no Mission Control to
  /// track with no user present, and a `.common`-mode timer that keeps firing into sleep is
  /// exactly the kind of thing that blocks App Nap. Resumes at the idle rate on wake; if MC
  /// somehow is already open the very next tick promotes it back to the active rate as usual.
  private func installSleepWakeObservers() {
    let nc = NSWorkspace.shared.notificationCenter
    sleepWakeObservers = [
      nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.suspendForSleep() }
      },
      nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.suspendForSleep() }
      },
      nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.resumeAfterWake() }
      },
      nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.resumeAfterWake() }
      },
    ]
  }

  private func suspendForSleep() {
    timer?.invalidate()
    timer = nil
    currentInterval = nil
    isMissionControlOpen = false
    hasLoggedDetectionFailure = false
    hide()
  }

  private func resumeAfterWake() {
    guard timer == nil else { return }  // already ticking — stay idempotent
    scheduleTimer(for: Constants.idleInterval)
  }

  /// One array per distinct Spaces Bar found — (structural index, AX-global rect) for each
  /// desktop thumbnail button in that bar — found by AX role and row shape rather than the
  /// localized "Spaces Bar" / "Desktop N" titles (#22: both are translated, and per the issue the
  /// digit itself can be too, e.g. Eastern Arabic numerals). The actual matching is pure and
  /// lives in `MissionControlMatching` (see its doc comment and `MissionControlMatchingTests`
  /// for the language-independent coverage); this is just the live-AX-to-`AXNode` boundary.
  ///
  /// Kept as *rows*, not a single flattened list (issue #64): `n` is only meaningful relative to
  /// its own row, and a second display's Spaces Bar restarts at 1 the same way the first one
  /// does — `render(_:)` resolves each row's owning display before doing anything with its `n`s.
  ///
  /// Now re-verified live (see `missionControlGroup(in:)`), not just reasoned from the prior
  /// spike: the captured tree confirms the Spaces Bar is exactly "an `AXButton 'Desktop N'` per
  /// Space with an exact rect (evenly spaced across the top, in desktop order)" (PLAN.md §4.3),
  /// wrapped in an `AXList` identified `"mc.spaces.list"` — a uniform, left-to-right row by
  /// construction, matched first by that identifier and by geometric shape as documented
  /// fallback (see `MissionControlMatching`'s doc comment). Whether Mission Control genuinely
  /// renders one such row *per physical display* rather than one shared row is still unverified
  /// on this single-display machine — see the PR body.
  private func desktopRows(in missionControl: AXUIElement) -> [[(n: Int, rect: CGRect)]] {
    let node = AXUtil.snapshot(
      missionControl, maxDepth: MissionControlMatching.RowMatching.maxTraversalDepth)
    return MissionControlMatching.desktopRows(in: node)
  }

  // MARK: Render

  /// #23: draws each label into the overlay window for whichever physical screen its Space's
  /// desktop button actually lands on (`MissionControlOverlayGeometry.screenFrame(containing:among:)`)
  /// rather than a single window sized to the primary screen — the fix for issue #23's item 3
  /// (previously any label for a Space on a non-primary display was silently clipped, since the
  /// old window never extended past the primary screen's bounds).
  ///
  /// #64: `rows` used to be one flattened, cross-display list keyed by `userIndex` alone —
  /// `userIndex` restarts at 0 *per display* (`Reconciler.resolve`), so two displays with two
  /// Spaces each produced duplicate keys and `Dictionary(uniqueKeysWithValues:)` trapped.
  ///
  /// All of the actual attribution — which screen a row belongs to, which CGS display identifier
  /// that screen maps to, which `ResolvedSpace` a button's structural index names — now happens
  /// inside `MissionControlRowResolution.resolve(rows:allSpaces:anchorScreenHeight:screenFrames:
  /// displayIDCandidates:)`, a pure function this method just calls and then draws the result of.
  /// PR #63's second review found the composition itself — not the pure helpers it called — was
  /// where two independent mutations (bypassing display attribution entirely, and reintroducing
  /// the flat, trapping dictionary) both slipped past the full test suite; routing every row
  /// through one pure, directly-tested call closes that gap (finding F4). This method must never
  /// touch `spacesByDisplayAndIndex`/`screenFrame`/display-ID resolution directly again.
  ///
  /// What's NOT fixed here, and is out of scope for this pass (documented, not silently dropped):
  /// whether Mission Control genuinely renders one Spaces Bar *per physical display* (as opposed
  /// to one shared row) remains unverified on this single-display machine — see
  /// `missionControlGroup(in:)`'s doc comment on the one candidate for structural per-display
  /// grouping (`mc.display`) this pass found but couldn't confirm multiplies per screen. Also
  /// unverified: whether `ScreenDisplayIdentity`'s UUID mapping stays correct once a second
  /// display attaches/detaches — see the PR body for exactly what's live-verified vs. reasoned.
  private func render(_ rows: [[(n: Int, rect: CGRect)]]) {
    guard let axAnchorScreen = axAnchorScreen() else { return }
    let screenFrames = NSScreen.screens.map(\.frame)
    syncWindows(toScreenFrames: screenFrames)
    clearAllWindows()

    // All display attribution (which screen, which CGS display identifier, which Space) happens
    // inside this one pure, directly-tested call — see its doc comment for why `render(_:)`
    // itself must never touch `spacesByDisplayAndIndex`/`screenFrame`/display-ID resolution again
    // (PR #63 review, finding F4).
    let labels = MissionControlRowResolution.resolve(
      rows: rows, allSpaces: spaces(), anchorScreenHeight: axAnchorScreen.frame.height,
      screenFrames: screenFrames, displayIDCandidates: displayIDCandidates)

    var frameKeysUsedThisTick: Set<String> = []
    for label in labels {
      guard
        let win = windowsByFrameKey[label.screenFrame.debugDescription],
        let content = win.contentView
      else { continue }
      let cocoaGlobal = MissionControlOverlayGeometry.cocoaGlobalRect(
        fromAX: label.axRect, mainScreenHeight: axAnchorScreen.frame.height)
      let local = MissionControlOverlayGeometry.localRect(cocoaGlobal, in: label.screenFrame)
      content.addSubview(
        makeLabel(space: label.space, over: local, screenSize: label.screenFrame.size))
      frameKeysUsedThisTick.insert(label.screenFrame.debugDescription)
    }
    orderFrontOnly(frameKeysUsedThisTick)
  }

  /// Live wrapper `MissionControlRowResolution.resolve` calls to turn a resolved screen frame
  /// into the ordered `"Display Identifier"` candidates to try against `SpaceService`'s topology
  /// — see `ScreenDisplayIdentity.cgsDisplayIDCandidates(for:)`'s doc comment (issue #64 / finding
  /// F2). `[]` if the frame doesn't match any currently-attached `NSScreen` at all.
  ///
  /// Nit (noted, not fixed): mirrored displays legitimately share one identical `frame`, so
  /// `first(where:)` here coin-flips between the mirror-set's members — benign for
  /// `cgsDisplayIDCandidates(for:)`'s own UUID/`"Main"` lookup only if every mirrored screen
  /// reports the same values, which hasn't been checked; worth confirming before relying on this
  /// for a real mirrored setup.
  private func displayIDCandidates(for screenFrame: CGRect) -> [String] {
    guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else { return [] }
    return ScreenDisplayIdentity.cgsDisplayIDCandidates(for: screen)
  }

  /// #22: shown in place of `render(_:)` when Mission Control is confirmed open but
  /// `desktopRects(in:)` couldn't structurally locate a desktop button row — see `tick()`. The
  /// only in-overlay affordance available here; the matching `log.warning` (see
  /// `missionControlGroup`/`tick`) is the durable record for diagnostics. Always anchored to the
  /// AX-anchor screen (the one with the menu bar) — this notice isn't tied to any particular
  /// Space's rect, so there's no per-screen placement question to answer.
  private func renderUnsupportedNotice() {
    if !hasLoggedDetectionFailure {
      log.warning(
        """
        MissionControlOverlay: Mission Control is open but no desktop button row was found \
        structurally — space names are unsupported for this Dock (possibly this display \
        language, possibly a Dock/macOS layout change).
        """
      )
      hasLoggedDetectionFailure = true
    }
    guard let axAnchorScreen = axAnchorScreen() else { return }
    let frame = axAnchorScreen.frame
    syncWindows(toScreenFrames: NSScreen.screens.map(\.frame))
    clearAllWindows()
    guard let win = windowsByFrameKey[frame.debugDescription], let content = win.contentView
    else { return }
    content.addSubview(makeNoticePill(screenSize: frame.size))
    orderFrontOnly([frame.debugDescription])
  }

  /// Shared rounded-pill chrome for both a per-Space name label and the unsupported-state
  /// notice — everything but the text and border color is identical between them.
  private func makePill(borderColor: NSColor) -> (pill: NSView, label: NSTextField) {
    let pill = NSView()
    pill.wantsLayer = true
    pill.layer?.backgroundColor = Self.bg.cgColor
    pill.layer?.cornerRadius = 9
    pill.layer?.borderWidth = 1
    pill.layer?.borderColor = borderColor.cgColor

    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = Self.text
    label.translatesAutoresizingMaskIntoConstraints = false
    pill.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
      label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
      label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
    ])
    return (pill, label)
  }

  /// `rect`/`screenSize` are both already in the target window's local (bottom-left origin)
  /// coordinate space — `screenSize` clamps the pill to stay on-screen near the top edge when the
  /// bar is collapsed, mirroring what the old primary-only clamp did, just per-screen now.
  private func makeLabel(space: ResolvedSpace, over rect: CGRect, screenSize: CGSize) -> NSView {
    let color = space.metadata?.colorHex.flatMap(NSColor.init(hex:)) ?? Self.lime
    let (pill, label) = makePill(borderColor: color.withAlphaComponent(0.9))
    label.stringValue = space.displayName

    let size = label.fittingSize
    let w = size.width + 18
    let h: CGFloat = 22
    // Center on the Space's column; keep the pill on-screen near the top when the bar is collapsed.
    let x = rect.midX - w / 2
    let y = min(rect.midY - h / 2, screenSize.height - h - 6)
    pill.frame = NSRect(x: x, y: max(y, 6), width: w, height: h)
    return pill
  }

  private func makeNoticePill(screenSize: CGSize) -> NSView {
    let (pill, label) = makePill(borderColor: Self.border.withAlphaComponent(0.9))
    label.stringValue = Constants.unsupportedMessage

    let size = label.fittingSize
    let w = size.width + 18
    let h: CGFloat = 22
    let x = screenSize.width / 2 - w / 2
    let y = screenSize.height - h - 40
    pill.frame = NSRect(x: x, y: y, width: w, height: h)
    return pill
  }

  // MARK: Window / geometry

  /// Reconciles `windowsByFrameKey` against the screens actually attached right now: creates a
  /// window for any new frame, and tears down (via `pruneWindows`) any window whose screen frame
  /// no longer exists — a display disconnected, or one just changed resolution/arrangement (which
  /// changes its `frame`, and therefore its key, too).
  private func syncWindows(toScreenFrames screenFrames: [CGRect]) {
    let currentKeys = Set(screenFrames.map(\.debugDescription))
    pruneWindows(keeping: currentKeys)
    for frame in screenFrames where windowsByFrameKey[frame.debugDescription] == nil {
      windowsByFrameKey[frame.debugDescription] = makeWindow(frame: frame)
    }
  }

  private func pruneWindows(keeping currentKeys: Set<String>) {
    for key in windowsByFrameKey.keys where !currentKeys.contains(key) {
      windowsByFrameKey[key]?.orderOut(nil)
      windowsByFrameKey.removeValue(forKey: key)
    }
  }

  private func makeWindow(frame: CGRect) -> NSWindow {
    let win = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    win.ignoresMouseEvents = true
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = false
    win.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
    return win
  }

  private func clearAllWindows() {
    for win in windowsByFrameKey.values {
      for view in win.contentView?.subviews ?? [] {
        view.removeFromSuperview()
      }
    }
  }

  /// Brings only the windows in `frameKeys` to the front; every other tracked window (nothing was
  /// drawn onto it this tick) is ordered out instead of left showing stale content.
  private func orderFrontOnly(_ frameKeys: Set<String>) {
    for (key, win) in windowsByFrameKey {
      if frameKeys.contains(key) {
        win.orderFrontRegardless()
      } else {
        win.orderOut(nil)
      }
    }
  }

  private func hide() {
    for win in windowsByFrameKey.values {
      win.orderOut(nil)
    }
  }

  /// The zero-origin (menu-bar) screen — the AX/Cocoa coordinate anchor. Named distinctly from
  /// `NSScreen.main` (which tracks key-window focus, not this): every AX/Cocoa global coordinate
  /// in this file is anchored to whichever screen sits at Cocoa origin `(0, 0)`, which is always
  /// the one with the menu bar, regardless of which window currently has focus.
  private func axAnchorScreen() -> NSScreen? {
    NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
  }
}
