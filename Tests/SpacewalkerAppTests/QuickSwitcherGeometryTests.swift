import XCTest

@testable import SpacewalkerApp

/// Issue #29: the Quick Switcher panel height had no screen clamp and no scroll view. macOS
/// allows 16 desktops/display, and across two displays `allSpaces` can flatten to 32 rows — a
/// panel far taller than any screen, with rows physically unreachable. `QuickSwitcherGeometry`
/// is the pure geometry backing the fix, so it's tested here without a live panel.
final class QuickSwitcherGeometryTests: XCTestCase {

  // Mirrors SwitcherView's private constants so the math is exercised with realistic numbers.
  private let rowHeight: CGFloat = 46
  private let rowGap: CGFloat = 4
  private let headerHeight: CGFloat = 62
  private let footerHeight: CGFloat = 34

  // MARK: - panelHeight

  /// A synthetic 800pt-tall screen clamps to 640pt (0.8 * 800). Row counts of 1, 9, 16, and 32
  /// (one Space, a full first page of jump keys, one full 16-desktop display, and two flattened
  /// 16-desktop displays) must never produce a panel taller than that clamp.
  func testPanelHeightNeverExceedsTheClamp() {
    let screenHeight: CGFloat = 800
    let maxHeight = screenHeight * 0.8
    for rows in [1, 9, 16, 32] {
      let height = QuickSwitcherGeometry.panelHeight(
        rows: rows, headerHeight: headerHeight, footerHeight: footerHeight,
        rowHeight: rowHeight, rowGap: rowGap, maxHeight: maxHeight)
      XCTAssertLessThanOrEqual(
        height, maxHeight, "\(rows) rows must not exceed the \(maxHeight)pt clamp")
    }
  }

  /// Below the clamp, the panel should still hug its natural (unclamped) content height — the
  /// clamp must not shrink small lists that already fit.
  func testPanelHeightMatchesNaturalSizeWhenBelowTheClamp() {
    let maxHeight: CGFloat = 640
    let oneRow = QuickSwitcherGeometry.panelHeight(
      rows: 1, headerHeight: headerHeight, footerHeight: footerHeight, rowHeight: rowHeight,
      rowGap: rowGap, maxHeight: maxHeight)
    XCTAssertEqual(oneRow, headerHeight + rowHeight + footerHeight)

    let nineRows = QuickSwitcherGeometry.panelHeight(
      rows: 9, headerHeight: headerHeight, footerHeight: footerHeight, rowHeight: rowHeight,
      rowGap: rowGap, maxHeight: maxHeight)
    let expectedNatural = headerHeight + 9 * rowHeight + 8 * rowGap + footerHeight
    XCTAssertLessThan(expectedNatural, maxHeight, "test setup: 9 rows should fit under the clamp")
    XCTAssertEqual(nineRows, expectedNatural)
  }

  /// Above the clamp, height is capped — 16 rows (one full display) and 32 rows (two displays
  /// flattened) both hit the same ceiling rather than scaling further.
  func testPanelHeightIsCappedAboveTheClamp() {
    let maxHeight: CGFloat = 640
    let sixteenRows = QuickSwitcherGeometry.panelHeight(
      rows: 16, headerHeight: headerHeight, footerHeight: footerHeight, rowHeight: rowHeight,
      rowGap: rowGap, maxHeight: maxHeight)
    let thirtyTwoRows = QuickSwitcherGeometry.panelHeight(
      rows: 32, headerHeight: headerHeight, footerHeight: footerHeight, rowHeight: rowHeight,
      rowGap: rowGap, maxHeight: maxHeight)
    XCTAssertEqual(sixteenRows, maxHeight)
    XCTAssertEqual(thirtyTwoRows, maxHeight)
  }

  /// Zero rows (an empty/no-match filter) still renders one placeholder row's worth of chrome,
  /// never collapsing to something smaller than that.
  func testPanelHeightFloorsAtOneRowWhenThereAreNoRows() {
    let height = QuickSwitcherGeometry.panelHeight(
      rows: 0, headerHeight: headerHeight, footerHeight: footerHeight, rowHeight: rowHeight,
      rowGap: rowGap, maxHeight: 640)
    XCTAssertEqual(height, headerHeight + rowHeight + footerHeight)
  }

