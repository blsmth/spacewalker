import Foundation

/// Decision layer between the raw preference-writing types (`DesktopShortcuts`,
/// `MissionControlPrefs`, `SystemPrefsBackup`) and the app. Nothing below this — not
/// `SpaceService`, not the switching layer — touches system preferences directly; this is the one
/// place that knows what WOULD change, gates every mutation behind explicit user consent, and owns
/// backup/restore. See issue #2 / PLAN.md §4.7.
public enum SystemPrefsCoordinator {

  /// One prospective system-preference change, described in plain language for a consent dialog.
  public struct Change: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
      case enableDesktopShortcuts
      case disableAutoRearrange
    }
    public let kind: Kind
    public let description: String
  }

  /// symbolichotkeys entry ids Spacewalker touches — desktops 1…`maxDirectDesktop`.
  private static let hotkeyIDs = (1...DesktopShortcuts.maxDirectDesktop).map {
    DesktopShortcuts.symbolicID(desktop: $0)
  }

  // MARK: Consent

  /// Sticky opt-in state. Once the user declines we never re-prompt on a later launch — only
  /// granting later (there is no UI path back to `notAsked` today) changes it again.
  public enum Consent: String, Sendable {
    case notAsked
    case granted
    case declined
  }

  private static let consentDefaultsKey = "SystemPrefsConsent"

  public static var consent: Consent {
    get {
      UserDefaults.standard.string(forKey: consentDefaultsKey).flatMap(Consent.init(rawValue:))
        ?? .notAsked
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: consentDefaultsKey) }
  }

  // MARK: What would change

  /// Exactly what would change on this machine right now. Empty means nothing to do — callers
  /// should skip the consent prompt entirely rather than showing an empty dialog.
  public static func pendingChanges() -> [Change] {
    var changes: [Change] = []
    if !DesktopShortcuts.allEnabled(upTo: DesktopShortcuts.maxDirectDesktop) {
      changes.append(
        Change(
          kind: .enableDesktopShortcuts,
          description:
            "Enable the ⌃1–⌃9 “Switch to Desktop N” keyboard shortcuts, so Spacewalker can jump "
            + "straight to any Space."))
    }
    if MissionControlPrefs.autoRearrangeEnabled {
      changes.append(
        Change(
          kind: .disableAutoRearrange,
          description:
            "Turn off “Automatically rearrange Spaces based on most recent use” in Mission "
            + "Control, so Space order and numbers stay stable. This restarts the Dock."))
    }
    return changes
  }

  /// True once a backup of the pristine pre-Spacewalker state exists — gates the
  /// "Restore System Settings…" menu item.
  public static func hasBackup() -> Bool {
    SystemPrefsBackup.exists()
  }

  // MARK: Apply

  /// Snapshot the machine's current state (a no-op if a backup already exists — see
  /// `SystemPrefsBackup.save`), apply every pending change, and reload/restart whatever's needed.
  /// `conflicts` lists the desktop numbers (1…9) whose shortcut was left alone because the user
  /// had already rebound it to something else. Calls `completion([])` immediately, with no writes
  /// at all, when `pendingChanges()` is already empty.
  @MainActor
  public static func apply(completion: @escaping @MainActor (_ conflicts: [Int]) -> Void) {
    let changes = pendingChanges()
    guard !changes.isEmpty else {
      completion([])
      return
    }

    SystemPrefsBackup.save(SystemPrefsBackup.capture(hotkeyIDs: hotkeyIDs))

    let needsHotkeys = changes.contains { $0.kind == .enableDesktopShortcuts }
    let needsDock = changes.contains { $0.kind == .disableAutoRearrange }
    let conflicts = needsHotkeys ? DesktopShortcuts.enable() : []
    if needsDock {
      MissionControlPrefs.disableAutoRearrange()
    }

    func finishDock() {
      if needsDock {
        MissionControlPrefs.restartDockAsync { _ in completion(conflicts) }
      } else {
        completion(conflicts)
      }
    }

    if needsHotkeys {
      DesktopShortcuts.reloadSettingsAsync { _ in finishDock() }
    } else {
      finishDock()
    }
  }

  // MARK: Restore

  /// Put system preferences back exactly as `SystemPrefsBackup` recorded them, then delete the
  /// backup file so a subsequent `apply()` can capture a fresh pristine snapshot if re-enabled.
  /// `completion(false)` means there was nothing to restore (no backup exists).
  @MainActor
  public static func restore(completion: @escaping @MainActor (Bool) -> Void) {
    guard let snapshot = SystemPrefsBackup.load() else {
      completion(false)
      return
    }
    let needsDockRestart = SystemPrefsBackup.restore(snapshot)
    SystemPrefsBackup.remove()
    DesktopShortcuts.reloadSettingsAsync { _ in
      if needsDockRestart {
        MissionControlPrefs.restartDockAsync { ok in completion(ok) }
      } else {
        completion(true)
      }
    }
  }
}
