import CGSPrivate
import SpaceModel
import XCTest

@testable import SpacewalkerApp

/// Issue #23: the Mission Control overlay used to convert AX rects and size its window against
/// the primary screen only, silently clipping any label for a Space on a secondary display.
/// `MissionControlOverlayGeometry` is the pure geometry backing the per-screen fix — exercised
/// here against synthetic multi-screen frames, the same technique #59 (`QuickSwitcherGeometry`)
/// and #61 (`SwitchHUDTiming`) used.
///
/// None of these fixtures were checked against a real second monitor (this machine has exactly
/// one display) — see the PR body for what that does and doesn't prove.
final class MissionControlOverlayGeometryTests: XCTestCase {

  // MARK: - cocoaGlobalRect(fromAX:mainScreenHeight:)

  /// A rect near the AX-space top-left (small `y`) must land near the Cocoa-space top (large
  /// `y`, close to the main screen's height) — the basic top/bottom flip, unchanged from the
  /// single-screen formula this replaces.
  func testCocoaGlobalRectFlipsAXTopLeftToCocoaBottomLeft() {
    let axRect = CGRect(x: 100, y: 10, width: 40, height: 20)
    let cocoa = MissionControlOverlayGeometry.cocoaGlobalRect(
      fromAX: axRect, mainScreenHeight: 900)

    XCTAssertEqual(cocoa.origin.x, 100)
    XCTAssertEqual(cocoa.origin.y, 900 - 10 - 20)
    XCTAssertEqual(cocoa.width, 40)
    XCTAssertEqual(cocoa.height, 20)
  }

  /// A rect on a *secondary* display, expressed in AX's shared global space (which can include
  /// x/y well beyond the main screen's own bounds), must still flip using the *main* screen's
  /// height, not the secondary display's — see the doc comment on `cocoaGlobalRect` for why that
  /// is the correct anchor regardless of which physical screen the rect visually sits on.
  func testCocoaGlobalRectUsesMainScreenHeightEvenForARectFarOutsideIt() {
    // A secondary display to the right of, and taller than, a 900pt-tall main screen.
    let axRect = CGRect(x: 2000, y: -50, width: 40, height: 20)
    let cocoa = MissionControlOverlayGeometry.cocoaGlobalRect(
      fromAX: axRect, mainScreenHeight: 900)

    XCTAssertEqual(cocoa.origin.x, 2000)
    XCTAssertEqual(cocoa.origin.y, 900 - (-50) - 20)
  }

  // MARK: - screenFrame(containing:among:)

  private let mainFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
  /// A secondary display to the right of main, in Cocoa global coordinates.
  private let rightFrame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
  /// A secondary display above main (taller in Cocoa's y-up space than main's own height).
  private let aboveFrame = CGRect(x: -200, y: 900, width: 1920, height: 1080)

  func testScreenFrameFindsTheContainingScreenAmongSeveral() {
    let frames = [mainFrame, rightFrame, aboveFrame]

    let onMain = CGRect(x: 100, y: 100, width: 40, height: 20)
    XCTAssertEqual(
      MissionControlOverlayGeometry.screenFrame(containing: onMain, among: frames), mainFrame)

    let onRight = CGRect(x: 1600, y: 100, width: 40, height: 20)
    XCTAssertEqual(
      MissionControlOverlayGeometry.screenFrame(containing: onRight, among: frames), rightFrame)

    let onAbove = CGRect(x: 0, y: 1000, width: 40, height: 20)
    XCTAssertEqual(
      MissionControlOverlayGeometry.screenFrame(containing: onAbove, among: frames), aboveFrame)
  }

  /// A rect that lands in a gap no screen actually covers (a non-adjacent arrangement) must
  /// return `nil` rather than falling back to any particular screen — the fallback issue #23
  /// reports as the bug (everything silently resolving to the primary display) is exactly what
  /// this must NOT reproduce.
  func testScreenFrameReturnsNilForARectInAGapBetweenDisplays() {
    let frames = [mainFrame, rightFrame]
    // Between main's top (y=900) and nothing above it — outside both frames.
    let inTheGap = CGRect(x: 100, y: 950, width: 40, height: 20)
    XCTAssertNil(MissionControlOverlayGeometry.screenFrame(containing: inTheGap, among: frames))
  }

  func testScreenFrameReturnsNilWhenThereAreNoScreens() {
    let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
    XCTAssertNil(MissionControlOverlayGeometry.screenFrame(containing: rect, among: []))
  }

  // MARK: - localRect(_:in:)

  func testLocalRectSubtractsTheScreenOriginForAPositiveOffsetScreen() {
    let global = CGRect(x: 1600, y: 100, width: 40, height: 20)
    let local = MissionControlOverlayGeometry.localRect(global, in: rightFrame)

    XCTAssertEqual(local.origin.x, 1600 - 1440)
    XCTAssertEqual(local.origin.y, 100)
    XCTAssertEqual(local.size, global.size)
  }

  /// A screen with a negative origin (positioned left of, or above, the main screen) must still
  /// produce a valid non-negative-looking local rect once translated into its own window's space.
  func testLocalRectHandlesANegativeOriginScreen() {
    let global = CGRect(x: -150, y: 950, width: 40, height: 20)
    let local = MissionControlOverlayGeometry.localRect(global, in: aboveFrame)

    XCTAssertEqual(local.origin.x, -150 - (-200))
    XCTAssertEqual(local.origin.y, 950 - 900)
  }