  /// A pathologically small screen (smaller than one row's chrome) must not collapse the panel
  /// below a single usable row.
  func testPanelHeightNeverShrinksBelowOneRowEvenOnATinyScreen() {
    let tinyMaxHeight: CGFloat = 50
    let height = QuickSwitcherGeometry.panelHeight(
      rows: 32, headerHeight: headerHeight, footerHeight: footerHeight, rowHeight: rowHeight,
      rowGap: rowGap, maxHeight: tinyMaxHeight)
    XCTAssertEqual(height, headerHeight + rowHeight + footerHeight)
  }

  // MARK: - rowTop

  /// Pins `rowTop`'s absolute values with literal numbers rather than deriving them from the
  /// formula under test. `50` (= `rowHeight` + `rowGap`, i.e. `NSStackView.spacing` + row height)
  /// is load-bearing for every scroll-offset computation below, so it's asserted explicitly — an
  /// off-by-one here (e.g. `(index + 1) * (rowHeight + rowGap)`) would push every scroll target
  /// one row below the actual selection, walking it off the viewport edge.
  func testRowTopReturnsLiteralOffsets() {
    XCTAssertEqual(QuickSwitcherGeometry.rowTop(0, rowHeight: rowHeight, rowGap: rowGap), 0)
    XCTAssertEqual(QuickSwitcherGeometry.rowTop(1, rowHeight: rowHeight, rowGap: rowGap), 50)
    XCTAssertEqual(QuickSwitcherGeometry.rowTop(10, rowHeight: rowHeight, rowGap: rowGap), 500)
  }

  // MARK: - scrollOffset(toReveal:)

