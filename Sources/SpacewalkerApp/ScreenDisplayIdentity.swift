import AppKit
import CoreGraphics

/// Maps an `NSScreen` to the same display-identifier string CGS reports via
/// `CGSCopyManagedDisplaySpaces`'s `"Display Identifier"` entry (`RawDisplay.displayID` /
/// `ResolvedSpace.displayID`) — needed so `MissionControlOverlay` can tell which of
/// `SpaceService`'s displays a Mission Control desktop-button row actually belongs to (issue
/// #64), instead of looking a row's positional index up in one flattened, cross-display list.
///
/// Uses only the public `CGDisplayCreateUUIDFromDisplayID` API — not a private symbol, so this
/// doesn't belong in `CGSPrivate` and doesn't need `SkyLightSymbols`' dlsym machinery. Verified
/// live on this (single-display) machine: for the one attached display, the UUID string this
/// produces is byte-for-byte identical to `CGSCopyManagedDisplaySpaces`'s own `"Display
/// Identifier"` value for that same screen (checked with a standalone probe against a live
/// `CGSMainConnectionID`/`CGSCopyManagedDisplaySpaces` read, not assumed). **Not** re-verified
/// against a real second monitor — see the PR body for exactly what that does and doesn't prove;
/// every display should get its own stable UUID from this API, but whether CGS's own identifier
/// stays in lockstep with it once a second display attaches/detaches is unconfirmed.
enum ScreenDisplayIdentity {
  /// Nit (noted, not fixed): `CGDisplayCreateUUIDFromDisplayID` silently resolves a bogus/zero
  /// `CGDirectDisplayID` to the **main** display's own UUID rather than failing — confirmed in
  /// Apple's own header documentation, not just assumed. `number` above always comes from a real
  /// `NSScreen`'s own `"NSScreenNumber"` device description key, which should never actually be
  /// `0`, but if that assumption is ever wrong (a screen AppKit can't fully identify, say), this
  /// would misreport that screen as the main display instead of returning `nil`.
  static func cgsDisplayID(for screen: NSScreen) -> String? {
    // `NSDeviceDescriptionKey` has no typed `.screenNumber` case on this SDK — "NSScreenNumber"
    // is the documented raw key AppKit itself populates `deviceDescription` with.
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    let directID = CGDirectDisplayID(number.uint32Value)
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(directID) else { return nil }
    return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
  }

  /// Ordered `"Display Identifier"` candidates to try against `SpaceService`'s own topology when
  /// resolving a Mission Control row to the display it belongs to (see
  /// `MissionControlRowResolution`) — PR #63 review, finding F2.
  ///
  /// CGS reports the **literal string `"Main"`**, not a UUID, for the active display's own entry
  /// whenever "Displays have separate Spaces" is OFF. Two independent confirmations: (1) this
  /// machine's own `~/Library/Preferences/com.apple.spaces.plist` has a
  /// `"Display Identifier" = Main` entry for its one attached monitor, alongside two other,
  /// UUID-keyed entries; (2) Hammerspoon's `hs.spaces` has mapped `"Main"` to the main screen's
  /// UUID and back for years, explicitly gated on `screensHaveSeparateSpaces()` being false
  /// (`spaces.lua:361-369,456,529-530`). The setting is a *global* toggle (not per-display), so
  /// this can affect a single-display machine too — the `uuid`/`isMainScreen` lookup below tries
  /// the UUID first (correct when the setting is ON), then `"Main"` for the menu-bar screen
  /// specifically (correct when it's OFF), rather than committing to one interpretation and
  /// missing every row whenever the user is actually in the other mode.
  ///
  /// Pure and free of any live `NSScreen`/CGS call — `cgsDisplayIDCandidates(for:)` below is the
  /// live wrapper `MissionControlOverlay` actually calls; this is the seam a test exercises
  /// directly (see `ScreenDisplayIdentityTests`).
  static func candidateDisplayIDs(uuid: String?, isMainScreen: Bool) -> [String] {
    var ids: [String] = []
    if let uuid {
      ids.append(uuid)
    }
    if isMainScreen {
      ids.append("Main")
    }
    return ids
  }

  /// Live wrapper: `candidateDisplayIDs(uuid:isMainScreen:)` fed from `screen`'s own UUID (via
  /// `cgsDisplayID(for:)`) and whether it's the one sitting at Cocoa global origin `(0, 0)` — the
  /// menu-bar screen, which is what `"Main"` means to CGS (not `NSScreen.main`, which tracks key-
  /// window focus instead; see `MissionControlOverlay.axAnchorScreen()`'s doc comment for the
  /// same distinction).
  static func cgsDisplayIDCandidates(for screen: NSScreen) -> [String] {
    candidateDisplayIDs(uuid: cgsDisplayID(for: screen), isMainScreen: screen.frame.origin == .zero)
  }
}
