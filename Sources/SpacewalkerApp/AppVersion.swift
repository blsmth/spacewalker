import Foundation

/// Single source for the app's version/build strings (issue #32). Previously read independently in
/// `DiagnosticsCollector` and `AppDelegate`'s About panel with the same fallback duplicated in both
/// places — this is the one place that knows the `Info.plist` keys and the "unknown" fallback.
enum AppVersion {

  private enum Constants {
    static let unknown = "unknown"
  }

  /// `CFBundleShortVersionString`, e.g. "0.1.0".
  static var shortVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? Constants.unknown
  }

  /// `CFBundleVersion`, the build number, e.g. "1".
  static var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? Constants.unknown
  }

  /// "0.1.0 (1)" for UI that wants both in one string (the About panel).
  static var displayString: String {
    "\(shortVersion) (\(build))"
  }
}
