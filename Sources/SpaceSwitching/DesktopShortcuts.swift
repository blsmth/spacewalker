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
  /// and reports the result back on the main actor, bounded by `Constants.subprocessTimeout` so a
  /// hung `activateSettings` can never leave the consent flow waiting forever (see issue #20).
  public static func reloadSettingsAsync(completion: @escaping @MainActor (Bool) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      let path =
        "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
      guard FileManager.default.isExecutableFile(atPath: path) else {
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(false) } }
        return
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = ["-u"]
      runProcessBounded(process, timeout: Constants.subprocessTimeout) { ok in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { completion(ok) }
        }
      }
    }
  }
}

extension DesktopShortcuts {

  private enum Constants {
    /// `activateSettings -u` only asks a running system daemon to re-read one preference domain
    /// over local IPC — under normal conditions it returns in well under a second. 5s gives
    /// generous headroom for scheduling delays under memory pressure while still bounding the
    /// wait to something far short of what a user watching the consent dialog would need to
    /// conclude the app has hung (see issue #20). `MissionControlPrefs.restartDockAsync` uses the
    /// same value for the same reasoning — `killall Dock` is an even lighter operation.
    static let subprocessTimeout: TimeInterval = 5
  }

  /// Runs `process`, invoking `completion` exactly once: after it exits normally, after
  /// `process.run()` throws, or after `timeout` elapses with no exit — whichever happens first.
  /// `completion` runs on whatever queue resolves it (the process's own termination queue, or the
  /// timeout's utility queue); callers that need a specific queue/actor must hop themselves,
  /// exactly as `reloadSettingsAsync`/`restartDockAsync` already do for the main actor.
  ///
  /// `Process.terminationHandler` firing and the timeout deadline elapsing are two independent
  /// events racing to resolve the same outcome — `SingleResolution` guarantees whichever comes
  /// first wins and the other is silently discarded, so `completion` can never fire twice and can
  /// never fail to fire at all.
  ///
  /// On timeout, the process is sent SIGTERM rather than left to finish on its own schedule:
  /// both `killall` and `activateSettings` only send a signal or make a short IPC call, so once
  /// we've decided to stop waiting there is no in-flight work worth letting complete, and an
  /// abandoned hung subprocess is worse than one we deliberately killed. If the process has
  /// already exited by the time the deadline fires, `terminate()` on it is a harmless no-op.
  ///
  /// Declared here rather than in a small shared file of its own because issue #20 scoped this
  /// fix to `DesktopShortcuts.swift` and `MissionControlPrefs.swift` only — both need it, and
  /// this type is the natural home for it since it owns the module's other subprocess helper.
  /// A future refactor extracting a general-purpose `SubprocessRunner` type would be reasonable.
  static func runProcessBounded(
    _ process: Process, timeout: TimeInterval, completion: @escaping (Bool) -> Void
  ) {
    let resolution = SingleResolution<Bool>(completion: completion)

    process.terminationHandler = { proc in
      resolution.resolve(proc.terminationStatus == 0)
    }

    do {
      try process.run()
    } catch {
      resolution.resolve(false)
      return
    }

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
      process.terminate()
      resolution.resolve(false)
    }
  }
}

/// Delivers exactly one result to `completion`, whichever of two racing events resolves first.
/// Exists to guard against exactly the race described in issue #20: a subprocess's
/// `terminationHandler` firing at nearly the same moment a timeout deadline elapses. Kept free of
/// `Process`, `DispatchQueue`, or wall-clock time so it is directly unit-testable — tests can call
/// `resolve` from either "side" of the race, in either order, from any thread, without spawning a
/// real subprocess or sleeping for a real timeout (see `SingleResolutionTests`).
final class SingleResolution<Result>: @unchecked Sendable {
  private let lock = NSLock()
  private var settled = false
  private var completion: ((Result) -> Void)?

  init(completion: @escaping (Result) -> Void) {
    self.completion = completion
  }

  /// Deliver `result` to the completion handler, unless a prior call already has. Safe to call
  /// from any thread, any number of times — only the first call after `init` has any effect.
  func resolve(_ result: Result) {
    lock.lock()
    let alreadySettled = settled
    settled = true
    let handler = alreadySettled ? nil : completion
    completion = nil
    lock.unlock()
    handler?(result)
  }
}
