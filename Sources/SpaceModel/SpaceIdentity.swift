import CGSPrivate

/// Stable identity for a Space, robust to the OS reindexing Space order/IDs.
///
/// Identity prefers the OS `uuid`, but the spike proved the first Space can report an **empty**
/// uuid — so we fall back to `id64`. `key` is what we persist metadata against; it must never
/// collapse two distinct Spaces onto the same string, nor change for a Space across its lifetime.
public struct SpaceIdentity: Hashable, Sendable {
  public let uuid: String
  public let id64: Int

  public init(uuid: String, id64: Int) {
    self.uuid = uuid
    self.id64 = id64
  }

  public init(raw: RawSpace) {
    self.init(uuid: raw.uuid, id64: raw.id64)
  }

  /// The persistence key. UUID when present, else a namespaced id64 so the two spaces never clash.
  public var key: String {
    uuid.isEmpty ? "id64:\(id64)" : "uuid:\(uuid)"
  }
}
