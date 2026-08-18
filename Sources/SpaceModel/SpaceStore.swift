import Foundation

/// Persists per-Space metadata, keyed by identity rather than by any single field of it.
///
/// Serialized as `{ schemaVersion, records }` JSON at
/// `~/Library/Application Support/Spacewalker/spaces.json`. Missing Spaces are **kept, not
/// deleted**, so replugging a display or rebooting restores custom names. Pass `fileURL: nil` for
/// an in-memory store (tests).
///
/// Two correctness properties this type exists to guarantee (issues #16, #17):
/// - A store that fails to load is never mistaken for an empty one. `read` distinguishes "no file
///   yet" (fine, nothing to load) from "file exists but couldn't be understood" (never overwrite
///   it — see `persistenceBlocked`). A corrupt/unreadable file is quarantined by rename so the
///   original bytes survive for recovery, and a rolling backup is written before every persist so
///   a bad write never destroys the last-known-good state either.
/// - A record's identity survives both directions Apple's Space ids can drift: a Space that used
///   to report an empty `uuid` starting to report a real one (self-heals onto it, see
///   `existingRecord`), and an `id64` being reused by an unrelated new Space after the old one is
///   destroyed (does NOT inherit the old name, because a record that already carries a real uuid
///   is never reachable by `id64` alone — see the `byID64` invariant below).
public final class SpaceStore {

  /// Records whose `uuid` is known. The authoritative index once a Space has ever reported one.
  private var byUUID: [String: SpaceRecord] = [:]
  /// Records that have **never** carried a uuid — the only entries eligible for the `id64`
  /// self-heal migration in `existingRecord`. A record leaves this dictionary the moment it gains
  /// a uuid and never returns to it, which is exactly what keeps a later, unrelated Space that
  /// reuses the same `id64` from inheriting a name that belongs to a Space with a known uuid.
  private var byID64: [Int: SpaceRecord] = [:]
  private let fileURL: URL?
  /// Set once loading the on-disk file failed in a way that must not be compounded by writing
  /// over it — see the type doc comment. There is deliberately no path that clears this within a
  /// run: the whole point is that persisting is refused until a human has looked at the
  /// quarantined file, and this process has no channel to learn that happened.
  private var persistenceBlocked = false

  private enum Constants {
    static let schemaVersion = 1
  }

  public init(fileURL: URL?) {
    self.fileURL = fileURL
    let outcome = SpaceStore.load(from: fileURL)
    for record in outcome.records {
      SpaceStore.index(record, intoUUID: &byUUID, id64: &byID64)
    }
    persistenceBlocked = outcome.blocksPersistence
    // Legacy on-disk data migrates in memory immediately above; write it back in the current
    // envelope shape right away so a process that loads-but-never-edits still leaves the store in
    // the new format, rather than silently relying on `read` to keep understanding the old one.
    if outcome.needsRewrite {
      persist()
    }
  }

  // MARK: Lookup

  public func metadata(for identity: SpaceIdentity) -> SpaceMetadata? {
    existingRecord(for: identity)?.metadata
  }

  /// Identity-style keys for every record currently held, in the historical `"uuid:…"` /
  /// `"id64:…"` shape (not read back by anything — kept only because it was public API).
  public var allKeys: [String] {
    byUUID.keys.map { "uuid:\($0)" } + byID64.keys.map { "id64:\($0)" }
  }

  // MARK: Mutation (auto-persists)

  /// Set the custom name. Passing nil/empty clears it (and drops the entry if nothing remains).
  public func setName(_ name: String?, for identity: SpaceIdentity) {
    update(identity) { $0.name = (name?.isEmpty ?? true) ? nil : name }
  }

  public func setSymbol(_ symbolName: String?, for identity: SpaceIdentity) {
    update(identity) { $0.symbolName = (symbolName?.isEmpty ?? true) ? nil : symbolName }
  }

  public func setColor(_ colorHex: String?, for identity: SpaceIdentity) {
    update(identity) { $0.colorHex = (colorHex?.isEmpty ?? true) ? nil : colorHex }
  }

  private func update(_ identity: SpaceIdentity, _ mutate: (inout SpaceMetadata) -> Void) {
    var record =
      existingRecord(for: identity)
      ?? SpaceRecord(uuid: identity.uuid, id64: identity.id64, metadata: SpaceMetadata())
    var metadata = record.metadata
    mutate(&metadata)
    record.metadata = metadata
    if metadata.isEmpty {
      remove(record)
    } else {
      SpaceStore.index(record, intoUUID: &byUUID, id64: &byID64)
    }
    persist()
  }

  private func remove(_ record: SpaceRecord) {
    if record.uuid.isEmpty {
      if let id64 = record.id64 { byID64.removeValue(forKey: id64) }
    } else {
      byUUID.removeValue(forKey: record.uuid)
    }
  }

