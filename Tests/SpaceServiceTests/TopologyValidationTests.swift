import CGSPrivate
import SpaceModel
import XCTest

@testable import SpaceService

/// Covers issue #24: `SpaceService` must flip `isAvailable` (and stay flipped) once a topology
/// read's shape fails `TopologyValidator`, instead of resolving corrupt Space identities.
@MainActor
final class TopologyValidationTests: XCTestCase {

  private func garbageDisplay() -> RawDisplay {
    // What a future macOS renaming every key `CGSSpacesAPI` looks for would produce under the old
    // silent-default parsing: every Space collapses onto `SpaceIdentity.key == "id64:-1"`.
    RawDisplay(
      displayID: "D1", currentManagedID: -1,
      spaces: [
        RawSpace(managedID: -1, id64: -1, uuid: "", isFullscreen: false),
        RawSpace(managedID: -1, id64: -1, uuid: "", isFullscreen: false),
      ])
  }

  private func healthyDisplay() -> RawDisplay {
    RawDisplay(
      displayID: "D1", currentManagedID: 1,
      spaces: [
        RawSpace(managedID: 1, id64: 1, uuid: "AAAA", isFullscreen: false),
        RawSpace(managedID: 2, id64: 2, uuid: "BBBB", isFullscreen: false),
      ])
  }

  func testValidTopologyLeavesServiceAvailable() {
    let api = FakeSpacesReading(displays: [healthyDisplay()], activeID: 1)
    let service = SpaceService(api: api, store: SpaceStore(fileURL: nil))
    addTeardownBlock { service.stop() }

    service.refresh()

    XCTAssertTrue(service.isAvailable)
    XCTAssertTrue(service.topologyShapeValid)
    XCTAssertEqual(service.allSpaces.count, 2)
  }

  func testInvalidTopologyDisablesService() {
    let api = FakeSpacesReading(displays: [garbageDisplay()], activeID: nil)
    let service = SpaceService(api: api, store: SpaceStore(fileURL: nil))
    addTeardownBlock { service.stop() }

    service.refresh()

    XCTAssertFalse(service.isAvailable, "a shape validation failure must flip isAvailable")
    XCTAssertFalse(service.topologyShapeValid)
    XCTAssertEqual(
      service.allSpaces.count, 0,
      "must not resolve the corrupt topology into colliding ResolvedSpaces")
  }

  /// Sticky: even after a later read looks fine, `isAvailable` must not flicker back on.
  func testInvalidTopologyStaysDisabledEvenIfALaterReadLooksValid() {
    let api = FakeSpacesReading(displays: [garbageDisplay()], activeID: nil)
    let service = SpaceService(api: api, store: SpaceStore(fileURL: nil))
    addTeardownBlock { service.stop() }

    service.refresh()
    XCTAssertFalse(service.isAvailable)

    api.rawDisplays = [healthyDisplay()]
    service.refresh()

    XCTAssertFalse(
      service.isAvailable, "must not flicker back to available once shape has failed this run")
  }

  /// A prior known-good topology must survive a later corrupt read intact.
  func testInvalidTopologyDoesNotClobberLastGoodDisplays() {
    let api = FakeSpacesReading(displays: [healthyDisplay()], activeID: 1)
    let service = SpaceService(api: api, store: SpaceStore(fileURL: nil))
    addTeardownBlock { service.stop() }

    service.refresh()
    XCTAssertEqual(service.allSpaces.count, 2)

    api.rawDisplays = [garbageDisplay()]
    service.refresh()

    XCTAssertEqual(
      service.allSpaces.count, 2, "the last known-good topology must not be overwritten")
    XCTAssertFalse(service.isAvailable)
  }
}
