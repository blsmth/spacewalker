import ApplicationServices
import XCTest

@testable import SpacewalkerApp

/// Regression + language-independence coverage for #22: the Mission Control overlay used to
/// locate elements by comparing against **localized English display titles**
/// (`"Mission Control"`, `"Spaces Bar"`, `"Desktop N"`), so it silently found nothing on any
/// non-English system. `MissionControlMatching` replaces that with AX role + structural-shape
/// matching (see its doc comment).
///
/// These build `AXNode` fixtures by hand — no live `AXUIElement`/Dock/Mission Control required
/// — which is what lets this suite exercise German/Japanese/localized-digit-*shaped* trees
/// directly, something a live test on this (English) machine cannot do. See the PR description
/// for which parts of the fix this actually verifies vs. which remain reasoned-but-unverified
/// against a real non-English system.
final class MissionControlMatchingTests: XCTestCase {

  // MARK: - missionControlGroup(among:) — role, not title

  func testMissionControlGroupFoundByRoleRegardlessOfTitleLanguage() {
    let english = AXNode(role: kAXGroupRole, title: "Mission Control")
    let german = AXNode(role: kAXGroupRole, title: "Missionssteuerung")
    let japanese = AXNode(role: kAXGroupRole, title: "ミッションコントロール")
    let untitled = AXNode(role: kAXGroupRole, title: nil)

    for group in [english, german, japanese, untitled] {
      let dockChildren = [AXNode(role: kAXListRole, title: nil), group]
      XCTAssertEqual(
        MissionControlMatching.missionControlGroup(among: dockChildren)?.title, group.title)
    }
  }

  func testMissionControlGroupNilWhenDockHasNoGroupChild() {
    // The idle-Dock shape this PR actually confirmed live: one AXList, no AXGroup.
    let dockChildren = [AXNode(role: kAXListRole, title: nil)]
    XCTAssertNil(MissionControlMatching.missionControlGroup(among: dockChildren))
  }

  func testMissionControlGroupIgnoresATitleMatchWithTheWrongRole() {
    // Guards against accidentally reintroducing a title-based fallback: a same-titled but
    // wrong-role element must not match.
    let impostor = AXNode(role: kAXStaticTextRole, title: "Mission Control")
    let group = AXNode(role: kAXGroupRole, title: "Mission Control")
    XCTAssertEqual(
      MissionControlMatching.missionControlGroup(among: [impostor, group])?.role, kAXGroupRole)
  }

  // MARK: - desktopRects(in:) / bestButtonRow(in:) — role + row shape, not "Desktop N" titles

  private func desktopButton(title: String?, x: CGFloat, width: CGFloat = 80) -> AXNode {
    AXNode(role: kAXButtonRole, title: title, frame: CGRect(x: x, y: -32, width: width, height: 64))
  }

