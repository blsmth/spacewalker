import CGSPrivate
import XCTest

@testable import SpaceModel

/// Covers issue #24's required fixture set: healthy, total-garbage (all keys renamed — simulated
/// here as the `id64 == -1`/`uuid == ""` values that shape would have produced under the old
/// silent-default parsing), duplicate `id64`, negative `id64`, and the legitimate empty-uuid case
/// that must still pass. Pure — no private symbol, no WindowServer.
final class TopologyValidatorTests: XCTestCase {

  private func space(managed: Int, id64: Int, uuid: String) -> RawSpace {
    RawSpace(managedID: managed, id64: id64, uuid: uuid, isFullscreen: false)
  }

  // MARK: Healthy

  func testHealthyTopologyIsValid() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: 1,
      spaces: [
        space(managed: 1, id64: 1, uuid: "AAAA"),
        space(managed: 2, id64: 2, uuid: "BBBB"),
      ])
    let result = TopologyValidator.validate([display])
    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.problems, [])
  }

  // MARK: Legitimate empty uuid (PLAN.md §2) — must still pass

  func testSingleLegitimateEmptyUUIDPasses() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: 1,
      spaces: [
        space(managed: 1, id64: 1, uuid: ""),  // the observed first-Space case
        space(managed: 2, id64: 2, uuid: "BBBB"),
      ])
    let result = TopologyValidator.validate([display])
    XCTAssertTrue(result.isValid, "a single legitimately-empty uuid must not be flagged")
  }

  // MARK: Duplicate id64

  /// Two Spaces sharing an `id64` but with distinct real uuids: `SpaceIdentity.key` prefers the
  /// uuid, so the *keys* don't collide — but `id64` is supposed to be a unique WindowServer id, so
  /// this must still be caught as its own problem, independent of the key-collision check.
  func testDuplicateID64WithDistinctUUIDsIsInvalid() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: 1,
      spaces: [
        space(managed: 1, id64: 7, uuid: "AAAA"),
        space(managed: 2, id64: 7, uuid: "BBBB"),
      ])
    let result = TopologyValidator.validate([display])
    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.problems.contains(.duplicateID64(displayID: "D1", id64: 7)))
    let hasIdentityCollision = result.problems.contains { problem in
      if case .duplicateIdentity = problem { return true }
      return false
    }
    XCTAssertFalse(
      hasIdentityCollision, "distinct uuids must not also be reported as a key collision")
  }

  /// The empty-uuid case collapses to `SpaceIdentity.key`'s `id64` fallback, so a shared `id64`
  /// here IS also a key collision — both problems fire.
  func testDuplicateID64WithBothEmptyUUIDsIsInvalidAsBothProblems() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: 1,
      spaces: [
        space(managed: 1, id64: 7, uuid: ""),
        space(managed: 2, id64: 7, uuid: ""),
      ])
    let result = TopologyValidator.validate([display])
    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.problems.contains(.duplicateID64(displayID: "D1", id64: 7)))
    XCTAssertTrue(result.problems.contains(.duplicateIdentity(displayID: "D1", key: "id64:7")))
  }

  /// The same `id64` recurring across *different* displays is not a problem — each display has
  /// its own WindowServer id space.
  func testSameID64AcrossDifferentDisplaysIsValid() {
    let displayA = RawDisplay(
      displayID: "A", currentManagedID: 1, spaces: [space(managed: 1, id64: 1, uuid: "AAAA")])
    let displayB = RawDisplay(
      displayID: "B", currentManagedID: 1, spaces: [space(managed: 1, id64: 1, uuid: "BBBB")])
    let result = TopologyValidator.validate([displayA, displayB])
    XCTAssertTrue(result.isValid)
  }

  // MARK: Negative id64

  func testNegativeID64IsInvalid() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: 1,
      spaces: [space(managed: 1, id64: -1, uuid: "AAAA")])
    let result = TopologyValidator.validate([display])
    XCTAssertFalse(result.isValid)
    XCTAssertTrue(result.problems.contains(.negativeID64(displayID: "D1", id64: -1)))
  }

  // MARK: Total garbage — the collapse-to-"id64:-1" scenario issue #24 is about

  /// Simulates what a future macOS renaming every key `CGSSpacesAPI` looks for would have produced
  /// under the old silent-default parsing: every Space resolves to `id64 == -1`, `uuid == ""`.
  /// Every one of them collapses onto the single `SpaceIdentity.key` `"id64:-1"` — exactly the
  /// collision `SpaceIdentity`'s own doc comment says must never happen. This must now be caught,
  /// not silently accepted as "one merged Space".
  func testTotalGarbageCollapsingToID64NegativeOneIsInvalid() {
    let display = RawDisplay(
      displayID: "D1", currentManagedID: -1,
      spaces: [
        space(managed: -1, id64: -1, uuid: ""),
        space(managed: -1, id64: -1, uuid: ""),
        space(managed: -1, id64: -1, uuid: ""),
      ])
    let result = TopologyValidator.validate([display])
    XCTAssertFalse(result.isValid)
    XCTAssertTrue(
      result.problems.contains(.duplicateIdentity(displayID: "D1", key: "id64:-1")),
      "every garbage Space must be caught colliding on the same identity key")
    XCTAssertTrue(result.problems.contains(.negativeID64(displayID: "D1", id64: -1)))
  }
}
