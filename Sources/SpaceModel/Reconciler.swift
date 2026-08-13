import CGSPrivate

/// A Space combined with its resolved metadata and position — the unit the UI renders.
public struct ResolvedSpace: Identifiable, Sendable, Equatable {
  public let identity: SpaceIdentity
  public let managedID: Int
  public let displayID: String
  /// 0-based position among *user* Spaces on this display (fullscreen spaces excluded).
  public let userIndex: Int
  public let isCurrent: Bool
  public let metadata: SpaceMetadata?

  public var id: String { identity.key }

  /// Custom name if set, else the positional default.
  public var displayName: String {
    if let name = metadata?.name, !name.isEmpty { return name }
    return "Desktop \(userIndex + 1)"
  }

  public var isCustomNamed: Bool {
    !(metadata?.name?.isEmpty ?? true)
  }
}

/// One display's ordered, user-facing Spaces.
public struct ResolvedDisplay: Sendable, Equatable {
  public let displayID: String
  public let spaces: [ResolvedSpace]
}

/// Turns raw WindowServer topology + stored metadata into resolved, ordered Spaces.
/// Pure and deterministic — the core of the unit tests.
public enum Reconciler {

  public static func resolve(displays: [RawDisplay], store: SpaceStore) -> [ResolvedDisplay] {
    displays.map { display in
      var userIndex = 0
      let spaces: [ResolvedSpace] = display.spaces.compactMap { raw in
        guard !raw.isFullscreen else { return nil }  // fullscreen apps aren't nameable Spaces
        let identity = SpaceIdentity(raw: raw)
        let resolved = ResolvedSpace(
          identity: identity,
          managedID: raw.managedID,
          displayID: display.displayID,
          userIndex: userIndex,
          isCurrent: raw.managedID == display.currentManagedID,
          metadata: store.metadata(for: identity)
        )
        userIndex += 1
        return resolved
      }
      return ResolvedDisplay(displayID: display.displayID, spaces: spaces)
    }
  }

  /// The currently-active Space across all displays (first match), if any.
  public static func currentSpace(in displays: [ResolvedDisplay]) -> ResolvedSpace? {
    for display in displays {
      if let current = display.spaces.first(where: { $0.isCurrent }) { return current }
    }
    return nil
  }
}
