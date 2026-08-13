import CGSPrivate
import XCTest

@testable import SpaceModel

final class ReconcilerTests: XCTestCase {

  private func user(_ managed: Int, uuid: String) -> RawSpace {
    RawSpace(managedID: managed, id64: managed, uuid: uuid, isFullscreen: false)
  }

  // Default names are positional and 1-based.
  func testDefaultNamesArePositional() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: 2,
      spaces: [
        user(1, uuid: "A"), user(2, uuid: "B"), user(3, uuid: "C"),
      ])
    let resolved = Reconciler.resolve(displays: [display], store: SpaceStore(fileURL: nil))
    let names = resolved[0].spaces.map(\.displayName)
    XCTAssertEqual(names, ["Desktop 1", "Desktop 2", "Desktop 3"])
    XCTAssertTrue(resolved[0].spaces[1].isCurrent)  // managed 2 is current
  }

  // A custom name must follow the Space's identity even after the OS reindexes order.
  func testCustomNameSurvivesReindex() {
    let store = SpaceStore(fileURL: nil)
    let identityB = SpaceIdentity(uuid: "B", id64: 2)
    store.setName("Email", for: identityB)

    // Initial order A,B,C → B is "Email" at index 1.
    let before = Reconciler.resolve(
      displays: [
        RawDisplay(
          displayID: "D1", currentManagedID: 1,
          spaces: [
            user(1, uuid: "A"), user(2, uuid: "B"), user(3, uuid: "C"),
          ])
      ], store: store)
    XCTAssertEqual(before[0].spaces[1].displayName, "Email")

    // OS reindexes: now B is first. The name must move WITH B, not stay at index 1.
    let after = Reconciler.resolve(
      displays: [
        RawDisplay(
          displayID: "D1", currentManagedID: 2,
          spaces: [
            user(2, uuid: "B"), user(1, uuid: "A"), user(3, uuid: "C"),
          ])
      ], store: store)
    XCTAssertEqual(after[0].spaces[0].displayName, "Email")
    XCTAssertEqual(after[0].spaces[1].displayName, "Desktop 2")  // A, now positional #2
  }

  // The empty-uuid first Space (observed in the spike) must key on id64, not collapse with others.
  func testEmptyUUIDFallsBackToId64() {
    let store = SpaceStore(fileURL: nil)
    let firstSpace = SpaceIdentity(uuid: "", id64: 1)
    XCTAssertEqual(firstSpace.key, "id64:1")
    store.setName("Main", for: firstSpace)

    let resolved = Reconciler.resolve(
      displays: [
        RawDisplay(
          displayID: "D1", currentManagedID: 1,
          spaces: [
            RawSpace(managedID: 1, id64: 1, uuid: "", isFullscreen: false),
            user(2, uuid: "B"),
          ])
      ], store: store)
    XCTAssertEqual(resolved[0].spaces[0].displayName, "Main")
    XCTAssertEqual(resolved[0].spaces[1].displayName, "Desktop 2")
  }

  // Fullscreen spaces are not nameable Spaces and must be excluded from ordering.
  func testFullscreenExcludedAndDoesNotConsumeAnIndex() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: 1,
      spaces: [
        user(1, uuid: "A"),
        RawSpace(managedID: 99, id64: 99, uuid: "FS", isFullscreen: true),
        user(2, uuid: "B"),
      ])
    let resolved = Reconciler.resolve(displays: [display], store: SpaceStore(fileURL: nil))
    XCTAssertEqual(resolved[0].spaces.count, 2)
    XCTAssertEqual(resolved[0].spaces.map(\.displayName), ["Desktop 1", "Desktop 2"])
  }

  func testCurrentSpaceLookup() {
    let displays = Reconciler.resolve(
      displays: [
        RawDisplay(
          displayID: "D1", currentManagedID: 3,
          spaces: [
            user(1, uuid: "A"), user(2, uuid: "B"), user(3, uuid: "C"),
          ])
      ], store: SpaceStore(fileURL: nil))
    XCTAssertEqual(Reconciler.currentSpace(in: displays)?.identity.uuid, "C")
  }
}
