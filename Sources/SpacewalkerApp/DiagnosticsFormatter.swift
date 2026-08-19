import Foundation

/// Renders a `DiagnosticsSnapshot` into plain text safe to paste into a **public** GitHub issue
/// (issue #25). Pure — no I/O, no AppKit, no `OSLogStore` — so the redaction policy is directly
/// unit-testable; see `DiagnosticsFormatterTests`.
///
/// Redaction policy:
///   - MUST NOT appear: Space names, custom symbol/color choices, window titles, usernames,
///     home-directory paths, or any absolute filesystem path.
///   - MUST appear: macOS + app version/build, CPU architecture, which of the three CGS symbols
///     resolved, Accessibility trust state, display count and per-display Space *counts* (never
///     names), whether the symbolic-hotkey bindings switching depends on are present, and whether
///     the last topology read validated (issue #24) — this can fail even when every symbol
///     resolved, if what they return no longer has the shape this build expects.
///   - `DiagnosticsSnapshot` structurally cannot carry a Space name, custom symbol/color, window
///     title, or username — none of its fields are typed to hold one. The one free-text field,
///     `recentLogs`, is sourced from `OSLogStore`, whose `.private` `os.Logger` annotations
///     (PR-A) already keep paths and errors out of what comes back. Every harvested line is still
///     passed through `DiagnosticsRedactor` here as a backstop against a future log call that
///     forgets to mark a path `.private`.
enum DiagnosticsFormatter {

  private enum Constants {
    static let logStreamCommand =
      #"log stream --predicate 'subsystem == "app.spacewalker"' --level debug"#
    static let logShowCommand =
      #"log show --predicate 'subsystem == "app.spacewalker"' --last 15m"#
  }

  static func render(_ snapshot: DiagnosticsSnapshot) -> String {
    var lines: [String] = []

    lines.append("Spacewalker Diagnostics")
    lines.append(String(repeating: "-", count: 24))
    lines.append("macOS: \(snapshot.macOSVersion)")
    lines.append("Spacewalker: \(snapshot.appVersion) (\(snapshot.appBuild))")
    lines.append("Architecture: \(snapshot.architecture)")
    lines.append("")

    lines.append("Private API symbol resolution:")
    lines.append(
      "  CGSMainConnectionID: \(availability(snapshot.symbolAvailability.mainConnectionID))")
    lines.append(
      "  CGSCopyManagedDisplaySpaces: "
        + availability(snapshot.symbolAvailability.copyManagedDisplaySpaces))
    lines.append(
      "  CGSGetActiveSpace: \(availability(snapshot.symbolAvailability.getActiveSpace))")
    lines.append("")

    lines.append("Permissions:")
    lines.append("  Accessibility: \(snapshot.accessibilityTrusted ? "granted" : "not granted")")
    lines.append("")

    lines.append("Symbolic hotkeys:")
    lines.append(
      "  Switch to Desktop 1-9 (⌃1…⌃9): \(bound(snapshot.desktopShortcutsBound))")
    lines.append(
      "  Move left/right a space (⌃←/⌃→): \(bound(snapshot.moveSpaceShortcutsBound))")
    lines.append("")

    lines.append("Space topology:")
    lines.append("  Displays: \(snapshot.displaySpaceCounts.count)")
    if snapshot.displaySpaceCounts.isEmpty {
      lines.append("  Spaces per display: (unavailable)")
    } else {
      lines.append(
        "  Spaces per display: "
          + snapshot.displaySpaceCounts.map(String.init).joined(separator: ", "))
    }
    lines.append("  Shape validation: \(shapeValidation(snapshot.topologyShapeValid))")
    lines.append("")

    lines.append("Recent log entries (subsystem app.spacewalker):")
    switch snapshot.recentLogs {
    case .entries(let entries) where entries.isEmpty:
      lines.append("  (none captured)")
    case .entries(let entries):
      for entry in entries {
        lines.append("  \(DiagnosticsRedactor.redactPaths(in: entry))")
      }
    case .unavailable(let reason):
      lines.append("  Could not read the log store on this build (\(reason)). Run this instead:")
      lines.append("    \(Constants.logShowCommand)")
    }
    lines.append("")
    lines.append("For live tailing: \(Constants.logStreamCommand)")

    return lines.joined(separator: "\n")
  }

  private static func availability(_ resolved: Bool) -> String {
    resolved ? "resolved" : "MISSING — this OS may need a Spacewalker update"
  }

  private static func bound(_ isBound: Bool) -> String {
    isBound ? "bound" : "not bound"
  }

  private static func shapeValidation(_ isValid: Bool) -> String {
    isValid
      ? "ok"
      : "FAILED — this OS returned Space data in an unrecognized shape; Spacewalker may need an "
        + "update"
  }
}
