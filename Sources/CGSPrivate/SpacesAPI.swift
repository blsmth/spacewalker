import Foundation

/// A single Space as reported by the WindowServer, before any of our metadata is applied.
public struct RawSpace: Equatable, Sendable {
  public let managedID: Int
  public let id64: Int
  /// OS-provided UUID. **Can be empty** for the first Space (observed in the `/spike` probe,
  /// which no longer lives in `main` — it is archived at the `spike-archive` tag:
  /// https://github.com/blsmth/spacewalker/tree/spike-archive/spike — `uuid="", managed=1,
  /// id64=1`) — never key identity on this alone.
  public let uuid: String
  public let isFullscreen: Bool

  public init(managedID: Int, id64: Int, uuid: String, isFullscreen: Bool) {
    self.managedID = managedID
    self.id64 = id64
    self.uuid = uuid
    self.isFullscreen = isFullscreen
  }
}

/// One display and its ordered list of Spaces.
public struct RawDisplay: Equatable, Sendable {
  public let displayID: String
  public let currentManagedID: Int
  public let spaces: [RawSpace]

  public init(displayID: String, currentManagedID: Int, spaces: [RawSpace]) {
    self.displayID = displayID
    self.currentManagedID = currentManagedID
    self.spaces = spaces
  }
}

/// Read-only view of the system's Space topology. The rest of the app depends on this protocol,
/// not on the private symbols behind it — so it can be mocked in tests and swapped if Apple moves.
public protocol SpacesReading: Sendable {
  /// True when the private symbols this implementation needs resolved successfully.
  var isAvailable: Bool { get }
  /// Current Space topology across all displays, in WindowServer order.
  func displays() -> [RawDisplay]
  /// The active Space's id64 on the primary display (cross-check / convenience).
  func activeSpaceID() -> UInt64?
}

/// Concrete `SpacesReading` backed by the private CGS APIs.
public final class CGSSpacesAPI: SpacesReading {

  public init() {}

  /// Symbols alone — does NOT prove the data they return still has the shape we expect. A `dlsym`
  /// hit and a garbage return value are different failure modes (issue #24): the former means this
  /// OS removed the entry point; the latter means it's still there but renamed/restructured what it
  /// hands back. `displays()`'s explicit-failure parsing is what catches the second case, and
  /// `SpaceService` is what turns a parse failure into a sticky "stop trusting this API" state —
  /// this property only ever reflects symbol resolution.
  public var isAvailable: Bool {
    SkyLightSymbols.mainConnectionID != nil && SkyLightSymbols.copyManagedDisplaySpaces != nil
      && SkyLightSymbols.getActiveSpace != nil
  }

  private func connectionID() -> Int32? {
    SkyLightSymbols.mainConnectionID?()
  }

  public func displays() -> [RawDisplay] {
    guard let cid = connectionID(),
      let copy = SkyLightSymbols.copyManagedDisplaySpaces,
      let raw = copy(cid)?.takeRetainedValue() as? [[String: Any]]
    else {
      return []
    }

    var parsed: [RawDisplay] = []
    for dict in raw {
      guard let display = Self.parseDisplay(dict) else {
        // `dict`'s keys are CGS's own, not user data, but logging them anyway would still just be
        // internal shape metadata — kept out regardless, matching this module's log-nothing-but-
        // fixed-strings-and-counts style. See `SpaceService`'s sticky shape-invalid flag for what
        // actually surfaces this to the user.
        log.error(
          """
          CGSCopyManagedDisplaySpaces returned a display dictionary shape this build doesn't \
          recognize (a required key is missing or the wrong type) — discarding this read rather \
          than resolving corrupt Space identities; this OS may need a Spacewalker update
          """)
        return []
      }
      parsed.append(display)
    }
    return parsed
  }

  /// Parses one entry of `CGSCopyManagedDisplaySpaces`'s top-level array, failing explicitly
  /// (`nil`) the instant a required key is missing or the wrong type — **never** silently
  /// defaulting (issue #24: the old `?? "Main"` / `?? -1` fallbacks made a renamed/restructured key
  /// indistinguishable from a legitimate reading). Internal (not `private`) so it's directly unit
  /// testable via `@testable import CGSPrivate` without a live WindowServer.
  static func parseDisplay(_ dict: [String: Any]) -> RawDisplay? {
    guard let displayID = dict["Display Identifier"] as? String,
      let currentSpace = dict["Current Space"] as? [String: Any],
      let currentManaged = currentSpace["ManagedSpaceID"] as? Int,
      let spaceDicts = dict["Spaces"] as? [[String: Any]]
    else {
      return nil
    }

    var spaces: [RawSpace] = []
    for spaceDict in spaceDicts {
      guard let space = parseSpace(spaceDict) else { return nil }
      spaces.append(space)
    }
    return RawDisplay(displayID: displayID, currentManagedID: currentManaged, spaces: spaces)
  }

  /// Parses one Space dictionary under a display's `"Spaces"` array. Same explicit-failure
  /// contract as `parseDisplay` — **with one deliberate exception**: `uuid` casting successfully to
  /// an empty string is NOT a failure. The archived `/spike` probe (see `RawSpace`'s doc comment
  /// above for the pointer) proved a display's first Space can legitimately report `uuid=""`
  /// (see also PLAN.md §2); only a *missing or wrong-typed*
  /// `"uuid"` key fails the parse, never a present-but-empty one.
  static func parseSpace(_ dict: [String: Any]) -> RawSpace? {
    guard let managedID = dict["ManagedSpaceID"] as? Int,
      let id64 = dict["id64"] as? Int,
      let uuid = dict["uuid"] as? String,
      let type = dict["type"] as? Int  // 0 = user desktop, 4 = fullscreen
    else {
      return nil
    }
    return RawSpace(managedID: managedID, id64: id64, uuid: uuid, isFullscreen: type != 0)
  }

  public func activeSpaceID() -> UInt64? {
    guard let cid = connectionID(), let fn = SkyLightSymbols.getActiveSpace else { return nil }
    return fn(cid)
  }
}
