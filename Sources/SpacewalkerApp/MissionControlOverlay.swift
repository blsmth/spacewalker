import AppKit
import ApplicationServices
import SpaceModel

/// Paints custom Space names **inside Mission Control** — the headline feature.
///
/// Mechanism (proven in the spike): poll the Dock's AX tree; while the `Mission Control` group
/// exists, read each `Desktop N` button rect from the `Spaces Bar`, map N → our Space, and draw a
/// name label over it via a window at `CGShieldingWindowLevel()` (which renders above MC).
@MainActor
final class MissionControlOverlay {

  private let spaces: () -> [ResolvedSpace]
  private var timer: Timer?
  private var window: NSWindow?
  /// The interval `timer` was last created with, so `scheduleTimer(for:)` only tears down and
  /// recreates it when the desired rate actually changes, instead of on every tick.
  private var currentInterval: TimeInterval?
  /// Cached so `tick()` doesn't re-run `NSRunningApplication.runningApplications` and rebuild the
  /// AX wrapper on every fire (#19) — only cleared when the Dock actually restarts, via
  /// `dockTerminationObserver` below.
  private var dockPID: pid_t?
  private var dockTerminationObserver: NSObjectProtocol?
  private var sleepWakeObservers: [NSObjectProtocol] = []
  /// True once a tick has actually found the "Mission Control" AX group — drives which of
  /// `Constants.activeInterval`/`idleInterval` the timer runs at (#19).
  private var isMissionControlOpen = false

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
    hide()
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
  /// Control is actually open (confirmed below by finding the "Mission Control" AX group);
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
    guard let dock = dockElement(),
      let mc = AXUtil.children(dock).first(where: {
        AXUtil.string($0, kAXTitleAttribute) == "Mission Control"
      })
    else {
      isMissionControlOpen = false
      scheduleTimer(for: Constants.idleInterval)
      hide()
      return
    }
    let rects = desktopRects(in: mc)
    guard !rects.isEmpty else {
      isMissionControlOpen = false
      scheduleTimer(for: Constants.idleInterval)
      hide()
      return
    }
    isMissionControlOpen = true
    scheduleTimer(for: Constants.activeInterval)
    render(rects)
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
    hide()
  }

  private func resumeAfterWake() {
    guard timer == nil else { return }  // already ticking — stay idempotent
    scheduleTimer(for: Constants.idleInterval)
  }

  /// (desktopNumber, AX-global rect) for each `Desktop N` button in the Spaces Bar.
  private func desktopRects(in missionControl: AXUIElement) -> [(n: Int, rect: CGRect)] {
    guard let spacesBar = AXUtil.firstDescendant(missionControl, title: "Spaces Bar") else {
      return []
    }
    var result: [(Int, CGRect)] = []
    collectDesktops(spacesBar, into: &result)
    return result
  }

  private func collectDesktops(
    _ element: AXUIElement, into result: inout [(Int, CGRect)], depth: Int = 0
  ) {
    guard depth < 6 else { return }
    for child in AXUtil.children(element) {
      if let title = AXUtil.string(child, kAXTitleAttribute),
        title.hasPrefix("Desktop "),
        let n = Int(title.dropFirst("Desktop ".count)),
        let frame = AXUtil.frame(child)
      {
        result.append((n, frame))
      }
      collectDesktops(child, into: &result, depth: depth + 1)
    }
  }

  // MARK: Render

  private func render(_ rects: [(n: Int, rect: CGRect)]) {
    let win = ensureWindow()
    guard let content = win.contentView, let primary = primaryScreen() else { return }
    for view in content.subviews { view.removeFromSuperview() }

    let byIndex = Dictionary(uniqueKeysWithValues: spaces().map { ($0.userIndex, $0) })
    for (n, axRect) in rects {
      guard let space = byIndex[n - 1] else { continue }  // Desktop N → userIndex N-1
      guard space.isCustomNamed else { continue }  // only show names we set
      let cocoa = cocoaRect(fromAX: axRect, primary: primary)
      content.addSubview(makeLabel(space: space, over: cocoa, primary: primary))
    }
    win.orderFrontRegardless()
  }

  private func makeLabel(space: ResolvedSpace, over rect: CGRect, primary: NSScreen) -> NSView {
    let color = space.metadata?.colorHex.flatMap(NSColor.init(hex:)) ?? Self.lime

    let pill = NSView()
    pill.wantsLayer = true
    pill.layer?.backgroundColor = Self.bg.cgColor
    pill.layer?.cornerRadius = 9
    pill.layer?.borderWidth = 1
    pill.layer?.borderColor = color.withAlphaComponent(0.9).cgColor

    let label = NSTextField(labelWithString: space.displayName)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = Self.text
    label.translatesAutoresizingMaskIntoConstraints = false
    pill.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
      label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
      label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
    ])

    let size = label.fittingSize
    let w = size.width + 18
    let h: CGFloat = 22
    // Center on the Space's column; keep the pill on-screen near the top when the bar is collapsed.
    let x = rect.midX - w / 2
    let y = min(rect.midY - h / 2, primary.frame.maxY - h - 6)
    pill.frame = NSRect(x: x, y: max(y, primary.frame.minY + 6), width: w, height: h)
    return pill
  }

  // MARK: Window / geometry

  private func ensureWindow() -> NSWindow {
    if let window { return window }
    let frame = primaryScreen()?.frame ?? .zero
    let win = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    win.ignoresMouseEvents = true
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = false
    win.contentView = NSView(frame: frame)
    window = win
    return win
  }

  private func hide() {
    window?.orderOut(nil)
  }

  /// The zero-origin (menu-bar) screen — the AX/Cocoa coordinate anchor.
  private func primaryScreen() -> NSScreen? {
    NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
  }

  /// AX global (top-left, y-down) → Cocoa global (bottom-left, y-up) for the primary display.
  private func cocoaRect(fromAX axRect: CGRect, primary: NSScreen) -> CGRect {
    CGRect(
      x: axRect.origin.x,
      y: primary.frame.height - axRect.origin.y - axRect.height,
      width: axRect.width, height: axRect.height)
  }
}