  func testDesktopRectsMatchesEnglishTitledRowAndOrdersLeftToRight() {
    // The shape that ships today (and that this PR must not regress): "Desktop 1", "Desktop 2",
    // "Desktop 3" siblings under some container, evenly spaced left to right.
    let bar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 1", x: 0),
        desktopButton(title: "Desktop 2", x: 100),
        desktopButton(title: "Desktop 3", x: 200),
      ])
    let mc = AXNode(role: kAXGroupRole, title: "Mission Control", children: [bar])

    let rects = MissionControlMatching.desktopRects(in: mc)
    XCTAssertEqual(rects.map(\.n), [1, 2, 3])
    XCTAssertEqual(rects.map(\.rect.origin.x), [0, 100, 200])
  }

  func testDesktopRectsMatchesGermanTitledRowByStructureNotText() {
    // "Schreibtisch N" — same structural row, a title an English-literal match would never see.
    let bar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Schreibtisch 1", x: 0),
        desktopButton(title: "Schreibtisch 2", x: 100),
      ])
    let mc = AXNode(role: kAXGroupRole, title: "Missionssteuerung", children: [bar])

    let rects = MissionControlMatching.desktopRects(in: mc)
    XCTAssertEqual(rects.map(\.n), [1, 2])
  }

  func testDesktopRectsMatchesJapaneseTitledRowByStructureNotText() {
    let bar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "デスクトップ 1", x: 0),
        desktopButton(title: "デスクトップ 2", x: 120),
        desktopButton(title: "デスクトップ 3", x: 240),
      ])
    let mc = AXNode(role: kAXGroupRole, title: "ミッションコントロール", children: [bar])

    let rects = MissionControlMatching.desktopRects(in: mc)
    XCTAssertEqual(rects.map(\.n), [1, 2, 3])
  }

  func testDesktopRectsAssignsStructuralIndexNotParsedDigitWhenTheyDisagree() {
    // If a button's title digit were ever out of step with its visual position (the scenario
    // the issue explicitly warns about — the digit itself can be localized/reordered), the
    // fix must still number by left-to-right position, not by parsing the title.
    let bar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 9", x: 0),  // visually first...
        desktopButton(title: "Desktop 1", x: 100),  // ...but titled "1"
      ])
    let mc = AXNode(role: kAXGroupRole, title: "Mission Control", children: [bar])

    let rects = MissionControlMatching.desktopRects(in: mc)
    XCTAssertEqual(rects.map(\.n), [1, 2], "must number by structural (x) order, not by title")
  }

  func testDesktopRectsMatchesRowWithNoTitlesAtAll() {
    // Titles are a confidence signal only — some Dock builds may not expose one at all.
    let bar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: nil, x: 0),
        desktopButton(title: nil, x: 100),
      ])
    let mc = AXNode(role: kAXGroupRole, children: [bar])

    XCTAssertEqual(MissionControlMatching.desktopRects(in: mc).map(\.n), [1, 2])
  }

  func testDesktopRectsMatchesSingleDesktopSystem() {
    let bar = AXNode(role: kAXListRole, children: [desktopButton(title: "Desktop 1", x: 0)])
    let mc = AXNode(role: kAXGroupRole, children: [bar])

    XCTAssertEqual(MissionControlMatching.desktopRects(in: mc).map(\.n), [1])
  }

  func testDesktopRectsEmptyWhenNoButtonsPresent() {
    let mc = AXNode(
      role: kAXGroupRole, title: "Mission Control",
      children: [AXNode(role: kAXListRole, title: "Spaces Bar", children: [])])
    XCTAssertTrue(MissionControlMatching.desktopRects(in: mc).isEmpty)
  }

  func testDesktopRectsPrefersUniformRowOverMisalignedButtonsElsewhere() {
    // A free-form cluster of same-role buttons at varying heights/y (representative of open
    // window thumbnails in the main MC canvas) must not be mistaken for the Spaces Bar.
    let windowThumbnails = AXNode(
      role: kAXGroupRole,
      children: [
        AXNode(
          role: kAXButtonRole, title: "Safari", frame: CGRect(x: 0, y: 40, width: 220, height: 140)),
        AXNode(
          role: kAXButtonRole, title: "Mail", frame: CGRect(x: 260, y: 90, width: 150, height: 100)),
      ])
    let spacesBar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 1", x: 0),
        desktopButton(title: "Desktop 2", x: 100),
      ])
    let mc = AXNode(
      role: kAXGroupRole, title: "Mission Control", children: [windowThumbnails, spacesBar])

    let rects = MissionControlMatching.desktopRects(in: mc)
    XCTAssertEqual(rects.map(\.n), [1, 2])
    XCTAssertEqual(rects.map(\.rect.origin.x), [0, 100])
  }

  func testDesktopRectsPrefersMoreNumericallyTitledRowWhenBothAreUniform() {
    // Two structurally-uniform rows: prefer the one whose titles look like a numbered sequence
    // (the extra confidence signal), even though it's smaller, over a bigger uniform row of
    // non-numeric-titled same-size buttons (e.g. hypothetical toolbar buttons).
    let toolbar = AXNode(
      role: kAXGroupRole,
      children: [
        AXNode(role: kAXButtonRole, title: "Add", frame: CGRect(x: 0, y: 0, width: 40, height: 40)),
        AXNode(
          role: kAXButtonRole, title: "Remove", frame: CGRect(x: 50, y: 0, width: 40, height: 40)),
        AXNode(
          role: kAXButtonRole, title: "Sort", frame: CGRect(x: 100, y: 0, width: 40, height: 40)),
      ])
    let spacesBar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 1", x: 0),
        desktopButton(title: "Desktop 2", x: 100),
      ])
    let mc = AXNode(role: kAXGroupRole, children: [toolbar, spacesBar])

    let rects = MissionControlMatching.desktopRects(in: mc)
    XCTAssertEqual(rects.map(\.n), [1, 2])
  }

  func testDesktopRectsIgnoresZeroSizedButtons() {
    let bar = AXNode(
      role: kAXListRole,
      children: [
        AXNode(role: kAXButtonRole, title: "Desktop 1", frame: .zero),
        desktopButton(title: "Desktop 2", x: 100),
      ])
    let mc = AXNode(role: kAXGroupRole, children: [bar])

    // Only the non-zero-sized button forms a row on its own.
    XCTAssertEqual(MissionControlMatching.desktopRects(in: mc).map(\.n), [1])
  }

  func testDesktopRectsRespectsTraversalDepthCap() {
    // Nest the real row one level past `RowMatching.maxTraversalDepth` and confirm it's not
    // found — matching the previous implementation's bounded `depth < 6` traversal.
    func wrap(_ node: AXNode, times: Int) -> AXNode {
      times == 0 ? node : AXNode(role: kAXGroupRole, children: [wrap(node, times: times - 1)])
    }
    let bar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 1", x: 0),
        desktopButton(title: "Desktop 2", x: 100),
      ])
    let tooDeep = wrap(bar, times: MissionControlMatching.RowMatching.maxTraversalDepth)
    XCTAssertTrue(MissionControlMatching.desktopRects(in: tooDeep).isEmpty)
  }

  // MARK: - hasTrailingNumeral(_:) — Unicode numeral scripts, not just ASCII 0-9

  func testHasTrailingNumeralAcceptsAsciiAndOtherUnicodeNumeralScripts() {
    XCTAssertTrue(MissionControlMatching.hasTrailingNumeral("Desktop 3"))
    XCTAssertTrue(MissionControlMatching.hasTrailingNumeral("Schreibtisch 12"))
    // Eastern Arabic-Indic digit ٣ (3) — the issue's explicit example of a localized digit.
    XCTAssertTrue(MissionControlMatching.hasTrailingNumeral("سطح المكتب ٣"))
    XCTAssertTrue(MissionControlMatching.hasTrailingNumeral("デスクトップ1"))
  }

  func testHasTrailingNumeralRejectsNonNumericOrMissingTitles() {
    XCTAssertFalse(MissionControlMatching.hasTrailingNumeral("Mission Control"))
    XCTAssertFalse(MissionControlMatching.hasTrailingNumeral(""))
    XCTAssertFalse(MissionControlMatching.hasTrailingNumeral(nil))
  }

  // MARK: - uniformRow(among:) directly

  func testUniformRowRejectsButtonsAtDifferentHeights() {
    let children = [
      AXNode(role: kAXButtonRole, frame: CGRect(x: 0, y: 0, width: 80, height: 60)),
      AXNode(role: kAXButtonRole, frame: CGRect(x: 100, y: 0, width: 80, height: 90)),
    ]
    XCTAssertNil(MissionControlMatching.uniformRow(among: children))
  }

  func testUniformRowRejectsButtonsAtDifferentYWithinTolerance() {
    let children = [
      AXNode(role: kAXButtonRole, frame: CGRect(x: 0, y: 0, width: 80, height: 60)),
      AXNode(role: kAXButtonRole, frame: CGRect(x: 100, y: 20, width: 80, height: 60)),
    ]
    XCTAssertNil(MissionControlMatching.uniformRow(among: children))
  }

  func testUniformRowIgnoresNonButtonSiblings() {
    let children = [
      AXNode(
        role: kAXButtonRole, title: "Desktop 1", frame: CGRect(x: 0, y: 0, width: 80, height: 60)),
      AXNode(
        role: kAXStaticTextRole, title: "Spaces", frame: CGRect(x: 100, y: 0, width: 80, height: 60)
      ),
    ]
    let row = MissionControlMatching.uniformRow(among: children)
    XCTAssertEqual(row?.count, 1)
  }

  /// Issue #64: two buttons that happen to share height/y (e.g. two separate per-display Spaces
  /// Bars rendered at the same relative screen y) but sit a screen's width apart must not be
  /// treated as one row — that merge is exactly what let a cross-screen "row" win the old
  /// count-based tiebreak in `bestButtonRow`.
  func testUniformRowRejectsButtonsWithALargeXGapEvenAtTheSameY() {
    let children = [
      AXNode(role: kAXButtonRole, frame: CGRect(x: 0, y: 0, width: 80, height: 60)),
      // Same y/height as above, but ~1900pt away — a second physical screen's worth of gap.
      AXNode(role: kAXButtonRole, frame: CGRect(x: 1920, y: 0, width: 80, height: 60)),
    ]
    XCTAssertNil(MissionControlMatching.uniformRow(among: children))
  }

  /// The normal, single-screen case: consecutive buttons a few tens of points apart must still
  /// form a row — the contiguity check must not be so tight it rejects real layouts.
  func testUniformRowAcceptsNormallySpacedButtons() {
    let children = [
      AXNode(role: kAXButtonRole, frame: CGRect(x: 0, y: 0, width: 80, height: 60)),
      AXNode(role: kAXButtonRole, frame: CGRect(x: 100, y: 0, width: 80, height: 60)),
      AXNode(role: kAXButtonRole, frame: CGRect(x: 200, y: 0, width: 80, height: 60)),
    ]
    XCTAssertEqual(MissionControlMatching.uniformRow(among: children)?.count, 3)
  }

  // MARK: - allButtonRows(in:) / desktopRows(in:) — issue #64, more than one Spaces Bar

  /// Two structurally-separate, numerically-titled uniform rows — the shape a per-display Spaces
  /// Bar (plausible with "Displays have separate Spaces" on) would produce. Both must be
  /// returned, each independently numbered from 1, rather than only the single "best" one.
  func testDesktopRowsReturnsEachDisplaysBarSeparatelyNumbered() {
    let barA = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 1", x: 0),
        desktopButton(title: "Desktop 2", x: 100),
      ])
    let barB = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 1", x: 5000),
        desktopButton(title: "Desktop 2", x: 5100),
        desktopButton(title: "Desktop 3", x: 5200),
      ])
    let mc = AXNode(role: kAXGroupRole, title: "Mission Control", children: [barA, barB])

    let rows = MissionControlMatching.desktopRows(in: mc)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map { $0.map(\.n) }, [[1, 2], [1, 2, 3]])
    XCTAssertEqual(rows[0].map(\.rect.origin.x), [0, 100])
    XCTAssertEqual(rows[1].map(\.rect.origin.x), [5000, 5100, 5200])
  }

  /// A single-display system must keep behaving exactly as before: one row, back-compat with
  /// `desktopRects(in:)`.
  func testDesktopRowsReturnsExactlyOneRowOnASingleDisplaySystem() {
    let bar = AXNode(
      role: kAXListRole,
      children: [
        desktopButton(title: "Desktop 1", x: 0),
        desktopButton(title: "Desktop 2", x: 100),
      ])
    let mc = AXNode(role: kAXGroupRole, title: "Mission Control", children: [bar])

    let rows = MissionControlMatching.desktopRows(in: mc)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].map(\.n), [1, 2])
  }

  /// No titles at all to disambiguate, and only one real uniform row present alongside an
  /// incidental one (a toolbar) — must fall back to the single largest row, same as
  /// `bestButtonRow`'s pre-#64 behavior, rather than treating the toolbar as a second display.
  func testDesktopRowsFallsBackToLargestRowWhenNoRowHasNumericTitles() {
    let toolbar = AXNode(
      role: kAXGroupRole,
      children: [
        AXNode(role: kAXButtonRole, title: "Add", frame: CGRect(x: 0, y: 0, width: 40, height: 40))
      ])
    let spacesBar = AXNode(
      role: kAXListRole,
      children: [
        AXNode(role: kAXButtonRole, frame: CGRect(x: 0, y: 100, width: 80, height: 60)),
        AXNode(role: kAXButtonRole, frame: CGRect(x: 100, y: 100, width: 80, height: 60)),
      ])
    let mc = AXNode(role: kAXGroupRole, children: [toolbar, spacesBar])

    let rows = MissionControlMatching.desktopRows(in: mc)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].count, 2)
  }

  func testDesktopRowsEmptyWhenNoButtonsPresent() {
    let mc = AXNode(role: kAXGroupRole, title: "Mission Control", children: [])
    XCTAssertTrue(MissionControlMatching.desktopRows(in: mc).isEmpty)
  }
}
