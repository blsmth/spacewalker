import Foundation

/// Snapshot/restore of the system-wide preference state Spacewalker mutates, so enabling its
/// features never permanently alters a machine. See issue #2 / PLAN.md §4.7.
///
/// Two pieces of prior state are captured, each recording "was absent" as its own case — never
/// coerced into a concrete value — so `restore()` can put a key back exactly as it found it,
/// including removing it entirely if it never existed before Spacewalker touched it:
/// - `com.apple.dock` → `mru-spaces`
/// - `com.apple.symbolichotkeys` entries 118…126 ("Switch to Desktop N")
///
/// This type intentionally owns its own copies of those domain/key constants rather than reaching
/// into `DesktopShortcuts`/`MissionControlPrefs` — it captures and restores *pristine* state, which
/// is a different concern from those types' job of *applying* Spacewalker's preferred state, and
/// keeping them decoupled means a change to one write path can't silently affect the backup.
///
/// Persisted as a property list, not JSON: the symbolichotkeys entries are arbitrary nested
/// dictionaries (mixed `NSNumber`/`NSString`/`NSDictionary`/`NSArray`), and JSON has no lossless,
/// order-preserving representation for that shape. `PropertyListSerialization` round-trips the
/// exact values CFPreferences handed us.
public enum SystemPrefsBackup {

  // Deliberately duplicated from DesktopShortcuts/MissionControlPrefs — see the type doc comment.
  private static let dockDomain = "com.apple.dock"
  private static let mruKey = "mru-spaces"
  private static let hotkeysDomain = "com.apple.symbolichotkeys"
  private static let hotkeysKey = "AppleSymbolicHotKeys"

  /// One property's prior state: it either didn't exist, or held a specific value.
  public enum PriorValue {
    case absent
    case present(Any)
  }

  /// Everything captured before Spacewalker's first mutation.
  public struct Snapshot {
    public var mruSpaces: PriorValue
    /// Keyed by symbolichotkeys entry id (118…126), not desktop number.
    public var hotkeyEntries: [Int: PriorValue]

    public init(mruSpaces: PriorValue, hotkeyEntries: [Int: PriorValue]) {
      self.mruSpaces = mruSpaces
      self.hotkeyEntries = hotkeyEntries
    }
  }

  private enum Field {
    static let present = "present"
    static let value = "value"
    static let mruSpaces = "mruSpaces"
    static let hotkeys = "hotkeys"
  }

