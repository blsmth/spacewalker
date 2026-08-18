import AppKit
import ApplicationServices

/// Thin helpers over the C Accessibility API. Used to read Mission Control's structure from the
/// Dock process (see `MissionControlOverlay`).
enum AXUtil {

  static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }

  static func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
      let children = value as? [AXUIElement]
    else { return [] }
    return children
  }

  /// Frame in AX global coordinates (top-left origin, y increasing downward).
  static func frame(_ element: AXUIElement) -> CGRect? {
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

  /// Depth-first search for the first descendant whose title equals `title` (optionally filtered
  /// by AX role). Bounded to keep traversal cheap.
  static func firstDescendant(
    _ element: AXUIElement, title: String, role: String? = nil,
    depth: Int = 0
  ) -> AXUIElement? {
    guard depth < 12 else { return nil }
    for child in children(element) {
      if string(child, kAXTitleAttribute) == title,
        role == nil || string(child, kAXRoleAttribute) == role
      {
        return child
      }
      if let found = firstDescendant(child, title: title, role: role, depth: depth + 1) {
        return found
      }
    }
    return nil
  }

  /// The Dock's process id, or nil if it isn't running. Cheap on its own — an in-process lookup
  /// against `NSWorkspace`'s already-tracked running-application list, no IPC into the Dock
  /// itself — but a caller that polls repeatedly (`MissionControlOverlay`) should still cache the
  /// result instead of calling this every tick (#19): use `dockElement(forPID:)` with the cached
  /// pid, and only call this again once you have reason to believe the Dock restarted.
  static func dockPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
      .first?.processIdentifier
  }

  /// The Dock's application AX element for an already-known pid. Trivial and local — the actual
  /// cost of talking to the Dock is in the `AXUIElementCopyAttributeValue` calls made against the
  /// returned element (e.g. `children(_:)`), not in constructing this wrapper.
  static func dockElement(forPID pid: pid_t) -> AXUIElement {
    AXUIElementCreateApplication(pid)
  }

  /// One-shot convenience: resolves the Dock's pid and wraps it, or nil if it isn't running.
  /// Callers that tick repeatedly should use `dockPID()` + `dockElement(forPID:)` with a cache
  /// instead — see their doc comments.
  static func dockElement() -> AXUIElement? {
    guard let pid = dockPID() else { return nil }
    return dockElement(forPID: pid)
  }
}
