import CoreGraphics
import SpaceModel

/// Pure composition: resolves Mission Control's detected desktop-button rows into the exact set
/// of (Space, AX rect, owning screen frame) triples `MissionControlOverlay.render(_:)` draws —
/// the seam between AX-derived rows and this app's own `SpaceService` topology (issue #64 /
/// PR #63's finding F4).
///
/// This exists because the composition, not the extracted helpers it calls, is where both the
/// original crash (#64) and the second review's regressions (F1/F2/F3) actually lived: two
/// mutations of `render(_:)` itself — bypassing display attribution
/// (`let spacesByIndex = byDisplayAndIndex.values.first`) and reintroducing the flat, trapping
/// `Dictionary(uniqueKeysWithValues: spaces().map { ($0.userIndex, $0) })` — both passed the full
/// 217-test suite, because no test exercised `render(_:)`'s composition, only
/// `MissionControlOverlayGeometry`'s pure helpers in isolation. Routing every row through this one
/// pure, directly-tested function closes that gap: `MissionControlOverlay.render(_:)` should never
/// touch `spacesByDisplayAndIndex`/`screenFrame`/display-ID resolution itself again.
///
/// Free of any live `AXUIElement`/`NSScreen`/`ScreenDisplayIdentity` call — both the screen frames
/// and the display-ID candidates are injected — so `MissionControlRowResolutionTests` can
/// exercise the exact shapes that broke (a collapsed bar above the screen top, a `"Main"`-keyed
/// topology, the #64 duplicate-`userIndex` crash shape) without a live Dock, Mission Control, or a
/// second monitor.
enum MissionControlRowResolution {

  /// One Space's resolved on-screen placement: which `ResolvedSpace` to name, its AX-global rect
  /// (still AX coordinates — `render(_:)` owns the AX→Cocoa flip and the final local-rect
  /// conversion, both of which need the live `axAnchorScreen` height this function doesn't take),
  /// and the Cocoa-global frame of the physical screen it belongs to.
  struct ResolvedLabel: Equatable {
    let space: ResolvedSpace
    let axRect: CGRect
    let screenFrame: CGRect
  }

  /// - Parameters:
  ///   - rows: One array per detected Spaces Bar row (`MissionControlMatching.desktopRows(in:)`),
  ///     each already independently numbered from 1.
  ///   - allSpaces: The live topology (`SpaceService.spaces()`) to resolve `n` against.
  ///   - anchorScreenHeight: The AX/Cocoa coordinate anchor's height — see
  ///     `MissionControlOverlayGeometry.cocoaGlobalRect(fromAX:mainScreenHeight:)`.
  ///   - screenFrames: Every attached screen's frame, in Cocoa global coordinates.
  ///   - displayIDCandidates: Maps a resolved screen frame to the ordered `"Display Identifier"`
  ///     strings to try against `allSpaces`' own `displayID`s — the live caller supplies
  ///     `ScreenDisplayIdentity.cgsDisplayIDCandidates(for:)`; tests supply a synthetic closure.
  static func resolve(
    rows: [[(n: Int, rect: CGRect)]],
    allSpaces: [ResolvedSpace],
    anchorScreenHeight: CGFloat,
    screenFrames: [CGRect],
    displayIDCandidates: (CGRect) -> [String]
  ) -> [ResolvedLabel] {
    let byDisplayAndIndex = MissionControlOverlayGeometry.spacesByDisplayAndIndex(allSpaces)
    var results: [ResolvedLabel] = []

    for row in rows {
      // Nit (noted, not fixed): only the row's *first* button decides which screen/display the
      // whole row belongs to. Every button in a row already shares one physical screen in
      // practice — `MissionControlMatching.uniformRow` rejects any row whose buttons aren't
      // x-contiguous (issue #64) — so this is safe for a real Spaces Bar. It would misattribute a
      // row that somehow straddled two screens (using the first button's screen/name for every
      // button, including ones visually on a different screen), which isn't possible for a row
      // `uniformRow` actually produced, but is worth calling out explicitly rather than silently
      // assuming.
      guard let anchorRect = row.first?.rect else { continue }
      let anchorCocoa = MissionControlOverlayGeometry.cocoaGlobalRect(
        fromAX: anchorRect, mainScreenHeight: anchorScreenHeight)
      guard
        let screenFrame = MissionControlOverlayGeometry.screenFrame(
          containing: anchorCocoa, among: screenFrames)
      else { continue }  // no screens at all — see screenFrame(containing:among:)

      // Try the screen's UUID first, then any other candidates (e.g. "Main") in order — the
      // first one that's actually a key in this display's topology wins. See F2's doc comment on
      // `ScreenDisplayIdentity.candidateDisplayIDs`.
      guard
        let spacesByIndex = displayIDCandidates(screenFrame).lazy.compactMap({
          byDisplayAndIndex[$0]
        }).first
      else { continue }  // this screen doesn't resolve to any known display in the topology

      for (n, axRect) in row {
        guard let space = spacesByIndex[n - 1] else { continue }  // Desktop N -> userIndex N-1
        guard space.isCustomNamed else { continue }  // only show names the user actually set
        results.append(ResolvedLabel(space: space, axRect: axRect, screenFrame: screenFrame))
      }
    }
    return results
  }
}
