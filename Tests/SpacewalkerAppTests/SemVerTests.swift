import XCTest

@testable import SpacewalkerApp

/// Issue #32: the update check compares versions numerically, never as strings — a naive string
/// compare gets "0.10.0" vs "0.9.0" backwards. This is a pure function, so every edge case the
/// GitHub API (or a malformed/missing tag) could hand back gets a table-driven case here.
final class SemVerTests: XCTestCase {

  func testNumericOrderingBeatsStringOrdering() {
    let cases: [(String, String, message: String)] = [
      ("0.10.0", "0.9.0", "0.10.0 must be newer than 0.9.0 (string compare gets this backwards)"),
      ("1.10.0", "1.2.0", "1.10.0 must be newer than 1.2.0"),
      ("2.0.0", "1.99.99", "a major bump beats any minor/patch of the previous major"),
    ]
    for (newer, older, message) in cases {
      guard let newerVersion = SemVer(newer), let olderVersion = SemVer(older) else {
        XCTFail("failed to parse \(newer) or \(older)")
        continue
      }
      XCTAssertGreaterThan(newerVersion, olderVersion, message)
    }
  }

  func testEqualVersionsAreNotNewer() {
    guard let a = SemVer("0.1.0"), let b = SemVer("0.1.0") else {
      return XCTFail("failed to parse")
    }
    XCTAssertEqual(a, b)
    XCTAssertFalse(a > b)
    XCTAssertFalse(a < b)
  }

  func testLeadingVPrefixIsTolerated() {
    XCTAssertEqual(SemVer("v0.1.0"), SemVer("0.1.0"))
    XCTAssertEqual(SemVer("V1.2.3"), SemVer("1.2.3"))
  }

  func testMissingComponentsDefaultToZero() {
    XCTAssertEqual(SemVer("1"), SemVer("1.0.0"))
    XCTAssertEqual(SemVer("1.2"), SemVer("1.2.0"))
  }

  func testPreReleaseAndBuildSuffixesAreStripped() {
    XCTAssertEqual(SemVer("1.2.3-beta.1"), SemVer("1.2.3"))
    XCTAssertEqual(SemVer("1.2.3+abc123"), SemVer("1.2.3"))
  }

  func testWhitespaceIsTrimmed() {
    XCTAssertEqual(SemVer("  0.1.0  "), SemVer("0.1.0"))
  }

  func testMalformedInputFailsToParseRatherThanGuessing() {
    let malformed = ["", "   ", "not-a-version", "1.2.3.4", "a.b.c", "1..2", "v", "-"]
    for input in malformed {
      XCTAssertNil(SemVer(input), "expected \(input.debugDescription) to fail to parse")
    }
  }

  func testComparableSortsAscending() {
    let versions = ["1.10.0", "1.2.0", "0.9.0", "2.0.0", "1.2.10"]
      .compactMap(SemVer.init)
    XCTAssertEqual(versions.count, 5)
    let sorted = versions.sorted()
    let expected = ["0.9.0", "1.2.0", "1.2.10", "1.10.0", "2.0.0"].compactMap(SemVer.init)
    XCTAssertEqual(sorted, expected)
  }
}
