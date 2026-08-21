import XCTest

@testable import SpaceSwitching

final class SwitchPlannerTests: XCTestCase {

  func testNoMoveWhenAlreadyThere() {
    XCTAssertEqual(SwitchPlanner.walk(fromStripIndex: 2, toStripIndex: 2), [])
  }

  func testStepsRight() {
    XCTAssertEqual(
      SwitchPlanner.walk(fromStripIndex: 1, toStripIndex: 4), [.right, .right, .right])
  }

  func testStepsLeft() {
    XCTAssertEqual(SwitchPlanner.walk(fromStripIndex: 4, toStripIndex: 1), [.left, .left, .left])
  }

  func testSingleAdjacent() {
    XCTAssertEqual(SwitchPlanner.walk(fromStripIndex: 0, toStripIndex: 1), [.right])
    XCTAssertEqual(SwitchPlanner.walk(fromStripIndex: 5, toStripIndex: 4), [.left])
  }

  /// The distinction the parameter labels exist to enforce: a strip of
  /// `[Desktop 1, fullscreen, Desktop 2]` puts Desktop 2 at `userIndex` 1 but `stripIndex` 2.
  /// ⌃←/→ steps over the fullscreen tile, so getting there is two hops. Passing user indices here
  /// would plan one hop and land on the fullscreen app instead — and `verifyAndFinish` would still
  /// call it `.ok`, because the active Space *did* change.
  func testWalkCountsFullscreenTilesOnTheStrip() {
    XCTAssertEqual(
      SwitchPlanner.walk(fromStripIndex: 0, toStripIndex: 2), [.right, .right],
      "crossing one fullscreen tile is two hops, not one")
  }
}
