import XCTest

@testable import SpacewalkerApp

/// Coverage for `ScreenDisplayIdentity.candidateDisplayIDs(uuid:isMainScreen:)` — PR #63's second
/// review, finding F2/F4. `cgsDisplayID(for:)`/`cgsDisplayIDCandidates(for:)` themselves need a
/// live `NSScreen` and stay untested here (as before); this is the pure seam the review's F4
/// finding asked for, so a mutation to how "Main" is tried can't silently ship unnoticed the way
/// the composition bugs in `MissionControlOverlay.render(_:)` did.
final class ScreenDisplayIdentityTests: XCTestCase {

  /// The steady-state case for a display with "Displays have separate Spaces" ON: the UUID alone
  /// is the correct (and only) candidate.
  func testCandidateDisplayIDsIsJustTheUUIDForANonMainScreenWithoutSpansDisplays() {
    let ids = ScreenDisplayIdentity.candidateDisplayIDs(uuid: "ABCD-1234", isMainScreen: false)
    XCTAssertEqual(ids, ["ABCD-1234"])
  }

  /// Finding F2: with "Displays have separate Spaces" OFF, CGS reports the literal string
  /// `"Main"` for the active display's own topology entry, not a UUID — confirmed against this
  /// machine's own `com.apple.spaces.plist` and Hammerspoon's `hs.spaces`. The UUID is still
  /// tried first (correct if the setting turns out to be ON after all), with `"Main"` as the
  /// fallback for the menu-bar screen specifically.
  func testCandidateDisplayIDsTriesUUIDThenMainForTheMenuBarScreen() {
    let ids = ScreenDisplayIdentity.candidateDisplayIDs(uuid: "ABCD-1234", isMainScreen: true)
    XCTAssertEqual(ids, ["ABCD-1234", "Main"])
  }

  /// `cgsDisplayID(for:)` itself can return `nil` (e.g. `CGDisplayCreateUUIDFromDisplayID`
  /// failing) — `"Main"` must still be offered as a candidate for the menu-bar screen even then,
  /// rather than the whole lookup coming back empty.
  func testCandidateDisplayIDsStillOffersMainWhenTheUUIDIsNil() {
    let ids = ScreenDisplayIdentity.candidateDisplayIDs(uuid: nil, isMainScreen: true)
    XCTAssertEqual(ids, ["Main"])
  }

  /// A non-main screen with no resolvable UUID at all has no candidates — never guess `"Main"`
  /// for a screen that isn't the menu-bar one, since CGS's `"Main"` key specifically means that
  /// display.
  func testCandidateDisplayIDsIsEmptyForANonMainScreenWithNoUUID() {
    XCTAssertTrue(ScreenDisplayIdentity.candidateDisplayIDs(uuid: nil, isMainScreen: false).isEmpty)
  }
}
