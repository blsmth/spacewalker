import XCTest

@testable import SpaceModel

/// Covers issue #16 (a corrupt/unreadable store must never be silently treated as empty and then
/// overwritten) and issue #17 (identity keys must survive a Space gaining a uuid, and must not let
/// id64 reuse leak a name onto an unrelated new Space). Every test uses a throwaway temp
/// directory — never the real `~/Library/Application Support/Spacewalker/spaces.json`.
final class SpaceStoreTests: XCTestCase {

  private var tempDirectory: URL!
  private var fileURL: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpaceStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    fileURL = tempDirectory.appendingPathComponent("spaces.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDirectory)
  }

  // MARK: #16 — round trip, missing/empty/truncated/malformed files

  func testRoundTripsThroughARealFile() {
    let identity = SpaceIdentity(uuid: "A-uuid", id64: 1)
    SpaceStore(fileURL: fileURL).setName("Email", for: identity)

    let reloaded = SpaceStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.metadata(for: identity)?.name, "Email")
  }

  func testMissingFileIsTreatedAsEmptyNotCorrupt() {
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

    let store = SpaceStore(fileURL: fileURL)
    XCTAssertNil(store.metadata(for: SpaceIdentity(uuid: "A", id64: 1)))

    // A missing file is not a failure — the very next persist must succeed normally.
    store.setName("Email", for: SpaceIdentity(uuid: "A", id64: 1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertEqual(
      SpaceStore(fileURL: fileURL).metadata(for: SpaceIdentity(uuid: "A", id64: 1))?.name, "Email")
  }

  func testEmptyFileIsQuarantinedNotSilentlyTreatedAsEmptyStore() {
    try! Data().write(to: fileURL)

    assertQuarantinedAndBlocked()
  }

  func testTruncatedGarbageFileIsQuarantinedNotSilentlyTreatedAsEmptyStore() {
    try! Data("{ \"schemaVersion\": 1, \"records\": [ { \"uuid\"".utf8).write(to: fileURL)

    assertQuarantinedAndBlocked()
  }

  func testWrongTypeFieldIsQuarantinedNotSilentlyTreatedAsEmptyStore() {
    // id64 must decode as an Int; a string in its place is a decode failure, not "no id64".
    let json = """
      {"schemaVersion": 1, "records": [{"uuid": "", "id64": "not-a-number", "name": "Email"}]}
      """
    try! Data(json.utf8).write(to: fileURL)

    assertQuarantinedAndBlocked()
  }

  func testUnknownFieldIsToleratedAndDoesNotQuarantine() {
    // Forward compatibility: an extra field from a newer build must not be treated as corruption.
    let json = """
      {"schemaVersion": 1, "records": [
        {"uuid": "A-uuid", "id64": 1, "name": "Email", "somethingFromTheFuture": 42}
      ]}
      """
    try! Data(json.utf8).write(to: fileURL)

    let store = SpaceStore(fileURL: fileURL)
    XCTAssertEqual(store.metadata(for: SpaceIdentity(uuid: "A-uuid", id64: 1))?.name, "Email")
    XCTAssertTrue(quarantineFiles().isEmpty, "an unknown field must not trigger quarantine")
  }

  /// Shared assertion for every "the file exists but can't be understood" case: it must be
  /// quarantined (original bytes preserved under a new name) and the store must refuse to ever
  /// write to the original path again this run — otherwise the next edit silently destroys
  /// whatever was really wrong with the file, with no trace left to investigate.
  private func assertQuarantinedAndBlocked(file: StaticString = #filePath, line: UInt = #line) {
    let originalContents = try? Data(contentsOf: fileURL)

    let store = SpaceStore(fileURL: fileURL)

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fileURL.path),
      "the corrupt file must be moved aside, not left in place", file: file, line: line)
    let quarantined = quarantineFiles()
    XCTAssertEqual(
      quarantined.count, 1, "exactly one quarantine file must be created", file: file, line: line)
    if let quarantined = quarantined.first {
      XCTAssertEqual(
        try? Data(contentsOf: quarantined), originalContents,
        "the quarantined file must hold the exact original bytes", file: file, line: line)
    }

    // The bug this closes: a "corrupt" read used to collapse to an empty store, and the next
    // edit persisted that empty store straight over the user's data. Prove that can't happen.
    store.setName("New Name", for: SpaceIdentity(uuid: "B-uuid", id64: 2))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fileURL.path),
      "persist must refuse to write to the original path once loading failed", file: file,
      line: line)
    XCTAssertEqual(
      quarantineFiles().count, 1, "no second file must appear at that path", file: file, line: line)
  }

  private func quarantineFiles() -> [URL] {
    let entries =
      try? FileManager.default.contentsOfDirectory(
        at: tempDirectory, includingPropertiesForKeys: nil)
    return (entries ?? []).filter { $0.lastPathComponent.hasPrefix("spaces.corrupt-") }
  }

  // MARK: #16 — schemaVersion + rolling backup

  func testPersistedFileCarriesASchemaVersion() throws {
    SpaceStore(fileURL: fileURL).setName("Email", for: SpaceIdentity(uuid: "A", id64: 1))

    let data = try Data(contentsOf: fileURL)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
  }

  func testRollingBackupIsWrittenBeforeEachPersist() {
    let store = SpaceStore(fileURL: fileURL)
    store.setName("First", for: SpaceIdentity(uuid: "A", id64: 1))

    let backupURL = tempDirectory.appendingPathComponent("spaces.backup.json")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: backupURL.path),
      "no backup yet — this was the very first persist, nothing existed to back up")

    store.setName("Second", for: SpaceIdentity(uuid: "A", id64: 1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

    // The backup must hold the state as it was *before* the second edit, i.e. "First".
    let backedUp = SpaceStore(fileURL: backupURL)
    XCTAssertEqual(backedUp.metadata(for: SpaceIdentity(uuid: "A", id64: 1))?.name, "First")
  }

  // MARK: #16 — in-memory store (fileURL: nil) still works, is unaffected by disk failures

  func testInMemoryStoreNeverTouchesDisk() {
    let store = SpaceStore(fileURL: nil)
    store.setName("Email", for: SpaceIdentity(uuid: "A", id64: 1))
    XCTAssertEqual(store.metadata(for: SpaceIdentity(uuid: "A", id64: 1))?.name, "Email")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  // MARK: #17 — legacy on-disk formats migrate, not stranded

  func testLegacyUUIDKeyedEntryMigrates() {
    let json = """
      {"uuid:1C91A725-EMAIL": {"name": "Calendar"}}
      """
    try! Data(json.utf8).write(to: fileURL)

    let store = SpaceStore(fileURL: fileURL)
    XCTAssertEqual(
      store.metadata(for: SpaceIdentity(uuid: "1C91A725-EMAIL", id64: 99))?.name, "Calendar")
  }

  func testLegacyID64KeyedEntryMigrates() {
    let json = """
      {"id64:1": {"name": "LL"}}
      """
    try! Data(json.utf8).write(to: fileURL)

    let store = SpaceStore(fileURL: fileURL)
    XCTAssertEqual(store.metadata(for: SpaceIdentity(uuid: "", id64: 1))?.name, "LL")
  }

  func testLegacyFormatIsRewrittenIntoTheCurrentEnvelopeOnLoad() throws {
    let json = """
      {"id64:1": {"name": "LL"}, "uuid:B": {"name": "Calendar"}}
      """
    try! Data(json.utf8).write(to: fileURL)

    _ = SpaceStore(fileURL: fileURL)  // load alone should rewrite, with no edit made

    let data = try Data(contentsOf: fileURL)
    let rewritten = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(rewritten?["schemaVersion"] as? Int, 1, "must have migrated to the new envelope")
  }

  func testBothLegacyFormatsInOneFileMigrateTogether() {
    let json = """
      {"id64:1": {"name": "LL"}, "uuid:1C91A725-EMAIL": {"name": "Calendar"}}
      """
    try! Data(json.utf8).write(to: fileURL)

    let store = SpaceStore(fileURL: fileURL)
    XCTAssertEqual(store.metadata(for: SpaceIdentity(uuid: "", id64: 1))?.name, "LL")
    XCTAssertEqual(
      store.metadata(for: SpaceIdentity(uuid: "1C91A725-EMAIL", id64: 2))?.name, "Calendar")
  }

  // MARK: #17 — a Space gaining a uuid self-heals onto it

  func testSpaceGainingAUUIDSelfHealsOntoIt() {
    let store = SpaceStore(fileURL: fileURL)
    let beforeUUIDAppeared = SpaceIdentity(uuid: "", id64: 1)
    store.setName("Main", for: beforeUUIDAppeared)

    // Apple starts reporting a real uuid for the same physical Space; id64 is unchanged.
    let afterUUIDAppeared = SpaceIdentity(uuid: "1C91A725-MAIN", id64: 1)
    XCTAssertEqual(store.metadata(for: afterUUIDAppeared)?.name, "Main", "must not go dark")

    // The migration must be durable — reload from disk and look up by the new uuid only.
    let reloaded = SpaceStore(fileURL: fileURL)
    XCTAssertEqual(
      reloaded.metadata(for: SpaceIdentity(uuid: "1C91A725-MAIN", id64: 999))?.name, "Main")
  }

  func testSpaceGainingAUUIDSelfHealsOntoItAcrossSetNameToo() {
    let store = SpaceStore(fileURL: fileURL)
    store.setName("Main", for: SpaceIdentity(uuid: "", id64: 1))

    // A write, not just a read, must also find (and migrate) the existing record.
    store.setSymbol("hammer", for: SpaceIdentity(uuid: "1C91A725-MAIN", id64: 1))

    let metadata = store.metadata(for: SpaceIdentity(uuid: "1C91A725-MAIN", id64: 1))
    XCTAssertEqual(metadata?.name, "Main")
    XCTAssertEqual(metadata?.symbolName, "hammer")
  }

  // MARK: #17 — id64 reuse must not leak a name onto an unrelated new Space

  func testID64ReuseDoesNotLeakANameToANewSpaceOnceTheOldOneHasAKnownUUID() {
    let store = SpaceStore(fileURL: fileURL)
    // The old Space already has a real, known uuid — it is not a self-heal candidate.
    store.setName("LL", for: SpaceIdentity(uuid: "old-uuid", id64: 1))

    // The old Space is destroyed and the WindowServer reassigns id64 1 to an unrelated new one.
    let newSpace = SpaceIdentity(uuid: "new-uuid", id64: 1)
    XCTAssertNil(store.metadata(for: newSpace), "the new Space must not inherit the old name")

    // The old record must still be intact under its own uuid, not deleted or corrupted.
    XCTAssertEqual(store.metadata(for: SpaceIdentity(uuid: "old-uuid", id64: 1))?.name, "LL")
  }

  func testID64ReuseAfterMigrationAlsoDoesNotLeak() {
    let store = SpaceStore(fileURL: fileURL)
    // Old record starts id64-only, then self-heals onto a uuid (as in the test above).
    store.setName("LL", for: SpaceIdentity(uuid: "", id64: 1))
    _ = store.metadata(for: SpaceIdentity(uuid: "healed-uuid", id64: 1))

    // Now id64 1 is reused by yet another, different new Space.
    let newSpace = SpaceIdentity(uuid: "new-uuid", id64: 1)
    XCTAssertNil(store.metadata(for: newSpace))
    XCTAssertEqual(store.metadata(for: SpaceIdentity(uuid: "healed-uuid", id64: 1))?.name, "LL")
  }

  // MARK: Clearing metadata still removes the record entirely

  func testClearingNameRemovesAnEmptyRecordEntirely() {
    let store = SpaceStore(fileURL: fileURL)
    let identity = SpaceIdentity(uuid: "A", id64: 1)
    store.setName("Email", for: identity)
    store.setName(nil, for: identity)

    XCTAssertNil(store.metadata(for: identity))
    XCTAssertTrue(store.allKeys.isEmpty)
  }
}