  /// Finds the live record for `identity`, self-healing a legacy id64-only record onto the uuid
  /// the OS now reports for it (issue #17, failure mode 1) so a name never goes dark just because
  /// Apple started reporting a UUID for a Space that previously lacked one.
  ///
  /// This is the ONLY place a record's identity fields change after creation, and the migration
  /// persists immediately — even though this is nominally a read — so it survives relaunch even
  /// if the caller never happens to write through `setName`/`setSymbol`/`setColor` afterwards.
  ///
  /// Deliberately does NOT fall back to `id64` for a record that already carries a real uuid:
  /// once a record has one, it is removed from `byID64` (see `index` below) and is therefore
  /// unreachable by `id64` alone. That is what stops issue #17 failure mode 2 — an unrelated new
  /// Space reusing a destroyed Space's `id64` — from inheriting the destroyed Space's name.
  private func existingRecord(for identity: SpaceIdentity) -> SpaceRecord? {
    if !identity.uuid.isEmpty, let record = byUUID[identity.uuid] {
      return record
    }
    guard var record = byID64[identity.id64] else { return nil }
    if !identity.uuid.isEmpty {
      record.uuid = identity.uuid
      record.id64 = identity.id64
      byID64.removeValue(forKey: identity.id64)
      byUUID[identity.uuid] = record
      persist()
    }
    return record
  }

  /// Places `record` in whichever index its identity currently supports. A record only ever lives
  /// in `byID64` while its `uuid` is empty — see the `byID64` doc comment for why that invariant
  /// is load-bearing, not incidental.
  private static func index(
    _ record: SpaceRecord, intoUUID byUUID: inout [String: SpaceRecord],
    id64 byID64: inout [Int: SpaceRecord]
  ) {
    if !record.uuid.isEmpty {
      byUUID[record.uuid] = record
    } else if let id64 = record.id64 {
      byID64[id64] = record
    }
    // uuid empty AND id64 unknown: an unrecoverable identity that only a maximally-mangled legacy
    // key could produce (see `migrate`). Dropping it silently is the same "can't happen for data
    // we ever wrote ourselves" case documented there.
  }

  // MARK: Persistence

  private func persist() {
    guard let fileURL else { return }
    guard !persistenceBlocked else {
      log.error(
        """
        Refusing to persist — the on-disk store failed to load safely this run; see the \
        earlier log line and the quarantined file next to spaces.json
        """)
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      SpaceStore.rollBackup(from: fileURL)
      let records = (Array(byUUID.values) + Array(byID64.values))
        .sorted { ($0.uuid, $0.id64 ?? Int.min) < ($1.uuid, $1.id64 ?? Int.min) }
      let envelope = StoreEnvelope(schemaVersion: Constants.schemaVersion, records: records)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(envelope).write(to: fileURL, options: .atomic)
      // `records.count` is not user data; `fileURL.path` embeds the macOS username.
      log.debug(
        """
        Persisted \(records.count, privacy: .public) space record(s) to \
        \(fileURL.path, privacy: .private)
        """)
    } catch {
      // Non-fatal: a failed write just means custom names don't survive relaunch.
      log.error(
        "Failed to persist to \(fileURL.path, privacy: .private): \(error, privacy: .private)")
    }
  }

  /// Copies the file as it was *before* this persist over a single rolling backup slot, so a
  /// write that succeeds but encodes the wrong thing (a future bug, not this one) still leaves
  /// one prior-good copy recoverable — belt-and-braces alongside the corrupt-file quarantine.
  private static func rollBackup(from fileURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    let backupURL = backupFileURL(for: fileURL)
    try? FileManager.default.removeItem(at: backupURL)
    try? FileManager.default.copyItem(at: fileURL, to: backupURL)
  }

  private static func backupFileURL(for fileURL: URL) -> URL {
    let base = fileURL.deletingPathExtension().lastPathComponent
    let ext = fileURL.pathExtension
    let name = ext.isEmpty ? "\(base).backup" : "\(base).backup.\(ext)"
    return fileURL.deletingLastPathComponent().appendingPathComponent(name)
  }

  // MARK: Loading

  /// The result of trying to load `fileURL`, keeping "nothing to load" and "load went wrong"
  /// distinct all the way through `init` — see the type doc comment.
  private struct LoadOutcome {
    var records: [SpaceRecord] = []
    var blocksPersistence = false
    var needsRewrite = false
  }

