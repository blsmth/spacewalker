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
}
