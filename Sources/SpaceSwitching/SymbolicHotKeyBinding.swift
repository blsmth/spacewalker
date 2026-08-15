import Foundation

/// Shared, CFPreferences-free plumbing for reading a single entry out of
/// `com.apple.symbolichotkeys`'s `AppleSymbolicHotKeys` dictionary — the private per-id plist
/// format both `DesktopShortcuts` (ids 118…126, "Switch to Desktop N") and `MoveSpaceShortcuts`
/// (ids 79/81, "Move left/right a space") depend on.
///
/// This exists because of issue #6: `DesktopShortcuts.allEnabled` checked only the `enabled` flag,
/// while `DesktopShortcuts.plan` (the write path) already checked the *actual binding*. The two
/// checks silently disagreed — a user who rebound "Switch to Desktop 1" to ⌥1 still had
/// `enabled == 1`, so the read side said "go ahead, ⌃1 is bound", while the write side would
/// correctly have refused to touch it. Factoring the binding predicate out here means the read
/// path (`allEnabled`/`isSatisfied`) and the write path (`plan`) can never independently drift
/// apart like that again — there is exactly one definition of "is this bound to our target".
enum SymbolicHotKeyBinding {

  /// Control modifier mask as used in symbolichotkeys `parameters`
  /// (`NSEvent.ModifierFlags.control`, i.e. `1 << 18`).
  static let controlMask = 262_144

  /// macOS's placeholder for the "ASCII" slot of `parameters` when the bound key has no ASCII
  /// representation (arrows, function keys, etc.) — `0xFFFF`. Only used when *writing* a fresh
  /// entry for such a key (see `MoveSpaceShortcuts.target`); never compared when reading, because
  /// `isBoundToTarget` ignores it entirely (see its doc comment).
  static let nonPrintableAsciiPlaceholder = 0xFFFF

  /// True if `entry`'s `value.parameters` is bound to exactly Control+`keycode` — the only binding
  /// shape Spacewalker's synthesized ⌃-keystrokes actually invoke.
  ///
  /// Only compares `parameters[1]` (keycode) and `parameters[2]` (modifier mask); deliberately
  /// ignores `parameters[0]`. That first element is macOS's ASCII/glyph placeholder for the key —
  /// the literal character code for a printable key, or a sentinel like
  /// `nonPrintableAsciiPlaceholder` for arrows/function keys — but it plays no part in which
  /// physical key event the WindowServer actually delivers. Comparing it too would risk flagging a
  /// functionally-correct entry as a user "rebinding" (and leaving it alone as a false conflict)
  /// just because it was encoded with a different placeholder by a different macOS version or
  /// write path than the one Spacewalker uses.
  static func isBoundToTarget(_ entry: [String: Any]?, keycode: Int) -> Bool {
    guard let entry,
      let value = entry["value"] as? [String: Any],
      let parameters = value["parameters"] as? [Int],
      parameters.count == 3
    else { return false }
    return parameters[1] == keycode && parameters[2] == controlMask
  }

  /// True if `entry`'s `enabled` flag is set. Confirmed live on macOS 15
  /// (`defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys`) that macOS stores this as an
  /// `NSNumber` holding either `1`/`0` (entries System Settings has written) or `true`/`false`
  /// (entries still at their factory default) depending on which wrote the plist — `as? Int`
  /// bridges both losslessly, since `NSNumber`'s Swift bridging converts by value, not by the
  /// original ObjC type encoding.
  static func isEnabled(_ entry: [String: Any]?) -> Bool {
    (entry?["enabled"] as? Int) == 1
  }

  /// A `value` dict for `keycode` + Control, in the shape macOS itself writes.
  static func targetValue(asciiPlaceholder: Int, keycode: Int) -> [String: Any] {
    [
      "type": "standard",
      "parameters": [asciiPlaceholder, keycode, controlMask],
    ]
  }
}
