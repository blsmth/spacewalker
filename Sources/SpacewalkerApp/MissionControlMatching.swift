import ApplicationServices
import CoreGraphics

/// A snapshot of one AX element's role/title/frame plus its children — the seam between the
/// live, cross-process `AXUIElement` world and `MissionControlMatching`'s pure, synchronous,
/// host-language-independent matching logic (#22). Test code builds these by hand to exercise
/// the matcher against synthetic fixtures shaped like a German/Japanese/etc. Dock without a live
/// Dock or a non-English system; `MissionControlOverlay` builds real ones by walking
/// `AXUIElement`s through `AXUtil` (see `MissionControlOverlay.axNode(_:depth:)`).
struct AXNode {
  let role: String?
  let title: String?
  let frame: CGRect?
  let children: [AXNode]

  init(role: String? = nil, title: String? = nil, frame: CGRect? = nil, children: [AXNode] = []) {
    self.role = role
    self.title = title
    self.frame = frame
    self.children = children
  }
}

/// A single AX button candidate for a Spaces Bar row: the frame (always needed) and title (an
/// optional, per-locale-unreliable confidence signal — see `MissionControlMatching.hasTrailingNumeral`).
struct DesktopButtonCandidate: Equatable {
  let rect: CGRect
  let title: String?
}

/// Pure matching logic for locating Mission Control's group and its desktop-button row inside
/// the Dock's AX tree, by role and structural shape rather than by localized English titles
/// (#22 — the previous `title == "Mission Control"` / `"Spaces Bar"` / `"Desktop N"` checks went
/// dark on any non-English system: see the issue and `MissionControlOverlay` for the live AX
/// plumbing this wraps, and PLAN.md §4.3 for the spike this tree shape comes from).
///
/// Deliberately free of `AXUIElement`/`@MainActor`/any live AX call so it can be exercised
/// directly against hand-built `AXNode` fixtures in `MissionControlMatchingTests` — including
/// fixtures shaped like non-English systems this environment cannot actually run against.
enum MissionControlMatching {

  enum RowMatching {
    /// Row members must agree on height and y-position within this many points to count as
    /// "the same horizontal bar" — loose enough for AX rounding, tight enough to reject a
    /// free-form spread of app-window thumbnails, which vary in both.
    static let alignmentTolerance: CGFloat = 2
    /// The previous implementation was two separately-bounded searches from the Mission Control
    /// group down to a button: `firstDescendant` (title == "Spaces Bar", `depth < 12`) then
    /// `collectDesktops` from there (`depth < 6`) — up to 18 levels of combined reach. This is a
    /// single DFS doing both jobs at once (no more separate "find the bar by title" step), so it
    /// uses the larger of the two old bounds rather than either alone, to avoid narrowing how
    /// deep a real, deeply-nested Spaces Bar could be found relative to before.
    static let maxTraversalDepth = 12
  }

  /// The Mission Control overlay group: a direct child of the Dock's `AXApplication` element
  /// whose role is `AXGroup` (`kAXGroupRole`) — never the element whose *title* happens to equal
  /// "Mission Control", which only holds on an English system. Mirrors
  /// `MissionControlOverlay.missionControlGroup(in:)`, which does the same check directly against
  /// a live `AXUIElement`'s children — see that method's doc comment for what's verified live vs.
  /// reasoned from PLAN.md's spike.
  static func missionControlGroup(among dockChildren: [AXNode]) -> AXNode? {
    dockChildren.first(where: { $0.role == kAXGroupRole })
  }

  /// (structural index, AX-global rect) for each desktop thumbnail button in the Spaces Bar —
  /// the desktop number assigned is the button's left-to-right position among its row
  /// (`index + 1`), never a value parsed out of a title, since the digit itself can be
  /// localized (e.g. Eastern Arabic numerals — see the issue).
  static func desktopRects(in missionControl: AXNode) -> [(n: Int, rect: CGRect)] {
    guard let row = bestButtonRow(in: missionControl) else { return [] }
    return row.enumerated().map { index, button in (index + 1, button.rect) }
  }

  /// Depth-first search for the most plausible "Spaces Bar" among all uniform rows of `AXButton`
  /// siblings found anywhere under `element` — see `uniformRow(among:)`. Candidates are scored
  /// by (a) whether every button's title ends in a numeral-like character in *any* script, then
  /// (b) member count; titles are a confidence signal only, never a requirement, since a button
  /// may expose no title at all. Ties keep the first-found row (DFS order), matching the
  /// previous implementation's "first match wins" behavior.
  static func bestButtonRow(in element: AXNode) -> [DesktopButtonCandidate]? {
    var best: [DesktopButtonCandidate]?
    collectRows(element, depth: 0, best: &best)
    return best
  }

  private static func collectRows(
    _ element: AXNode, depth: Int, best: inout [DesktopButtonCandidate]?
  ) {
    guard depth < RowMatching.maxTraversalDepth else { return }
    if let candidate = uniformRow(among: element.children),
      isCandidate(candidate, betterThan: best)
    {
      best = candidate
    }
    for child in element.children {
      collectRows(child, depth: depth + 1, best: &best)
    }
  }

  /// `children` filtered to `AXButton`s with a real, non-empty frame, kept only if they all
  /// share height and y-position within `RowMatching.alignmentTolerance` — i.e. actually form a
  /// single horizontal bar rather than a free-form cluster — sorted left to right. `nil` if no
  /// such button is present or they aren't aligned.
  static func uniformRow(among children: [AXNode]) -> [DesktopButtonCandidate]? {
    let buttons: [DesktopButtonCandidate] = children.compactMap { child in
      guard child.role == kAXButtonRole, let rect = child.frame, rect.width > 0, rect.height > 0
      else { return nil }
      return DesktopButtonCandidate(rect: rect, title: child.title)
    }
    guard !buttons.isEmpty else { return nil }
    let heights = buttons.map(\.rect.height)
    let ys = buttons.map(\.rect.origin.y)
    guard let maxHeight = heights.max(), let minHeight = heights.min(),
      let maxY = ys.max(), let minY = ys.min(),
      maxHeight - minHeight <= RowMatching.alignmentTolerance,
      maxY - minY <= RowMatching.alignmentTolerance
    else { return nil }
    return buttons.sorted { $0.rect.origin.x < $1.rect.origin.x }
  }

  /// True if `title` ends in at least one Unicode "number" character. `Character.isNumber`
  /// covers the Unicode Number category (decimal digits, letter numbers, and other numeral
  /// scripts) rather than just ASCII `0`–`9`, so this still fires for many — though not
  /// necessarily all — localized digit renderings. Used only as an extra confidence signal in
  /// `isCandidate`, never as a requirement.
  static func hasTrailingNumeral(_ title: String?) -> Bool {
    guard let last = title?.last else { return false }
    return last.isNumber
  }

  private static func isCandidate(
    _ candidate: [DesktopButtonCandidate], betterThan current: [DesktopButtonCandidate]?
  ) -> Bool {
    guard let current else { return true }
    let candidateNumeric = candidate.allSatisfy { hasTrailingNumeral($0.title) }
    let currentNumeric = current.allSatisfy { hasTrailingNumeral($0.title) }
    if candidateNumeric != currentNumeric { return candidateNumeric }
    return candidate.count > current.count
  }
}
