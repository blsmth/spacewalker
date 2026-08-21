import CGSPrivate
import SpaceModel
import XCTest

@testable import SpacewalkerApp

/// Pins `MissionControlOverlay.render(_:)`'s actual composition (PR #63's second review, finding
/// F4) — the piece two independent mutations bypassed while the full 217-test suite (which only
/// exercised the pure helpers `render(_:)` called, never the composition itself) kept passing:
/// `render()` ignoring row→display attribution entirely
/// (`let spacesByIndex = byDisplayAndIndex.values.first`), and `render()` reverting to the
/// original crashing `Dictionary(uniqueKeysWithValues: spaces().map { ($0.userIndex, $0) })`.
///
/// Every case here is built from either a real `Reconciler.resolve` topology (the #64 crash
/// shape) or the exact live-captured Mission Control geometry in `scripts/dump-mc-ax.swift` (F1),
/// so a regression to either bypass would fail one of these, not just an isolated helper test.
final class MissionControlRowResolutionTests: XCTestCase {

  private func rawSpace(_ managed: Int, uuid: String) -> RawSpace {
    RawSpace(managedID: managed, id64: managed, uuid: uuid, isFullscreen: false)
  }

  /// `ResolvedSpace` has no public initializer, so a custom name has to be set on a `SpaceStore`
  /// *before* `Reconciler.resolve` runs — the same path a real user naming a Space through the
  /// Quick Switcher would take — rather than constructed after the fact.
  private func namedStore(for rawSpaces: [RawSpace]) -> SpaceStore {
    let store = SpaceStore(fileURL: nil)
    for raw in rawSpaces {
      store.setName("Custom \(raw.uuid)", for: SpaceIdentity(raw: raw))
    }
    return store
  }

  /// The exact shape that crashed issue #64: two real displays, each with two Spaces, resolved
  /// through the actual `Reconciler` — `userIndex` is `[0, 1]` on *both* displays. Each row must
  /// resolve to its own display's Spaces, never the other's — the bypass-attribution mutation
  /// (`byDisplayAndIndex.values.first`) would make every row resolve to whichever display
  /// happened to be first in the dictionary's (unordered) iteration, silently mislabeling one
  /// display whenever there's more than one.
  func testResolveKeepsEachDisplaysSpacesDistinctForTheHashCrashShape() {
    let spacesA = [rawSpace(1, uuid: "A0"), rawSpace(2, uuid: "A1")]
    let spacesB = [rawSpace(10, uuid: "B0"), rawSpace(11, uuid: "B1")]
    let displayA = RawDisplay(displayID: "display-A", currentManagedID: 1, spaces: spacesA)
    let displayB = RawDisplay(displayID: "display-B", currentManagedID: 10, spaces: spacesB)
    let store = namedStore(for: spacesA + spacesB)

    let allSpaces = Reconciler.resolve(displays: [displayA, displayB], store: store)
      .flatMap(\.spaces)
    XCTAssertEqual(allSpaces.map(\.userIndex), [0, 1, 0, 1], "sanity: reproduces the crash shape")
    XCTAssertTrue(allSpaces.allSatisfy(\.isCustomNamed), "sanity: every Space is named")

    // Display A's row sits on the left screen; display B's row sits on the right screen.
    let leftScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let rightScreen = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    let rowA: [(n: Int, rect: CGRect)] = [(1, CGRect(x: 100, y: 10, width: 40, height: 20))]
    let rowB: [(n: Int, rect: CGRect)] = [(1, CGRect(x: 1100, y: 10, width: 40, height: 20))]

    let labels = MissionControlRowResolution.resolve(
      rows: [rowA, rowB], allSpaces: allSpaces, anchorScreenHeight: leftScreen.height,
      screenFrames: [leftScreen, rightScreen],
      displayIDCandidates: { frame in frame == leftScreen ? ["display-A"] : ["display-B"] })

    XCTAssertEqual(labels.count, 2)
    XCTAssertEqual(labels.first(where: { $0.screenFrame == leftScreen })?.space.identity.uuid, "A0")
    XCTAssertEqual(
      labels.first(where: { $0.screenFrame == rightScreen })?.space.identity.uuid, "B0")
  }

