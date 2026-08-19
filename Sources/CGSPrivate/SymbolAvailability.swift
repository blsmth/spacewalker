import Foundation

/// Snapshot of which private CGS/SkyLight symbols resolved on this OS — safe to surface in
/// diagnostics (issue #25) because it exposes only booleans, never a raw symbol pointer. Nothing
/// above `CGSPrivate` needs to touch `SkyLightSymbols` directly just to report capability.
public struct SkyLightSymbolAvailability: Sendable, Equatable {
  public let mainConnectionID: Bool
  public let copyManagedDisplaySpaces: Bool
  public let getActiveSpace: Bool

  public init(mainConnectionID: Bool, copyManagedDisplaySpaces: Bool, getActiveSpace: Bool) {
    self.mainConnectionID = mainConnectionID
    self.copyManagedDisplaySpaces = copyManagedDisplaySpaces
    self.getActiveSpace = getActiveSpace
  }

  /// Resolves against this process's actual `dlsym` lookups — see `SkyLightSymbols`.
  public static var current: SkyLightSymbolAvailability {
    SkyLightSymbolAvailability(
      mainConnectionID: SkyLightSymbols.mainConnectionID != nil,
      copyManagedDisplaySpaces: SkyLightSymbols.copyManagedDisplaySpaces != nil,
      getActiveSpace: SkyLightSymbols.getActiveSpace != nil)
  }
}
