import Foundation

/// A single Space as reported by the WindowServer, before any of our metadata is applied.
public struct RawSpace: Equatable, Sendable {
  public let managedID: Int
  public let id64: Int
  /// OS-provided UUID. **Can be empty** for the first Space (observed in the spike:
  /// `uuid="", managed=1, id64=1`) — never key identity on this alone.
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

  public var isAvailable: Bool {
    SkyLightSymbols.mainConnectionID != nil && SkyLightSymbols.copyManagedDisplaySpaces != nil
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

    return raw.map { display in
      let displayID = display["Display Identifier"] as? String ?? "Main"
      let currentManaged =
        (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
      let spaces = (display["Spaces"] as? [[String: Any]] ?? []).map { s -> RawSpace in
        let type = s["type"] as? Int ?? 0  // 0 = user desktop, 4 = fullscreen
        return RawSpace(
          managedID: s["ManagedSpaceID"] as? Int ?? -1,
          id64: s["id64"] as? Int ?? -1,
          uuid: s["uuid"] as? String ?? "",
          isFullscreen: type != 0
        )
      }
      return RawDisplay(displayID: displayID, currentManagedID: currentManaged, spaces: spaces)
    }
  }

  public func activeSpaceID() -> UInt64? {
    guard let cid = connectionID(), let fn = SkyLightSymbols.getActiveSpace else { return nil }
    return fn(cid)
  }
}
