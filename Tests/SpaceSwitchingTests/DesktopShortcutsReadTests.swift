import XCTest

@testable import SpaceSwitching

/// Tests for `DesktopShortcuts.isSatisfied`, the pure read-side check behind `allEnabled` — issue
/// #6: `allEnabled` used to check only the `enabled` flag, so a user who rebound "Switch to
/// Desktop N" elsewhere still passed it, and `switchToDesktop` synthesized a ⌃N bound to nothing.
/// Never touches CFPreferences — see `DesktopShortcutsPlanTests` for the write-side (`plan`) tests.
final class DesktopShortcutsReadTests: XCTestCase {

  private let controlMask = 262_144
  /// (ascii, keycode) for ⌃1, matching DesktopShortcuts' own table.
  private let digit1: [Int] = [49, 18]

  func testAbsentEntryIsNotSatisfied() {
    XCTAssertFalse(DesktopShortcuts.isSatisfied(existing: [:], upTo: 1))
  }

  func testDisabledEntryIsNotSatisfied() {
    let existing: [String: Any] = [
      "118": ["enabled": 0, "value": ["type": "standard", "parameters": digit1 + [controlMask]]]
    ]
    XCTAssertFalse(DesktopShortcuts.isSatisfied(existing: existing, upTo: 1))
  }

  func testEnabledAndCorrectlyBoundIsSatisfied() {
    let existing: [String: Any] = [
      "118": ["enabled": 1, "value": ["type": "standard", "parameters": digit1 + [controlMask]]]
    ]
    XCTAssertTrue(DesktopShortcuts.isSatisfied(existing: existing, upTo: 1))
  }

  func testEnabledButReboundToADifferentKeyIsNotSatisfied() {
    // The exact regression from issue #6: enabled == 1, but the binding itself points elsewhere
    // (here, ⌥1's keycode/modifier instead of ⌃1's).
    let existing: [String: Any] = [
      "118": ["enabled": 1, "value": ["type": "standard", "parameters": [49, 18, 524_288]]]
    ]
    XCTAssertFalse(DesktopShortcuts.isSatisfied(existing: existing, upTo: 1))
  }

  func testEnabledWithNoValueAtAllIsNotSatisfied() {
    // Unlike MoveSpaceShortcuts' ids 79/81, Desktop-N ships off by default, so an entry with no
    // recorded binding is never something we can assume is "correctly bound" — see
    // MoveSpaceShortcuts' type doc comment for the contrasting case.
    let existing: [String: Any] = ["118": ["enabled": 1]]
    XCTAssertFalse(DesktopShortcuts.isSatisfied(existing: existing, upTo: 1))
  }

  func testDifferingAsciiPlaceholderStillCountsAsBound() {
    // `isBoundToTarget` deliberately ignores parameters[0] (the ASCII/glyph placeholder) — only
    // the keycode and modifier mask are load-bearing for which key event actually fires.
    let existing: [String: Any] = [
      "118": ["enabled": 1, "value": ["type": "standard", "parameters": [0, 18, controlMask]]]
    ]
    XCTAssertTrue(DesktopShortcuts.isSatisfied(existing: existing, upTo: 1))
  }

  func testAllDesktopsInRangeMustBeSatisfied() {
    let onlyDesktop1: [String: Any] = [
      "118": ["enabled": 1, "value": ["type": "standard", "parameters": digit1 + [controlMask]]]
    ]
    XCTAssertFalse(DesktopShortcuts.isSatisfied(existing: onlyDesktop1, upTo: 2))
  }
}