  /// End-to-end: an AX rect reported for a Space on a secondary (right-hand) display converts to
  /// a sane, in-bounds local rect for that display's own window — the exact path `render(_:)`
  /// exercises, minus any live `NSScreen`/`NSWindow`.
  func testFullConversionPlacesASecondaryDisplayRectWithinItsOwnLocalBounds() {
    // AX-global coordinates for a button that's visually on the right-hand display: AX's shared
    // space extends past the main screen's own width once a display sits to its right.
    let axRect = CGRect(x: 1700, y: 40, width: 60, height: 30)
    let cocoa = MissionControlOverlayGeometry.cocoaGlobalRect(
      fromAX: axRect, mainScreenHeight: mainFrame.height)

    let frames = [mainFrame, rightFrame]
    guard let screen = MissionControlOverlayGeometry.screenFrame(containing: cocoa, among: frames)
    else {
      return XCTFail("expected the rect to resolve onto the right-hand display")
    }
    XCTAssertEqual(screen, rightFrame)

    let local = MissionControlOverlayGeometry.localRect(cocoa, in: screen)
    XCTAssertTrue(
      CGRect(origin: .zero, size: rightFrame.size).contains(local),
      "\(local) escaped the right-hand display's own local bounds \(rightFrame.size)")
  }

  // MARK: - spacesByDisplayAndIndex(_:) — issue #64

  /// Two real displays, resolved through the actual `Reconciler` (not a hand-built fixture) —
  /// each with two user Spaces, so `userIndex` is `[0, 1]` on *both* displays. This is exactly
  /// the topology `Dictionary(uniqueKeysWithValues: allSpaces.map { ($0.userIndex, $0) })` used
  /// to crash on: two displays' index-0 Spaces collide the instant they're flattened into one
  /// list. `Reconciler.resolve` restarting `userIndex` per display isn't a bug to fix here — see
  /// `ReconcilerTests.testUserIndexRestartsPerDisplayAcrossMultipleDisplays` — the bug was this
  /// overlay assuming it wouldn't.
  private func twoDisplayFixture() -> [ResolvedSpace] {
    func space(_ managed: Int, uuid: String) -> RawSpace {
      RawSpace(managedID: managed, id64: managed, uuid: uuid, isFullscreen: false)
    }
    let displayA = RawDisplay(
      displayID: "display-A", currentManagedID: 1,
      spaces: [space(1, uuid: "A0"), space(2, uuid: "A1")])
    let displayB = RawDisplay(
      displayID: "display-B", currentManagedID: 10,
      spaces: [space(10, uuid: "B0"), space(11, uuid: "B1")])
    return Reconciler.resolve(displays: [displayA, displayB], store: SpaceStore(fileURL: nil))
      .flatMap(\.spaces)
  }

  func testSpacesByDisplayAndIndexDoesNotCrashOnDuplicateUserIndexAcrossDisplays() {
    let allSpaces = twoDisplayFixture()
    // Sanity-check the fixture actually reproduces the crashing shape before asserting anything
    // about the fix.
    XCTAssertEqual(allSpaces.map(\.userIndex), [0, 1, 0, 1])

    let byDisplayAndIndex = MissionControlOverlayGeometry.spacesByDisplayAndIndex(allSpaces)

    XCTAssertEqual(byDisplayAndIndex["display-A"]?[0]?.identity.uuid, "A0")
    XCTAssertEqual(byDisplayAndIndex["display-A"]?[1]?.identity.uuid, "A1")
    XCTAssertEqual(byDisplayAndIndex["display-B"]?[0]?.identity.uuid, "B0")
    XCTAssertEqual(byDisplayAndIndex["display-B"]?[1]?.identity.uuid, "B1")
  }

  func testSpacesByDisplayAndIndexKeepsEachDisplaysIndexZeroDistinct() {
    // The specific collision that crashed: both displays' index-0 Space must resolve to its own
    // display's Space, never the other's.
    let allSpaces = twoDisplayFixture()
    let byDisplayAndIndex = MissionControlOverlayGeometry.spacesByDisplayAndIndex(allSpaces)

    let displayAIndexZero = byDisplayAndIndex["display-A"]?[0]
    let displayBIndexZero = byDisplayAndIndex["display-B"]?[0]
    XCTAssertNotEqual(displayAIndexZero?.identity.uuid, displayBIndexZero?.identity.uuid)
    XCTAssertEqual(displayAIndexZero?.displayID, "display-A")
    XCTAssertEqual(displayBIndexZero?.displayID, "display-B")
  }

  func testSpacesByDisplayAndIndexHandlesASingleDisplayUnchanged() {
    func space(_ managed: Int, uuid: String) -> RawSpace {
      RawSpace(managedID: managed, id64: managed, uuid: uuid, isFullscreen: false)
    }
    let display = RawDisplay(
      displayID: "only", currentManagedID: 1, spaces: [space(1, uuid: "X0"), space(2, uuid: "X1")])
    let allSpaces = Reconciler.resolve(displays: [display], store: SpaceStore(fileURL: nil))
      .flatMap(\.spaces)

    let byDisplayAndIndex = MissionControlOverlayGeometry.spacesByDisplayAndIndex(allSpaces)

    XCTAssertEqual(byDisplayAndIndex.keys.count, 1)
    XCTAssertEqual(byDisplayAndIndex["only"]?[0]?.identity.uuid, "X0")
    XCTAssertEqual(byDisplayAndIndex["only"]?[1]?.identity.uuid, "X1")
  }

  func testSpacesByDisplayAndIndexOnEmptyInputIsEmpty() {
    XCTAssertTrue(MissionControlOverlayGeometry.spacesByDisplayAndIndex([]).isEmpty)
  }
}
