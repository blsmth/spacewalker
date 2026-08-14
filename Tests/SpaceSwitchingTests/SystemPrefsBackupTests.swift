import XCTest

@testable import SpaceSwitching

/// Round-trip tests for `SystemPrefsBackup`'s file I/O and plist encode/decode. Never touches
/// CFPreferences (`capture`/`restore`) — see issue #2's constraint to test pure logic only.
final class SystemPrefsBackupTests: XCTestCase {

  private var tempDirectory: URL!
  private var fileURL: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SystemPrefsBackupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    fileURL = tempDirectory.appendingPathComponent("system-prefs-backup.plist")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDirectory)
  }

  // MARK: File I/O round trip

  func testSaveAndLoadRoundTripsPresentValues() {
    let snapshot = SystemPrefsBackup.Snapshot(
      mruSpaces: .present(true),
      hotkeyEntries: [
        118: .present([
          "enabled": 1, "value": ["type": "standard", "parameters": [49, 18, 262_144]],
        ])
      ])

    XCTAssertTrue(SystemPrefsBackup.save(snapshot, to: fileURL))
    let loaded = SystemPrefsBackup.load(from: fileURL)

    assertPriorValue(loaded?.mruSpaces, equals: .present(true))
    assertPriorValue(loaded?.hotkeyEntries[118], equals: snapshot.hotkeyEntries[118]!)
  }

  func testAbsentValuesRoundTripAsAbsentNotAsAFabricatedDefault() {
    let snapshot = SystemPrefsBackup.Snapshot(
      mruSpaces: .absent,
      hotkeyEntries: [118: .absent, 119: .present(["enabled": 1])])

    XCTAssertTrue(SystemPrefsBackup.save(snapshot, to: fileURL))
    let loaded = SystemPrefsBackup.load(from: fileURL)

    assertPriorValue(loaded?.mruSpaces, equals: .absent)
    assertPriorValue(loaded?.hotkeyEntries[118], equals: .absent)
    assertPriorValue(loaded?.hotkeyEntries[119], equals: .present(["enabled": 1]))
  }

  func testLoadReturnsNilWhenNoBackupExists() {
    XCTAssertNil(SystemPrefsBackup.load(from: fileURL))
  }

  func testExistsReflectsFilePresence() {
    XCTAssertFalse(SystemPrefsBackup.exists(at: fileURL))
    SystemPrefsBackup.save(
      SystemPrefsBackup.Snapshot(mruSpaces: .absent, hotkeyEntries: [:]), to: fileURL)
    XCTAssertTrue(SystemPrefsBackup.exists(at: fileURL))
  }

  func testRemoveDeletesTheBackupFile() {
    SystemPrefsBackup.save(
      SystemPrefsBackup.Snapshot(mruSpaces: .absent, hotkeyEntries: [:]), to: fileURL)
    XCTAssertTrue(SystemPrefsBackup.exists(at: fileURL))

    SystemPrefsBackup.remove(at: fileURL)

    XCTAssertFalse(SystemPrefsBackup.exists(at: fileURL))
  }

  // MARK: Never clobber a pristine backup

  func testSaveDoesNotOverwriteAnExistingBackup() {
    let pristine = SystemPrefsBackup.Snapshot(
      mruSpaces: .present(true), hotkeyEntries: [118: .absent])
    XCTAssertTrue(SystemPrefsBackup.save(pristine, to: fileURL))

    let ourOwnAppliedState = SystemPrefsBackup.Snapshot(
      mruSpaces: .present(false), hotkeyEntries: [118: .present(["enabled": 1])])
    XCTAssertFalse(
      SystemPrefsBackup.save(ourOwnAppliedState, to: fileURL),
      "a second save must be rejected, or a real pristine snapshot could be clobbered")

    let loaded = SystemPrefsBackup.load(from: fileURL)
    assertPriorValue(loaded?.mruSpaces, equals: .present(true), "must still be the pristine value")
    assertPriorValue(loaded?.hotkeyEntries[118], equals: .absent)
  }

  // MARK: Helpers

  private func assertPriorValue(
    _ actual: SystemPrefsBackup.PriorValue?, equals expected: SystemPrefsBackup.PriorValue,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let actual else {
      XCTFail("expected \(expected), got nil. \(message)", file: file, line: line)
      return
    }
    switch (actual, expected) {
    case (.absent, .absent):
      return
    case (.present(let a), .present(let e)):
      let equal = (a as? NSObject)?.isEqual(e as? NSObject) ?? false
      XCTAssertTrue(equal, "expected \(e), got \(a). \(message)", file: file, line: line)
    default:
      XCTFail(
        "mismatched cases: expected \(expected), got \(actual). \(message)", file: file, line: line)
    }
  }
}
