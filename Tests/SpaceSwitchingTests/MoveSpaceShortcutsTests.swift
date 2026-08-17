import XCTest

@testable import SpaceSwitching

/// Tests for `MoveSpaceShortcuts` (issue #7 — ids 79/81, "Move left/right a space", which the walk
/// path depends on and which nothing previously checked at all). Mirrors
/// `DesktopShortcutsPlanTests`' style. Never touches CFPreferences.
final class MoveSpaceShortcutsTests: XCTestCase {

  private let controlMask = 262_144
  /// Arrow keycodes `MoveSpaceShortcuts` targets.
  private let leftKeycode = 123
  private let rightKeycode = 124

  // MARK: isSatisfied (read side)

  func testAbsentEntryIsNotSatisfied() {
    XCTAssertFalse(MoveSpaceShortcuts.isSatisfied(existing: [:], direction: .left))
  }

  func testDisabledEntryIsNotSatisfied() {
    let existing: [String: Any] = ["79": ["enabled": 0]]
    XCTAssertFalse(MoveSpaceShortcuts.isSatisfied(existing: existing, direction: .left))
  }

  func testEnabledWithNoExplicitValueIsSatisfied() {
    // The shape a factory-default, never-customized entry actually has on a real machine (verified
    // via `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys`) — see the type doc
    // comment for why this counts as "correctly bound", unlike an absent DesktopShortcuts entry.
    let existing: [String: Any] = ["79": ["enabled": 1]]
    XCTAssertTrue(MoveSpaceShortcuts.isSatisfied(existing: existing, direction: .left))
  }

  /// Pins the *exact* runtime type CFPreferences hands back for these ids, which is not the type
  /// every other fixture here uses.
  ///
  /// Verified live on macOS 15: ids 79/81 come back as `__NSCFBoolean` (they are still at their
  /// factory default, which macOS stores as a real boolean), while id 118 — written by Spacewalker
  /// itself — comes back as `__NSCFNumber`. `isEnabled` reads the flag with `as? Int`, which
  /// bridges `__NSCFBoolean` to 1 correctly, so this works today.
  ///
  /// It is fragile in a way an `Int` literal cannot catch: a Swift `Bool` boxed in `Any` returns
  /// nil from `as? Int`. Any future refactor that swaps this fixture shape, or reads the flag as
  /// `as? Bool` instead, would keep every other test in this file green while silently breaking
  /// detection for 79/81 on every real machine — which is precisely the class of bug issue #7 was
  /// filed about.
  func testFactoryDefaultBooleanEnabledFlagIsRead() {
    let existing: [String: Any] = ["79": ["enabled": NSNumber(value: true)]]
    XCTAssertTrue(MoveSpaceShortcuts.isSatisfied(existing: existing, direction: .left))

    let disabled: [String: Any] = ["79": ["enabled": NSNumber(value: false)]]
    XCTAssertFalse(MoveSpaceShortcuts.isSatisfied(existing: disabled, direction: .left))
  }

  func testEnabledAndExplicitlyBoundToTargetIsSatisfied() {
    let existing: [String: Any] = [
      "81": [
        "enabled": 1,
        "value": ["type": "standard", "parameters": [0xFFFF, rightKeycode, controlMask]],
      ]
    ]
    XCTAssertTrue(MoveSpaceShortcuts.isSatisfied(existing: existing, direction: .right))
  }

  func testEnabledButReboundToADifferentKeyIsNotSatisfied() {
    let existing: [String: Any] = [
      "79": [
        "enabled": 1,
        "value": ["type": "standard", "parameters": [0xFFFF, 999, controlMask]],
      ]
    ]
    XCTAssertFalse(MoveSpaceShortcuts.isSatisfied(existing: existing, direction: .left))
  }

  func testEnabledButReboundToADifferentModifierIsNotSatisfied() {
    let existing: [String: Any] = [
      "81": [
        "enabled": 1,
        "value": ["type": "standard", "parameters": [0xFFFF, rightKeycode, 524_288]],  // ⌥→
      ]
    ]
    XCTAssertFalse(MoveSpaceShortcuts.isSatisfied(existing: existing, direction: .right))
  }

  func testBothMustBeSatisfiedForOverallCheck() {
    let leftOnly: [String: Any] = ["79": ["enabled": 1], "81": ["enabled": 0]]
    XCTAssertFalse(MoveSpaceShortcuts.isSatisfied(existing: leftOnly))

    let both: [String: Any] = ["79": ["enabled": 1], "81": ["enabled": 1]]
    XCTAssertTrue(MoveSpaceShortcuts.isSatisfied(existing: both))
  }

  // MARK: plan (write side)

  func testPlanWritesAbsentEntries() {
    let (updated, conflicts) = MoveSpaceShortcuts.plan(existing: [:])

    let left = updated["79"] as? [String: Any]
    XCTAssertEqual(left?["enabled"] as? Int, 1)
    let leftParameters = (left?["value"] as? [String: Any])?["parameters"] as? [Int]
    XCTAssertEqual(leftParameters, [0xFFFF, leftKeycode, controlMask])

    let right = updated["81"] as? [String: Any]
    let rightParameters = (right?["value"] as? [String: Any])?["parameters"] as? [Int]
    XCTAssertEqual(rightParameters, [0xFFFF, rightKeycode, controlMask])

    XCTAssertTrue(conflicts.isEmpty)
  }

  func testPlanClaimsADisabledEntryRegardlessOfPriorBinding() {
    let existing: [String: Any] = [
      "79": ["enabled": 0, "value": ["type": "standard", "parameters": [999, 999, controlMask]]]
    ]
    let (updated, conflicts) = MoveSpaceShortcuts.plan(existing: existing)

    let parameters =
      ((updated["79"] as? [String: Any])?["value"] as? [String: Any])?["parameters"]
      as? [Int]
    XCTAssertEqual(parameters, [0xFFFF, leftKeycode, controlMask])
    XCTAssertTrue(conflicts.isEmpty)
  }

  func testPlanRewritesTheFactoryDefaultExplicitlyWithoutFlaggingAConflict() {
    let existing: [String: Any] = ["79": ["enabled": 1]]
    let (updated, conflicts) = MoveSpaceShortcuts.plan(existing: existing)

    let parameters =
      ((updated["79"] as? [String: Any])?["value"] as? [String: Any])?["parameters"]
      as? [Int]
    XCTAssertEqual(parameters, [0xFFFF, leftKeycode, controlMask])
    XCTAssertTrue(conflicts.isEmpty, "the factory default is a harmless no-op rewrite")
  }

  func testPlanLeavesADeliberateReboundAloneAndReportsIt() {
    let existing: [String: Any] = [
      "81": ["enabled": 1, "value": ["type": "standard", "parameters": [999, 999, controlMask]]]
    ]
    let (updated, conflicts) = MoveSpaceShortcuts.plan(existing: existing)

    let parameters =
      ((updated["81"] as? [String: Any])?["value"] as? [String: Any])?["parameters"]
      as? [Int]
    XCTAssertEqual(parameters, [999, 999, controlMask], "a deliberate user rebinding must survive")
    XCTAssertEqual(conflicts, [.right])
  }

  func testPlanPreservesUnrelatedSymbolicHotkeys() {
    let existing: [String: Any] = ["118": ["enabled": 1, "value": ["type": "standard"]]]
    let (updated, _) = MoveSpaceShortcuts.plan(existing: existing)

    XCTAssertNotNil(updated["118"], "entries outside our ids must never be touched")
  }
}
