import CGSPrivate
import Foundation

/// Everything "Copy Diagnostics" (issue #25) puts on the clipboard, gathered into one value type
/// so `DiagnosticsFormatter.render` can be a pure function, testable without AppKit, the
/// WindowServer, or a live `OSLogStore` — see `DiagnosticsCollector` for the impure side that
/// builds one of these from the real system.
///
/// Deliberately does NOT accept `ResolvedSpace`, `SpaceMetadata`, or `ResolvedDisplay` — every
/// stored property here is a count, a boolean, or a short OS/app-version string, so there is no
/// parameter this type could use to carry a Space name, a custom symbol/color choice, a window
/// title, a username, or a path. The one exception is `recentLogs`, which holds free text read
/// back from the system log — see `DiagnosticsFormatter`'s doc comment for how that text is
/// still kept safe to paste publicly.
struct DiagnosticsSnapshot: Sendable, Equatable {
  var macOSVersion: String
  var appVersion: String
  var appBuild: String
  /// Compile-time target architecture ("arm64" / "x86_64" / "unknown").
  var architecture: String
  var symbolAvailability: SkyLightSymbolAvailability
  var accessibilityTrusted: Bool
  /// "Switch to Desktop N" (⌃1…⌃9) — powers direct one-hop jumps.
  var desktopShortcutsBound: Bool
  /// "Move left/right a space" (⌃←/⌃→) — powers the walk path every switch beyond ⌃9 relies on.
  var moveSpaceShortcutsBound: Bool
  /// Space *count* per display, in display order. Never a name, UUID, or other identifier.
  var displaySpaceCounts: [Int]
  /// False once `TopologyValidator` has rejected a topology read this run (issue #24) — duplicate
  /// or negative `id64`, the signature of a renamed/restructured CGS key. Distinct from whether the
  /// three symbols resolved (`symbolAvailability`): this can be false even when every symbol
  /// resolved, if what they return no longer has the shape this build expects.
  var topologyShapeValid: Bool
  var recentLogs: LogHarvest
}

/// Outcome of trying to harvest recent `os.Logger` entries via `OSLogStore` (see
/// `DiagnosticsCollector`). Modeled explicitly, rather than `[String]?`, so a failed read renders
/// as an actionable fallback command instead of a silently empty section — see issue #25's
/// requirement to verify `OSLogStore` actually works under this app's hardened-runtime signing
/// before relying on it.
enum LogHarvest: Sendable, Equatable {
  case entries([String])
  /// `reason` is always a short, developer-authored, hardcoded string — never the raw thrown
  /// error — so a failure message can never smuggle system/user data into the dump.
  case unavailable(reason: String)
}
