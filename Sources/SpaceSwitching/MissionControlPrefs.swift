import Foundation

/// Manages the macOS Mission Control preference that most affects a Spaces manager:
/// **"Automatically rearrange Spaces based on most recent use"** (`com.apple.dock` → `mru-spaces`).
///
/// With it on (the default), macOS constantly reorders Spaces by recency — so positions, "Desktop N"
/// numbers, and ⌃N mappings shuffle unpredictably. Spacewalker prefers this off, but only turns it
/// off after the user explicitly consents — `SystemPrefsCoordinator` is the only caller that should
/// invoke `disableAutoRearrange()` (see issue #2 / PLAN.md §4.7). Applying it requires a Dock
/// restart, so callers should gate on `autoRearrangeEnabled` to avoid a needless one.
public enum MissionControlPrefs {

  private static let domain = "com.apple.dock"
  private static let key = "mru-spaces"

  /// True when auto-rearrange is enabled (defaults to true when the key is unset).
  public static var autoRearrangeEnabled: Bool {
    let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    return (value as? NSNumber)?.boolValue ?? true
  }

  /// Disable auto-rearrange. Does not itself restart the Dock — see `restartDockAsync`, which
  /// callers should invoke afterward to make it take effect.
  public static func disableAutoRearrange() {
    CFPreferencesSetAppValue(key as CFString, kCFBooleanFalse, domain as CFString)
    CFPreferencesAppSynchronize(domain as CFString)
  }

  /// Restart the Dock so a preference change takes effect. Runs the subprocess off the main
  /// thread — this now fires from an explicit, user-consented action (the consent dialog or
  /// "Restore System Settings…"), never unannounced at launch — and reports the result back on
  /// the main actor.
  public static func restartDockAsync(completion: @escaping @MainActor (Bool) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      let ok = restartDockSync()
      DispatchQueue.main.async {
        MainActor.assumeIsolated { completion(ok) }
      }
    }
  }

  private static func restartDockSync() -> Bool {
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
