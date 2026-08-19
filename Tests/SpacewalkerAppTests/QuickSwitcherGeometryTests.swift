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

  // MARK: - scrollOffset(toReveal:)

  /// Arrowing down past the bottom of the visible window must scroll just enough to reveal the
  /// newly selected row, aligning its bottom edge with the viewport bottom.
  func testScrollOffsetScrollsDownWhenSelectionMovesBelowTheViewport() {
    let visibleHeight: CGFloat = 200  // ~4 rows visible at a time
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 10, rowCount: 32, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: visibleHeight, currentOffset: 0)
    let rowTop = QuickSwitcherGeometry.rowTop(10, rowHeight: rowHeight, rowGap: rowGap)
    let rowBottom = rowTop + rowHeight
    XCTAssertEqual(offset, rowBottom - visibleHeight)
  }

  /// Arrowing up past the top of the visible window must scroll just enough to reveal the row,
  /// aligning its top edge with the viewport top.
  func testScrollOffsetScrollsUpWhenSelectionMovesAboveTheViewport() {
    let visibleHeight: CGFloat = 200
    let startingOffset: CGFloat = 500
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 2, rowCount: 32, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: visibleHeight, currentOffset: startingOffset)
    XCTAssertEqual(offset, QuickSwitcherGeometry.rowTop(2, rowHeight: rowHeight, rowGap: rowGap))
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

  /// The offset never scrolls past the end of the document, even for the very last row.
  func testScrollOffsetClampsToTheEndOfTheDocumentForTheLastRow() {
    let rowCount = 32
    let visibleHeight: CGFloat = 200
    let totalHeight = CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * rowGap
    let maxOffset = totalHeight - visibleHeight
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: rowCount - 1, rowCount: rowCount, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: visibleHeight, currentOffset: 0)
    XCTAssertEqual(offset, maxOffset)
  }

  /// A viewport tall enough to show every row never needs to scroll away from the top.
  func testScrollOffsetStaysAtZeroWhenEverythingFits() {
    let offset = QuickSwitcherGeometry.scrollOffset(
      toReveal: 8, rowCount: 9, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: 1000, currentOffset: 0)
    XCTAssertEqual(offset, 0)
  }
}