  /// Default backup location, alongside `spaces.json`.
  public static func defaultFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Spacewalker/system-prefs-backup.plist")
  }

  // MARK: File I/O

  /// True once a backup exists on disk. Gates the "Restore System Settings…" menu item, and
  /// guards `save` against ever clobbering the pristine snapshot with our own applied values.
  public static func exists(at fileURL: URL = defaultFileURL()) -> Bool {
    FileManager.default.fileExists(atPath: fileURL.path)
  }

  /// Write `snapshot` to disk — but only if no backup exists yet. The backup must capture the
  /// machine's state *before Spacewalker ever touched it*. If we let a second `save()` (e.g. a
  /// re-run of `apply()` after a topology change) overwrite the file, we'd replace the real
  /// pristine state with our own already-applied values, making `restore()` a permanent no-op.
  /// Returns false (and does not write) when a backup already exists.
  @discardableResult
  public static func save(_ snapshot: Snapshot, to fileURL: URL = defaultFileURL()) -> Bool {
    guard !exists(at: fileURL) else { return false }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: encode(snapshot), format: .xml, options: 0)
      try data.write(to: fileURL, options: .atomic)
      // `fileURL.path` embeds the macOS username.
      log.debug("Saved system prefs backup to \(fileURL.path, privacy: .private)")
      return true
    } catch {
      log.error(
        """
        Failed to save system prefs backup to \(fileURL.path, privacy: .private): \
        \(error, privacy: .private)
        """)
      return false
    }
  }

  /// Load a previously-saved snapshot, if any.
  public static func load(from fileURL: URL = defaultFileURL()) -> Snapshot? {
    guard let data = try? Data(contentsOf: fileURL),
      let plist =
        try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any],
      let snapshot = decode(plist)
    else {
      log.error(
        "Failed to load system prefs backup from \(fileURL.path, privacy: .private)")
      return nil
    }
    return snapshot
  }

  /// Delete the backup file, e.g. after a successful `restore()`.
  public static func remove(at fileURL: URL = defaultFileURL()) {
    try? FileManager.default.removeItem(at: fileURL)
  }

  // MARK: Capture (reads live CFPreferences — not covered by unit tests, see DesktopShortcuts)

  /// Read the current, pre-mutation value of `mru-spaces` and every hotkey id in `hotkeyIDs`.
  public static func capture(hotkeyIDs: [Int]) -> Snapshot {
    let mruRaw = CFPreferencesCopyAppValue(mruKey as CFString, dockDomain as CFString)
    let mru: PriorValue = mruRaw.map { .present($0) } ?? .absent

    let hotkeysDict =
      CFPreferencesCopyAppValue(hotkeysKey as CFString, hotkeysDomain as CFString)
      as? [String: Any]
    var entries: [Int: PriorValue] = [:]
    for id in hotkeyIDs {
      if let value = hotkeysDict?["\(id)"] {
        entries[id] = .present(value)
      } else {
        entries[id] = .absent
      }
    }
    return Snapshot(mruSpaces: mru, hotkeyEntries: entries)
  }

  // MARK: Restore (writes live CFPreferences — not covered by unit tests, see DesktopShortcuts)

  /// Put `snapshot`'s values back onto disk-backed system preferences, exactly as recorded —
  /// removing keys that were absent rather than writing some default. Returns true when
  /// `mru-spaces` actually changes as a result, meaning a Dock restart is needed to apply it.
  @discardableResult
  public static func restore(_ snapshot: Snapshot) -> Bool {
    restoreHotkeys(snapshot.hotkeyEntries)
    return restoreMRUSpaces(snapshot.mruSpaces)
  }

  private static func restoreHotkeys(_ entries: [Int: PriorValue]) {
    guard !entries.isEmpty else { return }
    var dict =
      (CFPreferencesCopyAppValue(hotkeysKey as CFString, hotkeysDomain as CFString)
        as? [String: Any]) ?? [:]
    for (id, prior) in entries {
      let key = "\(id)"
      switch prior {
      case .absent:
        dict.removeValue(forKey: key)
      case .present(let value):
        dict[key] = value
      }
    }
    CFPreferencesSetAppValue(
      hotkeysKey as CFString, dict as CFDictionary, hotkeysDomain as CFString)
    CFPreferencesAppSynchronize(hotkeysDomain as CFString)
  }

  private static func restoreMRUSpaces(_ prior: PriorValue) -> Bool {
    let before = CFPreferencesCopyAppValue(mruKey as CFString, dockDomain as CFString)
    switch prior {
    case .absent:
      guard before != nil else { return false }  // already absent — nothing changes
      CFPreferencesSetAppValue(mruKey as CFString, nil, dockDomain as CFString)
    case .present(let value):
      if let beforeNumber = before as? NSNumber, let valueNumber = value as? NSNumber,
        beforeNumber.boolValue == valueNumber.boolValue
      {
        return false  // already matches — nothing to restart for
      }
      CFPreferencesSetAppValue(mruKey as CFString, value as AnyObject, dockDomain as CFString)
    }
    CFPreferencesAppSynchronize(dockDomain as CFString)
    return true
  }

  // MARK: Plist encode/decode (pure — unit tested)

  static func encode(_ snapshot: Snapshot) -> [String: Any] {
    var hotkeys: [String: Any] = [:]
    for (id, prior) in snapshot.hotkeyEntries {
      hotkeys["\(id)"] = encode(prior)
    }
    return [
      Field.mruSpaces: encode(snapshot.mruSpaces),
      Field.hotkeys: hotkeys,
    ]
  }

  private static func encode(_ prior: PriorValue) -> [String: Any] {
    switch prior {
    case .absent:
      return [Field.present: false]
    case .present(let value):
      return [Field.present: true, Field.value: value]
    }
  }

  static func decode(_ plist: [String: Any]) -> Snapshot? {
    guard
      let mruDict = plist[Field.mruSpaces] as? [String: Any],
      let hotkeysDict = plist[Field.hotkeys] as? [String: Any]
    else { return nil }
    var hotkeyEntries: [Int: PriorValue] = [:]
    for (key, value) in hotkeysDict {
      guard let id = Int(key), let entryDict = value as? [String: Any] else { continue }
      hotkeyEntries[id] = decode(entryDict)
    }
    return Snapshot(mruSpaces: decode(mruDict), hotkeyEntries: hotkeyEntries)
  }

  private static func decode(_ dict: [String: Any]) -> PriorValue {
    guard dict[Field.present] as? Bool == true else { return .absent }
    return .present(dict[Field.value] as Any)
  }
}
