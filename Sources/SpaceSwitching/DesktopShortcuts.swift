import Foundation

/// Manages the macOS "Switch to Desktop N" keyboard shortcuts (⌃1…⌃9) that enable one-hop direct
/// jumps. These live in `com.apple.symbolichotkeys` as entries 118…126 (Desktop 1 = 118). We write
/// them ourselves (bound to ⌃N) and poke `activateSettings -u` so they apply **live, no logout** —
/// verified on macOS 15.
///
/// Writes are **non-clobbering** (see `plan`): an entry is only touched if it's currently
/// absent/disabled, or already bound to exactly our target. An entry that's enabled and bound to
/// something else means the user deliberately rebound "Switch to Desktop N" themselves, and is
/// left alone. `SystemPrefsCoordinator` is the only caller that should ever invoke `enable()` —
/// it gates the write behind explicit user consent (see issue #2 / PLAN.md §4.7).
public enum DesktopShortcuts {

  private static let domain = "com.apple.symbolichotkeys"
  private static let hotkeysKey = "AppleSymbolicHotKeys"

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

  /// True if every desktop 1…`upTo` is both enabled AND actually bound to ⌃N (issue #6 — this used
  /// to check only `enabled`, which a user who rebound "Switch to Desktop N" to something else
  /// still satisfied, so `switchToDesktop` would synthesize a ⌃N bound to nothing and report a
  /// silent no-op as success).
  public static func allEnabled(upTo upperBound: Int) -> Bool {
    isSatisfied(existing: current() ?? [:], upTo: upperBound)
  }

  /// Pure read-side counterpart to `plan`: true if every desktop 1…`upTo` in `existing` is enabled
  /// and bound to exactly ⌃N. Kept free of CFPreferences, mirroring `plan`, so it's unit-testable
  /// and the read path can never independently drift from what `plan` considers "ours" on the
  /// write path — see `SymbolicHotKeyBinding`.
  static func isSatisfied(existing: [String: Any], upTo upperBound: Int) -> Bool {
    (1...upperBound).allSatisfy { n in
      guard let keycode = digitKey[n]?.keycode else { return false }
      let entry = existing["\(symbolicID(desktop: n))"] as? [String: Any]
      return SymbolicHotKeyBinding.isEnabled(entry)
        && SymbolicHotKeyBinding.isBoundToTarget(entry, keycode: keycode)
    }
  }

  /// Pure planning step: given the current `AppleSymbolicHotKeys` dictionary, decide the updated
  /// dictionary to write for desktops 1…`upTo`. An entry is written only if it's currently
  /// absent/disabled, or already bound to exactly ⌃N (a harmless no-op rewrite). An entry that's
  /// enabled and bound to something else is left untouched, and its desktop number is reported in
  /// `conflicts` instead — the user rebound it on purpose and we must not silently take it back.
  /// Kept free of CFPreferences so it's fully unit-testable; `enable()` is a thin wrapper around it.
  static func plan(existing: [String: Any], upTo upperBound: Int) -> (
    updated: [String: Any], conflicts: [Int]
  ) {
    var dict = existing
    var conflicts: [Int] = []
    for n in 1...upperBound {
      guard let key = digitKey[n] else { continue }
      let id = "\(symbolicID(desktop: n))"
      let target: [String: Any] = [
        "enabled": 1,
        "value": SymbolicHotKeyBinding.targetValue(
          asciiPlaceholder: key.ascii, keycode: key.keycode),
      ]
      guard let entry = dict[id] as? [String: Any] else {
        dict[id] = target  // absent — safe to write
        continue
      }
      let isEnabled = SymbolicHotKeyBinding.isEnabled(entry)
      if !isEnabled || SymbolicHotKeyBinding.isBoundToTarget(entry, keycode: key.keycode) {
        dict[id] = target
      } else {
        conflicts.append(n)
      }
    }
    return (dict, conflicts)
  }

  /// Write ⌃1…⌃`upTo` shortcuts, preserving any other symbolichotkeys and never clobbering a
  /// deliberate user rebinding (see `plan`). Returns the desktop numbers left alone as conflicts
  /// (empty means every desktop 1…`upTo` is now bound to ⌃N). Callers must reload live settings
  /// afterward — see `reloadSettingsAsync` — this only writes the preference.
  @discardableResult
  public static func enable(upTo upperBound: Int = maxDirectDesktop) -> [Int] {
    let (updated, conflicts) = plan(existing: current() ?? [:], upTo: upperBound)
    CFPreferencesSetAppValue(hotkeysKey as CFString, updated as CFDictionary, domain as CFString)
    CFPreferencesAppSynchronize(domain as CFString)
    return conflicts
  }

  private static func current() -> [String: Any]? {
    CFPreferencesCopyAppValue(hotkeysKey as CFString, domain as CFString) as? [String: Any]
  }

  /// Ask the settings system to re-read symbolic hotkeys without a logout. Runs the subprocess off
  /// the main thread — this is now triggered by an explicit, user-consented action (the consent
  /// dialog or "Restore System Settings…"), never by launch, so there's no excuse to block it —
  /// and reports the result back on the main actor.
  public static func reloadSettingsAsync(completion: @escaping @MainActor (Bool) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      let ok = reloadSettingsSync()
      DispatchQueue.main.async {
        MainActor.assumeIsolated { completion(ok) }
      }
    }
  }

  private static func reloadSettingsSync() -> Bool {
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
