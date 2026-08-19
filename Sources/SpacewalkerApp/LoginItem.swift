import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the "Launch at Login" menu toggle
/// (PLAN.md §5, issue #32). macOS 13+, matching `Package.swift`'s deployment target.
///
/// `isEnabled` deliberately re-reads `SMAppService.mainApp.status` every call rather than caching
/// it: a user can flip this from System Settings ▸ General ▸ Login Items & Extensions independently
/// of Spacewalker's own menu, and the menu item (rebuilt on every open, like the rest of the status
/// menu) must reflect that, not a stale value from whenever Spacewalker last wrote it.
///
/// Only meaningful from a properly bundled, launchd-registered `.app` — `swift run` has no bundle
/// identifier for `SMAppService` to register, so `register()` throws there. See the PR body for
/// what could and couldn't be exercised outside a bundled build.
enum LoginItem {

  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Registers or unregisters the login item. Logs and returns rather than crashing if
  /// registration throws (e.g. run outside a bundled `.app`, or launchd rejects it).
  static func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      let action = enabled ? "registration" : "unregistration"
      log.error(
        "Login item \(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
