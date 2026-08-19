import CGSPrivate
import Foundation
import OSLog
import SpaceSwitching

/// Gathers a `DiagnosticsSnapshot` from the live system for "Copy Diagnostics" (issue #25). Kept
/// separate from `DiagnosticsFormatter` (pure) and `DiagnosticsSnapshot` (data) so the actual
/// rendering/redaction logic stays unit-testable without AppKit, `OSLogStore`, or a live
/// WindowServer.
///
/// `@MainActor` because `DesktopShortcuts`/`MoveSpaceShortcuts`/`KeySynth` read live system state
/// synchronously and `AppDelegate` (the only caller) is itself main-actor confined.
@MainActor
enum DiagnosticsCollector {

  private enum Constants {
    /// How far back to look for recent entries — long enough to cover "I just tried to switch and
    /// it didn't work", short enough that a dump doesn't balloon into unrelated history.
    static let logWindow: TimeInterval = 15 * 60
    static let maxLogEntries = 40
  }

  /// - Parameter displaySpaceCounts: Space count per display, in display order — passed in rather
  ///   than read from `SpaceService` directly so this type has no dependency on `SpaceService`
  ///   (and can't accidentally reach for a `ResolvedSpace`/name through it).
  static func snapshot(displaySpaceCounts: [Int]) -> DiagnosticsSnapshot {
    let processInfo = ProcessInfo.processInfo
    return DiagnosticsSnapshot(
      macOSVersion: processInfo.operatingSystemVersionString,
      appVersion: AppVersion.shortVersion,
      appBuild: AppVersion.build,
      architecture: architecture,
      symbolAvailability: .current,
      accessibilityTrusted: KeySynth.hasAccessibility,
      desktopShortcutsBound: DesktopShortcuts.allEnabled(upTo: DesktopShortcuts.maxDirectDesktop),
      moveSpaceShortcutsBound: MoveSpaceShortcuts.allEnabled(),
      displaySpaceCounts: displaySpaceCounts,
      recentLogs: harvestRecentLogs()
    )
  }

  private static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }

  /// Reads this process's own recent `app.spacewalker` entries back out of the unified log.
  /// Verified live under `scripts/make-app.sh`'s hardened-runtime + dev-identity signing (see the
  /// PR body) — `OSLogStore(scope: .currentProcessIdentifier)` works with no extra entitlement.
  /// Still handled as a `throws` call and given an explicit fallback: if a future OS/signing
  /// change breaks it, "Copy Diagnostics" must degrade to a usable command, not a silent gap.
  private static func harvestRecentLogs() -> LogHarvest {
    do {
      let store = try OSLogStore(scope: .currentProcessIdentifier)
      let position = store.position(timeIntervalSinceEnd: -Constants.logWindow)
      let predicate = NSPredicate(format: "subsystem == %@", "app.spacewalker")
      let entries = try store.getEntries(at: position, matching: predicate)

      let timeFormatter = DateFormatter()
      timeFormatter.dateFormat = "HH:mm:ss"

      var lines: [String] = []
      for entry in entries {
        guard let logEntry = entry as? OSLogEntryLog else { continue }
        let time = timeFormatter.string(from: logEntry.date)
        lines.append("\(time) [\(logEntry.category)] \(logEntry.composedMessage)")
      }
      return .entries(Array(lines.suffix(Constants.maxLogEntries)))
    } catch {
      // Deliberately not including `error` itself in the reason — see `LogHarvest.unavailable`'s
      // doc comment on why the message must always be a fixed, developer-authored string.
      log.error("Copy Diagnostics: OSLogStore harvest failed, falling back to a log-show command")
      return .unavailable(reason: "log store access failed on this build")
    }
  }
}
