import Foundation

/// Manages the macOS "Switch to Desktop N" keyboard shortcuts (⌃1…⌃9) that enable one-hop direct
/// jumps. These live in `com.apple.symbolichotkeys` as entries 118…126 (Desktop 1 = 118). We write
/// them ourselves (bound to ⌃N) and poke `activateSettings -u` so they apply **live, no logout** —
/// verified on macOS 15. The user opted into Spacewalker managing these (see PLAN.md §1).
public enum DesktopShortcuts {

  private static let domain = "com.apple.symbolichotkeys"
  private static let hotkeysKey = "AppleSymbolicHotKeys"

  /// Control modifier mask as used in symbolichotkeys parameters.
  private static let controlMask = 262144

  /// (ascii, keycode) for digit keys 1–9.
  private static let digitKey: [Int: (ascii: Int, keycode: Int)] = [
    1: (49, 18), 2: (50, 19), 3: (51, 20), 4: (52, 21), 5: (53, 23),
    6: (54, 22), 7: (55, 26), 8: (56, 28), 9: (57, 25),
  ]

  public static let maxDirectDesktop = 9

  /// symbolichotkeys entry id for "Switch to Desktop N".
  public static func symbolicID(desktop n: Int) -> Int { 117 + n }

  /// Keycode to synthesize for ⌃N.
  public static func keycode(desktop n: Int) -> Int? { digitKey[n]?.keycode }

  /// True if every desktop 1…`upTo` currently has an enabled shortcut entry.
  public static func allEnabled(upTo upperBound: Int) -> Bool {
    guard let dict = current() else { return false }
    return (1...upperBound).allSatisfy { n in
      (dict["\(symbolicID(desktop: n))"] as? [String: Any])?["enabled"] as? Int == 1
    }
  }

  /// Write ⌃1…⌃`upTo` shortcuts (preserving any other symbolichotkeys) and reload live.
  /// Returns false if the reload helper couldn't run.
  @discardableResult
  public static func enable(upTo upperBound: Int = maxDirectDesktop) -> Bool {
    var dict = current() ?? [:]
    for n in 1...upperBound {
      guard let key = digitKey[n] else { continue }
      dict["\(symbolicID(desktop: n))"] = [
        "enabled": 1,
        "value": [
          "type": "standard",
          "parameters": [key.ascii, key.keycode, controlMask],
        ],
      ]
    }
    CFPreferencesSetAppValue(hotkeysKey as CFString, dict as CFDictionary, domain as CFString)
    CFPreferencesAppSynchronize(domain as CFString)
    return reloadSettings()
  }

  private static func current() -> [String: Any]? {
    CFPreferencesCopyAppValue(hotkeysKey as CFString, domain as CFString) as? [String: Any]
  }

  /// Ask the settings system to re-read symbolic hotkeys without a logout.
  private static func reloadSettings() -> Bool {
    let path =
      "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["-u"]
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
