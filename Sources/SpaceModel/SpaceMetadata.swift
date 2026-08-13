import Foundation

/// User-assigned metadata for a Space. Only *custom* values live here — an unnamed Space has no
/// entry at all and falls back to a positional default ("Desktop N"), so defaults always track the
/// current ordering while custom names stick to the Space's identity.
public struct SpaceMetadata: Codable, Equatable, Sendable {
  /// Custom name. `nil` ⇒ use the positional default.
  public var name: String?
  /// SF Symbol name for the Space's icon (e.g. "envelope", "hammer").
  public var symbolName: String?
  /// Accent color as "#RRGGBB".
  public var colorHex: String?

  public init(name: String? = nil, symbolName: String? = nil, colorHex: String? = nil) {
    self.name = name
    self.symbolName = symbolName
    self.colorHex = colorHex
  }

  /// True when this metadata carries nothing worth persisting.
  public var isEmpty: Bool {
    (name?.isEmpty ?? true) && (symbolName?.isEmpty ?? true) && (colorHex?.isEmpty ?? true)
  }
}
