import XCTest

@testable import SpaceSwitching

final class SwitchPlannerTests: XCTestCase {

  func testNoMoveWhenAlreadyThere() {
    XCTAssertEqual(SwitchPlanner.walk(fromIndex: 2, toIndex: 2), [])
  }

  func testStepsRight() {
    XCTAssertEqual(SwitchPlanner.walk(fromIndex: 1, toIndex: 4), [.right, .right, .right])
  }

  func testStepsLeft() {
    XCTAssertEqual(SwitchPlanner.walk(fromIndex: 4, toIndex: 1), [.left, .left, .left])
  }

  func testSingleAdjacent() {
    XCTAssertEqual(SwitchPlanner.walk(fromIndex: 0, toIndex: 1), [.right])
    XCTAssertEqual(SwitchPlanner.walk(fromIndex: 5, toIndex: 4), [.left])
  }
}