  /// Arrowing down past the bottom of the visible window must scroll just enough to reveal the
  /// newly selected row, aligning its bottom edge with the viewport bottom. Expected offset is a
  /// literal (346 = row 10's bottom edge at 546 minus the 200pt viewport) rather than one derived
  /// by calling `rowTop` — computing the expectation from the function under test let an
  /// off-by-one in `rowTop` survive mutation testing undetected.
  func testScrollOffsetScrollsDownWhenSelectionMovesBelowTheViewport() {
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 10, rowCount: 32, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: 200, currentOffset: 0)  // ~4 rows visible at a time
    XCTAssertEqual(offset, 346)
  }

  /// Arrowing up past the top of the visible window must scroll just enough to reveal the row,
  /// aligning its top edge with the viewport top. Expected offset is a literal (100 = row 2's top
  /// edge) for the same reason as the down-scroll case above.
  func testScrollOffsetScrollsUpWhenSelectionMovesAboveTheViewport() {
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 2, rowCount: 32, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: 200, currentOffset: 500)
    XCTAssertEqual(offset, 100)
  }

  /// A selection that's already fully visible must not cause any scroll — arrowing within the
  /// visible window shouldn't jitter the list.
  func testScrollOffsetLeavesAnAlreadyVisibleSelectionUntouched() {
    let visibleHeight: CGFloat = 200
    let currentOffset: CGFloat = 100
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 3, rowCount: 32, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: visibleHeight, currentOffset: currentOffset)
    XCTAssertEqual(offset, currentOffset)
  }

  /// The last row's bottom-aligned offset happens to equal the document's max scroll offset, so
  /// this exercises the bottom-alignment branch's arithmetic — but NOT the `min(..., maxOffset)`
  /// clamp itself, since the unclamped result here never exceeds `maxOffset` in the first place.
  /// (Renamed from a name that implied clamp coverage it didn't have — deleting the clamp entirely
  /// left this test passing. See `testScrollOffsetClampBindsWhenRevealingPastTheLastRow` below for
  /// a case where the clamp is actually load-bearing.)
  func testScrollOffsetAlignsBottomEdgeForTheLastRow() {
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 31, rowCount: 32, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: 200, currentOffset: 0)
    XCTAssertEqual(offset, 1396)  // totalHeight (1596 = 32*46 + 31*4) - visibleHeight (200)
  }

  /// Unlike the last-row case above, revealing an index at (one past) `rowCount` computes a
  /// bottom-aligned offset that genuinely overshoots the document — this is what the
  /// `min(..., maxOffset)` clamp exists to catch. Deleting that clamp makes this test fail.
  func testScrollOffsetClampBindsWhenRevealingPastTheLastRow() {
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 32, rowCount: 32, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: 200, currentOffset: 0)
    // Unclamped this would be rowTop(32) + rowHeight - visibleHeight = 1600 + 46 - 200 = 1446,
    // past the document's actual max offset of 1396 (see the literal above).
    XCTAssertEqual(offset, 1396)
  }

  /// A viewport tall enough to show every row never needs to scroll away from the top.
  func testScrollOffsetStaysAtZeroWhenEverythingFits() {
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 8, rowCount: 9, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: 1000, currentOffset: 0)
    XCTAssertEqual(offset, 0)
  }

  // MARK: - panelFrame

  /// The clamped panel must never extend past the top of the screen (issue found in review of
  /// #59): with the height clamp at 0.8 * screen height and the pre-existing +0.12 * screen height
  /// upward bias, `panelFrame` is the only thing standing between a tall panel and a top edge that
  /// draws under the menu bar, clipping the header. Swept across every row count from empty to the
  /// 32-row worst case (#29) and three real screen heights (13" laptop, 1080p external, this
  /// machine's 3440x1440 ultrawide), the resulting frame must stay fully inside `visibleFrame`.
  func testPanelFrameIsAlwaysContainedInVisibleFrame() {
    let panelWidth: CGFloat = 460
    let verticalBias: CGFloat = 0.12
    let heightClampFraction: CGFloat = 0.8

    for screenHeight: CGFloat in [860, 1080, 1415] {
      // A non-zero origin (menu bar offset, secondary-display placement) so the test can't pass
      // by accident on an assumption that visibleFrame starts at (0, 0).
      let visibleFrame = NSRect(x: 100, y: 25, width: 2000, height: screenHeight)
      let maxHeight = screenHeight * heightClampFraction

      for rows in [0, 1, 7, 12, 16, 20, 32] {
        let height = QuickSwitcherGeometry.panelHeight(
          rows: rows, headerHeight: headerHeight, footerHeight: footerHeight,
          rowHeight: rowHeight, rowGap: rowGap, maxHeight: maxHeight)
        let frame = QuickSwitcherGeometry.panelFrame(
          width: panelWidth, height: height, visibleFrame: visibleFrame,
          verticalBias: verticalBias)
        XCTAssertTrue(
          visibleFrame.contains(frame),
          "\(rows) rows on a \(screenHeight)pt screen: frame \(frame) escapes "
            + "visibleFrame \(visibleFrame)")
      }
    }
  }

  /// Below the clamp (small row counts), the pleasing upward bias should still apply — the frame
  /// clamp must be a no-op in the common case, not override it unconditionally.
  func testPanelFrameKeepsTheUpwardBiasWhenThereIsNoOverflow() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 2000, height: 1415)
    let height: CGFloat = 300  // comfortably under any clamp
    let frame = QuickSwitcherGeometry.panelFrame(
      width: 460, height: height, visibleFrame: visibleFrame, verticalBias: 0.12)
    let expectedY = visibleFrame.midY - height / 2 + visibleFrame.height * 0.12
    XCTAssertEqual(frame.origin.y, expectedY)
    XCTAssertEqual(frame.origin.x, visibleFrame.midX - 460 / 2)
  }

  /// A panel tall enough that the biased position would push it past the top of the screen is
  /// pulled down until its top edge lands exactly on the screen's top edge, rather than
  /// overflowing — this is the exact scenario from the review finding (0.8H clamp + 0.12H bias
  /// always overflows the top by 0.02H before this fix).
  func testPanelFrameClampsToTheTopEdgeWhenTheBiasWouldOverflow() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 2000, height: 1415)
    let height = visibleFrame.height * 0.8  // the worst case: the height clamp itself
    let frame = QuickSwitcherGeometry.panelFrame(
      width: 460, height: height, visibleFrame: visibleFrame, verticalBias: 0.12)
    XCTAssertEqual(frame.maxY, visibleFrame.maxY)
    XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
  }

  /// A panel exactly as tall as the screen has no room for any bias at all — both edges pin.
  /// Accuracy tolerance absorbs floating-point round-off in the two chained subtractions inside
  /// `clamped`, not a real gap — both edges are meant to land exactly on the screen edges here.
  func testPanelFrameClampsToBothEdgesWhenThePanelFillsTheScreen() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 2000, height: 1415)
    let frame = QuickSwitcherGeometry.panelFrame(
      width: 460, height: visibleFrame.height, visibleFrame: visibleFrame, verticalBias: 0.12)
    XCTAssertEqual(frame.minY, visibleFrame.minY, accuracy: 0.001)
    XCTAssertEqual(frame.maxY, visibleFrame.maxY, accuracy: 0.001)
  }
}
