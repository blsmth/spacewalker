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
  ///
  /// `element` belongs to the Dock, a process we don't control, so a `.success` result from
  /// `AXUIElementCopyAttributeValue` is not a guarantee the returned value is actually an
  /// `AXValue` wrapping a `CGPoint`/`CGSize` (see #21) — `point(from:)`/`size(from:)` below treat
  /// every step of unwrapping it as fallible and bail to `nil` rather than trap.
  static func frame(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
      let point = point(from: posRef),
      let size = size(from: sizeRef)
    else { return nil }
    return CGRect(origin: point, size: size)
  }

  /// Safely unwraps a `CFTypeRef?` believed to be an `AXValue` wrapping a `CGPoint`. Returns `nil`
  /// — never traps — if the value isn't an `AXValue`, wraps a different encoded type, or
  /// `AXValueGetValue` itself reports failure. Exposed (rather than folded into `frame(_:)`) so it
  /// can be exercised directly with hand-built `AXValue`/non-`AXValue` `CFTypeRef`s in tests
  /// without needing a live Dock AX tree.
  static func point(from ref: CFTypeRef?) -> CGPoint? {
    guard let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    // `AXValue` is a toll-free-bridged CF type, so `value as? AXValue` is a compile error
    // ("always succeeds") rather than a real runtime check — the CFGetTypeID comparison above is
    // the actual type check. `unsafeDowncast` is safe here only because that comparison already
    // confirmed `value`'s runtime type is `AXValue`.
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
  }

  /// Safely unwraps a `CFTypeRef?` believed to be an `AXValue` wrapping a `CGSize`. See
  /// `point(from:)` for the rationale — same guarded, trap-free path for the size attribute.
  static func size(from ref: CFTypeRef?) -> CGSize? {
    guard let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
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
