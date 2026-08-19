import CGSPrivate

/// Stable identity for a Space, robust to the OS reindexing Space order/IDs.
///
/// Identity prefers the OS `uuid`, but the `/spike` probe proved the first Space can report an
/// **empty** uuid — so we fall back to `id64`. (`/spike` no longer lives in `main`; it is
/// archived at the `spike-archive` tag:
/// https://github.com/blsmth/spacewalker/tree/spike-archive/spike.) `key` is a convenience
/// string for callers that just need a
/// stable-for-now `Identifiable`/diffing token (the HUD's "current vs. previous" tracking, SwiftUI
/// list ids) — it is allowed to change if a Space's uuid appears later.
///
/// `SpaceStore` does NOT use `key` to persist metadata (issue #17): it keys on `uuid` and `id64`
/// directly and self-heals a record from one to the other, because collapsing that decision into
/// a single string is exactly what made the old `id64:`/`uuid:` key format unable to distinguish
/// "this Space just started reporting a uuid" from "an unrelated Space reused this id64".
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

  public var key: String {
    uuid.isEmpty ? "id64:\(id64)" : "uuid:\(uuid)"
  }
}
