import XCTest

@testable import SpaceSwitching

/// Tests for `DesktopShortcuts.plan`, the pure decision function behind `enable()`. Never touches
/// CFPreferences — see issue #2, which requires writes to be non-clobbering.
final class DesktopShortcutsPlanTests: XCTestCase {

  /// Control modifier mask as used in symbolichotkeys parameters (mirrors the private constant).
  private let controlMask = 262144

  /// (ascii, keycode) for ⌃1, matching DesktopShortcuts' own table.
  private let digit1: [Int] = [49, 18]

  func testAbsentEntryIsWritten() {
    let (updated, conflicts) = DesktopShortcuts.plan(existing: [:], upTo: 1)

    let entry = updated["118"] as? [String: Any]
    XCTAssertEqual(entry?["enabled"] as? Int, 1, "an absent entry should be written and enabled")
    let parameters =
      (entry?["value"] as? [String: Any])?["parameters"] as? [Int]
    XCTAssertEqual(parameters, digit1 + [controlMask])
    XCTAssertTrue(conflicts.isEmpty)
  }

  func testDisabledEntryIsOverwrittenRegardlessOfPriorBinding() {
    let existing: [String: Any] = [
      "118": [
        "enabled": 0,
        "value": ["type": "standard", "parameters": [999, 999, controlMask]],
      ]
    ]
    let (updated, conflicts) = DesktopShortcuts.plan(existing: existing, upTo: 1)

    let parameters =
      ((updated["118"] as? [String: Any])?["value"] as? [String: Any])?["parameters"] as? [Int]
    XCTAssertEqual(parameters, digit1 + [controlMask], "a disabled entry is safe to claim")
    XCTAssertTrue(conflicts.isEmpty)
  }

  func testAlreadyBoundToOurTargetIsWrittenNotFlaggedAsConflict() {
    let existing: [String: Any] = [
      "118": [
        "enabled": 1,
        "value": ["type": "standard", "parameters": digit1 + [controlMask]],
      ]
    ]
    let (updated, conflicts) = DesktopShortcuts.plan(existing: existing, upTo: 1)

    let parameters =
      ((updated["118"] as? [String: Any])?["value"] as? [String: Any])?["parameters"] as? [Int]
    XCTAssertEqual(parameters, digit1 + [controlMask])
    XCTAssertTrue(conflicts.isEmpty, "our own binding is a no-op rewrite, never a conflict")
  }

  func testEnabledButReboundIsLeftAloneAndReportedAsConflict() {
    let existing: [String: Any] = [
      "118": [
        "enabled": 1,
        "value": ["type": "standard", "parameters": [999, 999, controlMask]],
      ]
    ]
    let (updated, conflicts) = DesktopShortcuts.plan(existing: existing, upTo: 1)

    let parameters =
      ((updated["118"] as? [String: Any])?["value"] as? [String: Any])?["parameters"] as? [Int]
    XCTAssertEqual(parameters, [999, 999, controlMask], "a deliberate user rebinding must survive")
    XCTAssertEqual(conflicts, [1])
  }

  func testPreservesUnrelatedSymbolicHotkeys() {
    let existing: [String: Any] = ["79": ["enabled": 1, "value": ["type": "standard"]]]
    let (updated, _) = DesktopShortcuts.plan(existing: existing, upTo: 1)

    XCTAssertNotNil(updated["79"], "entries outside our range must never be touched")
  }

  func testMixOfConflictsAndWritesAcrossMultipleDesktops() {
    let existing: [String: Any] = [
      "118": [
        "enabled": 1, "value": ["type": "standard", "parameters": [999, 999, controlMask]],
      ],
      "119": ["enabled": 0],
    ]
    let (updated, conflicts) = DesktopShortcuts.plan(existing: existing, upTo: 3)

    XCTAssertEqual(conflicts, [1], "only desktop 1 was rebound; 2 and 3 should be claimable")
    XCTAssertNotNil(updated["119"])
    XCTAssertNotNil(updated["120"])
  }
}