  private static func load(from fileURL: URL?) -> LoadOutcome {
    guard let fileURL else { return LoadOutcome() }  // in-memory store (tests)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      log.debug("No existing store on disk — first launch, nothing to load")
      return LoadOutcome()  // first launch — nothing to load, nothing wrong
    }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      // `fileURL.path` embeds the macOS username; `error` may echo it back (e.g. POSIX errors).
      log.error(
        """
        spaces.json exists but could not be read at \(fileURL.path, privacy: .private) \
        (\(error, privacy: .private)) — quarantining and refusing to persist over it until \
        this is investigated
        """)
      quarantine(fileURL)
      return LoadOutcome(blocksPersistence: true)
    }

    if let envelope = try? JSONDecoder().decode(StoreEnvelope.self, from: data),
      envelope.schemaVersion == Constants.schemaVersion
    {
      log.debug("Loaded \(envelope.records.count, privacy: .public) space record(s)")
      return LoadOutcome(records: envelope.records)
    }

    // Not decodable as the current envelope — try the pre-#16/#17 flat `{ key: SpaceMetadata }`
    // shape before giving up, so shipped user data migrates instead of being mistaken for
    // corruption. A future schemaVersion bump should add a migration branch here too, rather than
    // falling through to quarantine.
    if let legacy = try? JSONDecoder().decode([String: SpaceMetadata].self, from: data) {
      let records = legacy.compactMap(migrateLegacyEntry)
      log.info(
        """
        Migrated \(records.count, privacy: .public) space record(s) from the legacy flat store \
        format
        """)
      return LoadOutcome(records: records, needsRewrite: true)
    }

    log.error(
      """
      spaces.json is corrupt or in an unrecognized format at \(fileURL.path, privacy: .private) \
      — quarantining and refusing to persist over it until this is investigated
      """)
    quarantine(fileURL)
    return LoadOutcome(blocksPersistence: true)
  }

  /// Recovers a record from one entry of the pre-#17 flat store, where a single string encoded
  /// whichever identifier was available. The `id64` for a `"uuid:…"` entry is unrecoverable — the
  /// old format never stored it — so it comes back `nil`; that is fine, because a record with a
  /// known uuid never needs the `id64` fallback path (see `existingRecord`).
  private static func migrateLegacyEntry(_ entry: (key: String, value: SpaceMetadata))
    -> SpaceRecord?
  {
    let (key, metadata) = entry
    if key.hasPrefix("uuid:") {
      return SpaceRecord(uuid: String(key.dropFirst("uuid:".count)), id64: nil, metadata: metadata)
    }
    if key.hasPrefix("id64:"), let id64 = Int(key.dropFirst("id64:".count)) {
      return SpaceRecord(uuid: "", id64: id64, metadata: metadata)
    }
    return nil  // unrecognized key shape — drop defensively rather than guess at an identity
  }

  /// Preserves an unreadable/undecodable file by renaming it aside, so the raw bytes remain
  /// recoverable rather than being silently replaced the next time something is persisted.
  private static func quarantine(_ fileURL: URL) {
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let quarantineURL =
      fileURL.deletingLastPathComponent()
      .appendingPathComponent("spaces.corrupt-\(timestamp).json")
    do {
      try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
      log.info("Preserved the original file at \(quarantineURL.path, privacy: .private)")
    } catch {
      log.error(
        "Failed to quarantine \(fileURL.path, privacy: .private): \(error, privacy: .private)")
    }
  }

  // MARK: Default location

  public static func defaultFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Spacewalker/spaces.json")
  }
}

/// The on-disk envelope. `schemaVersion` exists so a future field change can migrate `records`
/// instead of the whole file being mistaken for corruption (see `SpaceStore.load`).
private struct StoreEnvelope: Codable {
  var schemaVersion: Int
  var records: [SpaceRecord]
}

/// One persisted Space record. Carries both identifiers per-record (issue #17) rather than
/// encoding exactly one of them into a lookup key, so which identifier is authoritative can change
/// over a Space's lifetime (see `SpaceStore.existingRecord`) without the record itself moving.
///
/// Flat fields (not a nested `metadata` object) so the JSON stays a plain
/// `{"uuid", "id64", "name", "symbolName", "colorHex"}` per record; `metadata` below is a
/// convenience view for callers that only care about the `SpaceMetadata` payload.
private struct SpaceRecord: Codable, Equatable {
  var uuid: String
  /// `nil` only for a record migrated from the pre-#17 format's `"uuid:…"` key, which never
  /// stored an id64 alongside the uuid. Always known for anything created by this build.
  var id64: Int?
  var name: String?
  var symbolName: String?
  var colorHex: String?

  init(uuid: String, id64: Int?, metadata: SpaceMetadata) {
    self.uuid = uuid
    self.id64 = id64
    self.name = metadata.name
    self.symbolName = metadata.symbolName
    self.colorHex = metadata.colorHex
  }

  var metadata: SpaceMetadata {
    get { SpaceMetadata(name: name, symbolName: symbolName, colorHex: colorHex) }
    set {
      name = newValue.name
      symbolName = newValue.symbolName
      colorHex = newValue.colorHex
    }
  }
}