  /// Live-verified regression for finding F1, using `scripts/dump-mc-ax.swift`'s exact captured
  /// geometry: a Spaces Bar row collapsed above the screen's top edge must still resolve to a
  /// label on a single-display machine, not silently vanish.
  func testResolveStillProducesALabelForTheRealCollapsedRowAboveTheScreenTop() {
    let singleScreen = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    let spaces = [rawSpace(1, uuid: "X0")]
    let display = RawDisplay(displayID: "only-display", currentManagedID: 1, spaces: spaces)
    let allSpaces = Reconciler.resolve(displays: [display], store: namedStore(for: spaces))
      .flatMap(\.spaces)

    // "Desktop 1" from the live capture: AX rect (1338, -32, 65, 24).
    let row: [(n: Int, rect: CGRect)] = [(1, CGRect(x: 1338, y: -32, width: 65, height: 24))]

    let labels = MissionControlRowResolution.resolve(
      rows: [row], allSpaces: allSpaces, anchorScreenHeight: singleScreen.height,
      screenFrames: [singleScreen], displayIDCandidates: { _ in ["only-display"] })

    XCTAssertEqual(labels.count, 1, "the real collapsed Spaces Bar row must still produce a label")
    XCTAssertEqual(labels.first?.space.identity.uuid, "X0")
  }

  /// Finding F2: CGS reports `"Main"`, not a UUID, for the active display's topology entry when
  /// "Displays have separate Spaces" is off. `displayIDCandidates` offers `["some-uuid", "Main"]`
  /// (mirroring `ScreenDisplayIdentity.cgsDisplayIDCandidates(for:)`); the topology itself is only
  /// keyed `"Main"`, so the lookup must fall through to it rather than missing outright.
  func testResolveFallsBackToMainWhenTheTopologyIsKeyedMainNotAUUID() {
    let spaces = [rawSpace(1, uuid: "M0")]
    let display = RawDisplay(displayID: "Main", currentManagedID: 1, spaces: spaces)
    let allSpaces = Reconciler.resolve(displays: [display], store: namedStore(for: spaces))
      .flatMap(\.spaces)

    let singleScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let row: [(n: Int, rect: CGRect)] = [(1, CGRect(x: 100, y: 10, width: 40, height: 20))]

    let labels = MissionControlRowResolution.resolve(
      rows: [row], allSpaces: allSpaces, anchorScreenHeight: singleScreen.height,
      screenFrames: [singleScreen],
      displayIDCandidates: { _ in ["CFCDBA12-0000-0000-0000-000000000000", "Main"] })

    XCTAssertEqual(labels.count, 1)
    XCTAssertEqual(labels.first?.space.identity.uuid, "M0")
  }

  /// A Space that hasn't been given a custom name must not be drawn — `resolve`'s own
  /// responsibility, independent of display attribution, and the reason the crash-shape test
  /// above deliberately names every Space first.
  func testResolveOnlyIncludesSpacesTheUserActuallyNamed() {
    let spaces = [rawSpace(1, uuid: "X0"), rawSpace(2, uuid: "X1")]
    let display = RawDisplay(displayID: "only", currentManagedID: 1, spaces: spaces)
    // Deliberately an unnamed store — no custom names set.
    let allSpaces = Reconciler.resolve(displays: [display], store: SpaceStore(fileURL: nil))
      .flatMap(\.spaces)
    XCTAssertTrue(allSpaces.allSatisfy { !$0.isCustomNamed }, "sanity: no custom names set")

    let singleScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let row: [(n: Int, rect: CGRect)] = [
      (1, CGRect(x: 0, y: 10, width: 40, height: 20)),
      (2, CGRect(x: 50, y: 10, width: 40, height: 20)),
    ]

    let labels = MissionControlRowResolution.resolve(
      rows: [row], allSpaces: allSpaces, anchorScreenHeight: singleScreen.height,
      screenFrames: [singleScreen], displayIDCandidates: { _ in ["only"] })

    XCTAssertTrue(labels.isEmpty, "no Space had a custom name, so nothing should be drawn")
  }

  /// No screens at all — must return `[]`, not trap, mirroring
  /// `MissionControlOverlayGeometry.screenFrame(containing:among:)`'s own "empty screens" case.
  func testResolveIsEmptyWhenThereAreNoScreens() {
    let spaces = [rawSpace(1, uuid: "X0")]
    let display = RawDisplay(displayID: "only", currentManagedID: 1, spaces: spaces)
    let allSpaces = Reconciler.resolve(displays: [display], store: namedStore(for: spaces))
      .flatMap(\.spaces)
    let row: [(n: Int, rect: CGRect)] = [(1, CGRect(x: 0, y: 10, width: 40, height: 20))]

    let labels = MissionControlRowResolution.resolve(
      rows: [row], allSpaces: allSpaces, anchorScreenHeight: 900, screenFrames: [],
      displayIDCandidates: { _ in ["only"] })

    XCTAssertTrue(labels.isEmpty)
  }
}
