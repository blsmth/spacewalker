import Foundation

/// Manages the macOS Mission Control preference that most affects a Spaces manager:
/// **"Automatically rearrange Spaces based on most recent use"** (`com.apple.dock` → `mru-spaces`).
///
/// With it on (the default), macOS constantly reorders Spaces by recency — so positions, "Desktop N"
/// numbers, and ⌃N mappings shuffle unpredictably. Spacewalker wants stable order, so it keeps this
/// off (user opted in). Applying it requires a Dock restart, so we only do that when we change it.
public enum MissionControlPrefs {

  private static let domain = "com.apple.dock"
  private static let key = "mru-spaces"

  /// True when auto-rearrange is enabled (defaults to true when the key is unset).
  public static var autoRearrangeEnabled: Bool {
    let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    return (value as? NSNumber)?.boolValue ?? true
  }

  /// Disable auto-rearrange and restart the Dock so it takes effect. No-op-safe to call when
  /// already disabled (caller should gate on `autoRearrangeEnabled` to avoid a needless restart).
  @discardableResult
  public static func disableAutoRearrange() -> Bool {
    CFPreferencesSetAppValue(key as CFString, kCFBooleanFalse, domain as CFString)
    CFPreferencesAppSynchronize(domain as CFString)
    return restartDock()
  }

  private static func restartDock() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["Dock"]
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
