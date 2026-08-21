import CGSPrivate

/// A Space combined with its resolved metadata and position — the unit the UI renders.
public struct ResolvedSpace: Identifiable, Sendable, Equatable {
  public let identity: SpaceIdentity
  public let managedID: Int
  public let displayID: String
  /// 0-based position among *user* Spaces on this display (fullscreen spaces excluded).
  /// This is the coordinate the ⌃N "Switch to Desktop N" shortcut addresses — macOS numbers only
  /// nameable desktops, so a fullscreen tile sitting between two desktops does not consume a number.
  public let userIndex: Int
  /// 0-based position in this display's full Mission Control strip, *counting* fullscreen tiles.
  /// This is the coordinate ⌃←/→ traverses: those shortcuts step through every tile on the strip,
  /// fullscreen apps included. Distinct from `userIndex` precisely because the two shortcut
  /// families disagree, and conflating them walks the wrong number of hops (issue: silent wrong
  /// destination reported as success).
  public let stripIndex: Int
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
  /// Strip position (see `ResolvedSpace.stripIndex`) of this display's *active* tile, whether or
  /// not that tile is a nameable user Space — `nil` only when the active Space lives on another
  /// display.
  ///
  /// The asymmetry against `spaces.first(where: \.isCurrent)` is deliberate and is the whole point
  /// of this property: when the user is inside a fullscreen app, that tile is dropped from `spaces`
  /// (it isn't nameable), so `isCurrent` is nowhere to be found — but the display still *hosts* the
  /// active Space and we can still walk out of it. Treating "no current user Space" as "the active
  /// Space is on some other display" is what made every switch from a fullscreen app on a
  /// single-display Mac fail with `.crossDisplayUnsupported`.
  public let currentStripIndex: Int?

  /// True when this display holds the active tile, including a fullscreen one.
  public var hostsCurrentSpace: Bool { currentStripIndex != nil }
}

/// Turns raw WindowServer topology + stored metadata into resolved, ordered Spaces.
/// Pure and deterministic — the core of the unit tests.
public enum Reconciler {

  public static func resolve(displays: [RawDisplay], store: SpaceStore) -> [ResolvedDisplay] {
    displays.map { display in
      var userIndex = 0
      var currentStripIndex: Int?
      var spaces: [ResolvedSpace] = []

      for (stripIndex, raw) in display.spaces.enumerated() {
        let isCurrent = raw.managedID == display.currentManagedID
        // Record the active tile's strip position *before* the fullscreen filter, so a fullscreen
        // active Space still marks this display as hosting the current tile.
        if isCurrent { currentStripIndex = stripIndex }

        guard !raw.isFullscreen else { continue }  // fullscreen apps aren't nameable Spaces

        let identity = SpaceIdentity(raw: raw)
        spaces.append(
          ResolvedSpace(
            identity: identity,
            managedID: raw.managedID,
            displayID: display.displayID,
            userIndex: userIndex,
            stripIndex: stripIndex,
            isCurrent: isCurrent,
            metadata: store.metadata(for: identity)
          ))
        userIndex += 1
      }

      return ResolvedDisplay(
        displayID: display.displayID, spaces: spaces, currentStripIndex: currentStripIndex)
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
