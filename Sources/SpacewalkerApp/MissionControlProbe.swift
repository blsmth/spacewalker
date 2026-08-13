import AppKit
import ApplicationServices

/// Feasibility probe for the headline "names inside Mission Control" feature. Answers two unknowns:
///  1. Can any window render ABOVE Mission Control? (overlay at `CGShieldingWindowLevel()`)
///  2. Are the Space-thumbnail rects readable so we could position labels? (AX dump of the Dock)
///
/// Nothing here is production — it's a yes/no probe. Toggle from the menu, open Mission Control,
/// and observe whether the marker shows on top; dump the Dock AX tree while MC is open.
@MainActor
final class MissionControlProbe {

  private var overlay: NSWindow?

  var isOverlayVisible: Bool { overlay != nil }

  // MARK: 1. Can we draw above Mission Control?

  func toggleOverlay() {
    if let overlay {
      overlay.orderOut(nil)
      self.overlay = nil
      return
    }
    guard let screen = NSScreen.main else { return }

    let win = NSWindow(
      contentRect: screen.frame, styleMask: [.borderless],
      backing: .buffered, defer: false)
    // The key experiment: the shielding level is what screen savers use — above ~everything.
    win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    win.ignoresMouseEvents = true
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = false

    let content = NSView(frame: screen.frame)
    content.wantsLayer = true
    content.layer?.borderWidth = 8
    content.layer?.borderColor =
      NSColor(srgbRed: 0.67, green: 0.93, blue: 0.29, alpha: 0.95).cgColor

    let banner = NSTextField(
      labelWithString:
        "SPACEWALKER OVERLAY PROBE  —  open Mission Control: can you still see this bar & the lime border?"
    )
    banner.font = .systemFont(ofSize: 18, weight: .bold)
    banner.textColor = .white
    banner.alignment = .center
    banner.wantsLayer = true
    banner.drawsBackground = true
    banner.backgroundColor = NSColor(srgbRed: 0.49, green: 0.24, blue: 0.93, alpha: 0.95)
    banner.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(banner)
    NSLayoutConstraint.activate([
      banner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      banner.topAnchor.constraint(equalTo: content.topAnchor, constant: 120),
      banner.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.9),
      banner.heightAnchor.constraint(equalToConstant: 44),
    ])
    win.contentView = content
    win.orderFrontRegardless()
    overlay = win
  }

  // MARK: 2. Are Space-thumbnail rects readable via the Dock's accessibility tree?

  /// Dump the Dock's AX tree (roles + frames) to /tmp/spacewalker-mc-ax.txt. Run WHILE Mission
  /// Control is open to see whether the Space tiles are exposed as elements with usable frames.
  @discardableResult
  func dumpDockAX() -> String {
    guard
      let dock = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      return "Dock process not found"
    }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    var out = "Dock AX dump @ \(Date())\n"
    dumpElement(app, depth: 0, into: &out)
    let url = URL(fileURLWithPath: "/tmp/spacewalker-mc-ax.txt")
    try? out.write(to: url, atomically: true, encoding: .utf8)
    return "Wrote \(out.count) chars to \(url.path)"
  }

  private func dumpElement(_ element: AXUIElement, depth: Int, into out: inout String) {
    guard depth < 10 else { return }
    let role = axString(element, kAXRoleAttribute) ?? "?"
    let subrole = axString(element, kAXSubroleAttribute)
    let title = axString(element, kAXTitleAttribute) ?? axString(element, kAXDescriptionAttribute)
    let frame = axFrame(element)
    let pad = String(repeating: "  ", count: depth)
    var line = "\(pad)\(role)"
    if let subrole { line += " [\(subrole)]" }
    if let title, !title.isEmpty { line += " '\(title)'" }
    if let frame {
      line +=
        "  @\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
    }
    out += line + "\n"

    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
      == .success,
      let children = childrenRef as? [AXUIElement]
    {
      for child in children.prefix(60) {
        dumpElement(child, depth: depth + 1, into: &out)
      }
    }
  }

  private func axString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func axFrame(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
  }
}
