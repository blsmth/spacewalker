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
  /// `rect` actually belongs on — matched by whether that screen's frame contains `rect`'s
  /// center. `nil` when no screen claims it (e.g. a coordinate that lands in the gap between two
  /// non-adjacent displays in an unusual arrangement) — deliberately NOT defaulting to the first/
  /// main screen: silently drawing a label in the wrong place is exactly the bug issue #23 reports
  /// (a label that only ever renders correctly relative to the primary display), so an unplaceable
  /// rect must be dropped, not guessed at.
  static func screenFrame(containing rect: CGRect, among screenFrames: [CGRect]) -> CGRect? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return screenFrames.first(where: { $0.contains(center) })
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
  /// as the ideal — deliberately: this app can't be run or have Mission Control opened as part of
  /// this change, so there's no way to verify an observer against the Dock actually fires for
  /// this specific case (a system-owned process's internal MC group, not one of its own windows,
  /// which is the well-documented, common use of these notifications). Shipping an unverified
  /// observer risks silently disabling the overlay outright — this app's headline feature — with
  /// no fallback if it turns out unreliable on some macOS version. A reduced-but-nonzero idle poll
  /// that is trivially correct by inspection is the safer trade here; a future pass with the
  /// ability to actually open Mission Control against a running build should attempt the
  /// observer and only keep this as the fallback path if it proves unreliable.
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
  /// Verified live on this (English, macOS) system today: with Mission Control closed, the
  /// Dock's `AXApplication` element has exactly one direct child, an `AXList` — no `AXGroup` —
  /// so matching on role here is at least as precise as the old title check for the closed case.
  /// I could not get Mission Control to actually open in this environment (see the doc comment
  /// on `tick()`), so the shape of the tree *while MC is open* is reasoned from the prior spike
  /// (PLAN.md §4.3, confirmed live on macOS 15 previously) rather than re-verified here — the
  /// Dock did not expose an `AXIdentifier` on any element I could inspect (checked, not assumed;
  /// see `AXUtilTests` / the PR description for what that dump showed).
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
  /// Reasoned, not re-verified live (see `missionControlGroup(in:)`): the prior spike documented
  /// the Spaces Bar as "an `AXButton 'Desktop N'` per Space with an exact rect (evenly spaced
  /// across the top, in desktop order)" (PLAN.md §4.3) — i.e. already a uniform, left-to-right
  /// row by construction, which is exactly what `MissionControlMatching.allButtonRows` looks for.
  /// Whether Mission Control genuinely renders one such row *per physical display* rather than
  /// one shared row is itself unverified on this single-display machine — see the PR body.
  private func desktopRows(in missionControl: AXUIElement) -> [[(n: Int, rect: CGRect)]] {
    MissionControlMatching.desktopRows(in: axNode(missionControl, depth: 0))
  }

  /// Recursively snapshots a live `AXUIElement` subtree into the plain `AXNode` value type
  /// `MissionControlMatching` operates on, bounded to
  /// `MissionControlMatching.RowMatching.maxTraversalDepth` (see its doc comment for why that's
  /// 12, not the previous `collectDesktops`'s 6). This is the one place in the file that crosses
  /// from the cross-process AX world into pure, testable data.
  private func axNode(_ element: AXUIElement, depth: Int) -> AXNode {
    let role = AXUtil.string(element, kAXRoleAttribute)
    let title = AXUtil.string(element, kAXTitleAttribute)
    let frame = AXUtil.frame(element)
    guard depth < MissionControlMatching.RowMatching.maxTraversalDepth else {
      return AXNode(role: role, title: title, frame: frame)
    }
    let children = AXUtil.children(element).map { axNode($0, depth: depth + 1) }
    return AXNode(role: role, title: title, frame: frame, children: children)
  }

  // MARK: Render

  /// #23: draws each label into the overlay window for whichever physical screen its Space's
  /// desktop button actually lands on (`MissionControlOverlayGeometry.screenFrame(containing:among:)`)
  /// rather than a single window sized to the primary screen — the fix for issue #23's item 3
  /// (previously any label for a Space on a non-primary display was silently clipped, since the
  /// old window never extended past the primary screen's bounds).
  ///
  /// #64: `rects` used to be one flattened, cross-display list keyed by `userIndex` alone —
  /// `userIndex` restarts at 0 *per display* (`Reconciler.resolve`), so two displays with two
  /// Spaces each produced duplicate keys and `Dictionary(uniqueKeysWithValues:)` trapped. Now
  /// operates one *row* at a time: each row's owning display is resolved once (via whichever
  /// physical screen the row's buttons sit on, mapped to CGS's own display identifier — see
  /// `ScreenDisplayIdentity`), and `n` is only ever looked up within that display's own Spaces.
  /// `Dictionary(_:uniquingKeysWith:)` never traps regardless, so an unexpected topology
  /// (duplicate `userIndex` even within one resolved display, which shouldn't happen but isn't
  /// re-derived here) degrades to "first one wins" instead of crashing.
  ///
  /// What's NOT fixed here, and is out of scope for this pass (documented, not silently dropped):
  /// whether Mission Control genuinely renders one Spaces Bar *per physical display* (as opposed
  /// to one shared row) is unverified on this single-display machine, as is whether
  /// `ScreenDisplayIdentity`'s public-API UUID mapping stays correct once a second display
  /// attaches/detaches — see the PR body for exactly what's live-verified vs. reasoned.
  private func render(_ rows: [[(n: Int, rect: CGRect)]]) {
    guard let axAnchorScreen = axAnchorScreen() else { return }
    let screenFrames = NSScreen.screens.map(\.frame)
    syncWindows(toScreenFrames: screenFrames)
    clearAllWindows()

    let byDisplayAndIndex = MissionControlOverlayGeometry.spacesByDisplayAndIndex(spaces())
    var frameKeysUsedThisTick: Set<String> = []

    for row in rows {
      guard
        let rowDisplayID = displayID(
          forRow: row, anchorScreenHeight: axAnchorScreen.frame.height, among: screenFrames),
        let spacesByIndex = byDisplayAndIndex[rowDisplayID]
      else { continue }  // unplaceable row, or its screen doesn't resolve to a known display

      for (n, axRect) in row {
        guard let space = spacesByIndex[n - 1] else { continue }  // Desktop N → userIndex N-1
        guard space.isCustomNamed else { continue }  // only show names we set
        let cocoaGlobal = MissionControlOverlayGeometry.cocoaGlobalRect(
          fromAX: axRect, mainScreenHeight: axAnchorScreen.frame.height)
        guard
          let screenFrame = MissionControlOverlayGeometry.screenFrame(
            containing: cocoaGlobal, among: screenFrames),
          let win = windowsByFrameKey[screenFrame.debugDescription],
          let content = win.contentView
        else { continue }  // unplaceable rect — see screenFrame(containing:among:)'s doc comment

        let local = MissionControlOverlayGeometry.localRect(cocoaGlobal, in: screenFrame)
        content.addSubview(makeLabel(space: space, over: local, screenSize: screenFrame.size))
        frameKeysUsedThisTick.insert(screenFrame.debugDescription)
      }
    }
    orderFrontOnly(frameKeysUsedThisTick)
  }

  /// Which display's Spaces `row`'s buttons actually belong to, resolved once per row rather
  /// than once per button — every button in `row` already shares one physical screen, since
  /// `MissionControlMatching.uniformRow` rejects any row whose buttons aren't x-contiguous
  /// (issue #64). `nil` if the row's screen can't be placed among `screenFrames`, or that screen
  /// doesn't resolve to a CGS display identifier at all (see `ScreenDisplayIdentity`).
  private func displayID(
    forRow row: [(n: Int, rect: CGRect)], anchorScreenHeight: CGFloat, among screenFrames: [CGRect]
  ) -> String? {
    guard let anchorRect = row.first?.rect else { return nil }
    let cocoaGlobal = MissionControlOverlayGeometry.cocoaGlobalRect(
      fromAX: anchorRect, mainScreenHeight: anchorScreenHeight)
    guard
      let screenFrame = MissionControlOverlayGeometry.screenFrame(
        containing: cocoaGlobal, among: screenFrames),
      let screen = NSScreen.screens.first(where: { $0.frame == screenFrame })
    else { return nil }
    return ScreenDisplayIdentity.cgsDisplayID(for: screen)
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
