import XCTest

@testable import SpaceModel

final class FuzzyMatchTests: XCTestCase {

  func testEmptyQueryMatchesEverythingWithZeroScore() {
    XCTAssertEqual(FuzzyMatch.score(query: "", in: "Email"), 0)
  }

  func testSubsequenceMatches() {
    XCTAssertNotNil(FuzzyMatch.score(query: "eml", in: "Email"))
    XCTAssertNotNil(FuzzyMatch.score(query: "bld", in: "Build"))
  }

  func testNonSubsequenceFails() {
    XCTAssertNil(FuzzyMatch.score(query: "xyz", in: "Email"))
    XCTAssertNil(FuzzyMatch.score(query: "eming", in: "Email"))  // wrong order
  }

  func testContiguousBeatsScattered() {
    let contiguous = FuzzyMatch.score(query: "ema", in: "Email")!
    let scattered = FuzzyMatch.score(query: "eml", in: "Email")!
    XCTAssertGreaterThan(contiguous, scattered)
  }

  func testRankingOrdersByBestMatch() {
    let names = ["Design", "Email", "Debugging"]
    let ranked = FuzzyMatch.rank(names, query: "de", name: { $0 })
    XCTAssertEqual(ranked.first, "Design")  // prefix "De" wins
    XCTAssertFalse(ranked.contains("Email"))  // no subsequence
  }

  func testCaseInsensitive() {
    XCTAssertNotNil(FuzzyMatch.score(query: "EMAIL", in: "email"))
  }
}
