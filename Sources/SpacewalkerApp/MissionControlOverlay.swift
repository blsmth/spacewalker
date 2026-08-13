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

  private static let bg = NSColor(srgbRed: 0.06, green: 0.04, blue: 0.10, alpha: 0.92)
  private static let border = NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 0.85)
  private static let text = NSColor(srgbRed: 0.97, green: 0.96, blue: 1.0, alpha: 1)
  private static let lime = NSColor(srgbRed: 0.67, green: 0.93, blue: 0.29, alpha: 1)

  init(spaces: @escaping () -> [ResolvedSpace]) {
    self.spaces = spaces
  }

  func start() {
    guard timer == nil else { return }
    let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    hide()
  }

  // MARK: Poll

  private func tick() {
    guard let dock = AXUtil.dockElement(),
      let mc = AXUtil.children(dock).first(where: {
        AXUtil.string($0, kAXTitleAttribute) == "Mission Control"
      })
    else {
      hide()
      return
    }
    let rects = desktopRects(in: mc)
    guard !rects.isEmpty else {
      hide()
      return
    }
    render(rects)
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
    content.subviews.forEach { $0.removeFromSuperview() }

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
