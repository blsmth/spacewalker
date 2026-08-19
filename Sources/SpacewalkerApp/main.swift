import AppKit
import Foundation

/// Writes a breadcrumb before the process dies of an uncaught Objective-C exception (issue #25).
///
/// **This is not crash reporting.** `NSSetUncaughtExceptionHandler` only fires for Objective-C
/// exceptions — it does NOT catch Swift runtime traps: `fatalError`, force-unwrapping `nil`,
/// array-out-of-bounds, or the force-cast class of bug issue #21 fixed. Since private-API
/// breakage (this app's biggest risk) mostly shows up as exactly those Swift traps, this handler
/// is a narrow win: it only helps for the AppKit/Cocoa exception case (e.g. an invalid key path,
/// an unrecognized selector reaching an NSObject).
///
/// Deliberately minimal: a single `os.Logger` call and nothing else. An exception handler runs on
/// the thread that raised the exception, moments before termination — not a place to allocate,
/// touch UI, or do file I/O. `os_log`'s own persistence to the unified log is the "breadcrumb";
/// there is nothing more to append here. `name`/`reason`/the call stack are AppKit/Foundation
/// implementation detail (selector names, class names, argument-count mismatches) rather than
/// user content, so they're logged `.public` — this is a developer-facing `log show`, not
/// something surfaced automatically in "Copy Diagnostics".
private func spacewalkerUncaughtExceptionHandler(_ exception: NSException) {
  log.fault(
    """
    Uncaught NSException (Objective-C only — does not catch Swift traps): \
    name=\(exception.name.rawValue, privacy: .public) \
    reason=\(exception.reason ?? "none", privacy: .public)
    """)
  log.fault(
    "Uncaught NSException call stack: \(exception.callStackSymbols.joined(separator: "\n"), privacy: .public)"
  )
}

NSSetUncaughtExceptionHandler(spacewalkerUncaughtExceptionHandler)

// Menu-bar–only agent app: no Dock icon, no main window. (LSUIElement in the bundle Info.plist;
// .accessory covers the same for a bare `swift run`.)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
