import XCTest

@testable import CGSPrivate

/// Covers issue #24: `CGSSpacesAPI.parseDisplay`/`parseSpace` must fail explicitly (`nil`) on a
/// missing or wrong-typed key rather than silently defaulting — the old `?? "Main"` / `?? -1` /
/// `?? ""` behavior this replaces made a renamed/restructured CGS key indistinguishable from a
/// legitimate reading. These are pure dictionary-shape tests: no `dlsym`, no live WindowServer.
final class SpacesAPIParsingTests: XCTestCase {

  // MARK: Fixtures

  private func healthySpaceDict(
    managedID: Int = 1, id64: Int = 1, uuid: String = "SPACE-UUID", type: Int = 0
  ) -> [String: Any] {
    ["ManagedSpaceID": managedID, "id64": id64, "uuid": uuid, "type": type]
  }

  private func healthyDisplayDict(spaces: [[String: Any]]) -> [String: Any] {
    [
      "Display Identifier": "Main",
      "Current Space": ["ManagedSpaceID": 1],
      "Spaces": spaces,
    ]
  }

  // MARK: parseSpace

  func testParseSpaceParsesHealthyDict() {
    let space = CGSSpacesAPI.parseSpace(healthySpaceDict(id64: 5, uuid: "ABC", type: 0))
    XCTAssertEqual(space, RawSpace(managedID: 1, id64: 5, uuid: "ABC", isFullscreen: false))
  }

  func testParseSpaceMarksTypeFourAsFullscreen() {
    let space = CGSSpacesAPI.parseSpace(healthySpaceDict(type: 4))
    XCTAssertEqual(space?.isFullscreen, true)
  }

  /// The legitimate case (PLAN.md §2): `uuid` present as an empty string must still parse — this
  /// is real, expected data on macOS 15, not a parse failure.
  func testParseSpaceAcceptsPresentButEmptyUUID() {
    let space = CGSSpacesAPI.parseSpace(healthySpaceDict(uuid: ""))
    XCTAssertEqual(space?.uuid, "", "a present-but-empty uuid must parse, not fail")
  }

  func testParseSpaceFailsWhenUUIDKeyIsMissingEntirely() {
    var dict = healthySpaceDict()
    dict.removeValue(forKey: "uuid")
    XCTAssertNil(
      CGSSpacesAPI.parseSpace(dict),
      "a missing uuid key must fail the parse, not silently become an empty string")
  }

  func testParseSpaceFailsWhenID64KeyIsMissing() {
    var dict = healthySpaceDict()
    dict.removeValue(forKey: "id64")
    XCTAssertNil(CGSSpacesAPI.parseSpace(dict))
  }

  func testParseSpaceFailsWhenManagedSpaceIDIsWrongType() {
    var dict = healthySpaceDict()
    dict["ManagedSpaceID"] = "not-a-number"
    XCTAssertNil(CGSSpacesAPI.parseSpace(dict))
  }

  func testParseSpaceFailsWhenTypeKeyIsMissing() {
    var dict = healthySpaceDict()
    dict.removeValue(forKey: "type")
    XCTAssertNil(CGSSpacesAPI.parseSpace(dict))
  }

  /// Simulates a future macOS renaming every key this parser looks for — the "total garbage"
  /// scenario from issue #24. Must fail outright rather than manufacturing a plausible-looking
  /// `RawSpace` with `id64 == -1`/`uuid == ""`.
  func testParseSpaceFailsOnTotallyRenamedKeys() {
    let dict: [String: Any] = ["SpaceManagedID": 1, "spaceUUID": "ABC", "kind": 0]
    XCTAssertNil(CGSSpacesAPI.parseSpace(dict))
  }

  // MARK: parseDisplay

  func testParseDisplayParsesHealthyDict() {
    let dict = healthyDisplayDict(spaces: [healthySpaceDict(id64: 1), healthySpaceDict(id64: 2)])
    let display = CGSSpacesAPI.parseDisplay(dict)
    XCTAssertEqual(display?.displayID, "Main")
    XCTAssertEqual(display?.currentManagedID, 1)
    XCTAssertEqual(display?.spaces.count, 2)
  }

  func testParseDisplayFailsWhenDisplayIdentifierMissing() {
    var dict = healthyDisplayDict(spaces: [healthySpaceDict()])
    dict.removeValue(forKey: "Display Identifier")
    XCTAssertNil(
      CGSSpacesAPI.parseDisplay(dict),
      "a missing Display Identifier must fail, not silently default to \"Main\"")
  }

  func testParseDisplayFailsWhenCurrentSpaceManagedIDMissing() {
    var dict = healthyDisplayDict(spaces: [healthySpaceDict()])
    dict["Current Space"] = [String: Any]()
    XCTAssertNil(CGSSpacesAPI.parseDisplay(dict))
  }

  func testParseDisplayFailsWhenSpacesKeyMissing() {
    var dict = healthyDisplayDict(spaces: [healthySpaceDict()])
    dict.removeValue(forKey: "Spaces")
    XCTAssertNil(CGSSpacesAPI.parseDisplay(dict))
  }

  /// One malformed Space in the list must fail the whole display's parse rather than silently
  /// dropping just that entry — a partially-corrupt topology is still corrupt.
  func testParseDisplayFailsWhenAnySpaceFailsToParse() {
    var badSpace = healthySpaceDict()
    badSpace.removeValue(forKey: "id64")
    let dict = healthyDisplayDict(spaces: [healthySpaceDict(), badSpace])
    XCTAssertNil(CGSSpacesAPI.parseDisplay(dict))
  }
}
