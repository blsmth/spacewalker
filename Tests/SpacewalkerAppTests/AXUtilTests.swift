import ApplicationServices
import XCTest

@testable import SpacewalkerApp

/// Regression coverage for #21: `AXUtil.point(from:)`/`size(from:)` must never trap, no matter
/// what a foreign process (the Dock) hands back through `AXUIElementCopyAttributeValue`.
///
/// These exercise the guarded unwrap directly with hand-built `AXValue`/non-`AXValue`
/// `CFTypeRef`s — no live Dock AX tree required, since the actual cross-process AX round-trip
/// isn't fakeable in-process. That's also why the tests live at this seam rather than against
/// `AXUtil.frame(_:)` or `MissionControlOverlay` itself, both of which require a real
/// `AXUIElement`.
final class AXUtilTests: XCTestCase {

  func testPointFromNilReturnsNil() {
    XCTAssertNil(AXUtil.point(from: nil))
  }

  func testSizeFromNilReturnsNil() {
    XCTAssertNil(AXUtil.size(from: nil))
  }

  func testPointFromNonAXValueReturnsNil() {
    // A real CFTypeRef, just not an AXValue — the pre-#21 code would have force-cast this and
    // crashed.
    let notAnAXValue = "not an AXValue" as CFString
    XCTAssertNil(AXUtil.point(from: notAnAXValue))
  }

  func testSizeFromNonAXValueReturnsNil() {
    let notAnAXValue = 42 as CFNumber
    XCTAssertNil(AXUtil.size(from: notAnAXValue))
  }

  func testPointFromAXValueOfWrongEncodedTypeReturnsNil() {
    // A genuine AXValue — just wrapping a CGSize, not the CGPoint `point(from:)` expects.
    var size = CGSize(width: 3, height: 4)
    guard let axValue = AXValueCreate(.cgSize, &size) else {
      return XCTFail("AXValueCreate(.cgSize, _) unexpectedly failed")
    }
    XCTAssertNil(AXUtil.point(from: axValue))
  }

  func testSizeFromAXValueOfWrongEncodedTypeReturnsNil() {
    var point = CGPoint(x: 1, y: 2)
    guard let axValue = AXValueCreate(.cgPoint, &point) else {
      return XCTFail("AXValueCreate(.cgPoint, _) unexpectedly failed")
    }
    XCTAssertNil(AXUtil.size(from: axValue))
  }

  func testPointFromValidAXValueRoundTrips() {
    var point = CGPoint(x: 12, y: 34)
    guard let axValue = AXValueCreate(.cgPoint, &point) else {
      return XCTFail("AXValueCreate(.cgPoint, _) unexpectedly failed")
    }
    XCTAssertEqual(AXUtil.point(from: axValue), point)
  }

  func testSizeFromValidAXValueRoundTrips() {
    var size = CGSize(width: 56, height: 78)
    guard let axValue = AXValueCreate(.cgSize, &size) else {
      return XCTFail("AXValueCreate(.cgSize, _) unexpectedly failed")
    }
    XCTAssertEqual(AXUtil.size(from: axValue), size)
  }
}
