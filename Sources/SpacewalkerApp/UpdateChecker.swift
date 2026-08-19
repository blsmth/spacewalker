import Foundation

/// Lightweight "is a newer release available" check (issue #32) — deliberately not Sparkle. This
/// app depends on private SkyLight/CGS symbols Apple can break in any macOS point release; the goal
/// here is the ability to *reach* a user stranded on a build that no longer works, not to
/// self-update them. See the PR body for the full rationale. (PLAN.md §6 still describes a Sparkle
/// appcast — that needs a follow-up now that this is the chosen approach, tracked separately so as
/// not to conflict with the in-flight PLAN.md rewrite.)
///
/// Respects the idle-first design issue #19 fought for: this never polls on a timer. It checks at
/// most once per launch, throttled to once per 24h via a persisted timestamp, plus an on-demand
/// "Check for Updates…" menu item that always runs regardless of the throttle. It is silent and
/// non-retrying on any failure — no network is the ordinary state for a menu-bar app on a laptop,
/// not an error worth surfacing.
@MainActor
final class UpdateChecker {

  struct UpdateInfo: Equatable, Sendable {
    /// The release tag as published, e.g. "v0.2.0" — shown to the user verbatim.
    let version: String
    let releaseURL: URL
  }

  private enum Constants {
    static let releasesEndpoint = URL(
      string: "https://api.github.com/repos/blsmth/spacewalker/releases/latest")!
    static let minimumCheckInterval: TimeInterval = 24 * 60 * 60
    static let lastCheckDefaultsKey = "UpdateCheckLastCheckDate"
  }

  private let session: URLSession
  private let defaults: UserDefaults
  private let currentVersion: SemVer?

  /// Set once a check finds a release newer than `currentVersion`. `AppDelegate` reads this
  /// synchronously when it rebuilds the menu (`menuNeedsUpdate` runs on every open), so there is no
  /// need to push a redraw from here.
  private(set) var available: UpdateInfo?
  /// Optional hook for a non-modal notice (e.g. a `SwitchHUD` flash) the moment a check finds
  /// something new. Never invoked for "no update"/"offline"/"malformed response" — those are
  /// silent by design.
  var onUpdateFound: ((UpdateInfo) -> Void)?

  /// `defaults` is injectable (rather than always `.standard`) so tests can verify the 24h
  /// throttle without touching this machine's real preferences.
  init(
    currentVersion: String = AppVersion.shortVersion, session: URLSession = .shared,
    defaults: UserDefaults = .standard
  ) {
    self.currentVersion = SemVer(currentVersion)
    self.session = session
    self.defaults = defaults
  }

  /// Call once at launch. Does nothing (no request at all) if the last check was under 24h ago.
  func checkIfDue(now: Date = Date()) {
    if let last = defaults.object(forKey: Constants.lastCheckDefaultsKey) as? Date,
      now.timeIntervalSince(last) < Constants.minimumCheckInterval
    {
      return
    }
    check()
  }

  /// "Check for Updates…" menu item — always runs, ignoring the 24h throttle.
  func checkNow() {
    check()
  }

  private func check() {
    defaults.set(Date(), forKey: Constants.lastCheckDefaultsKey)

    guard let currentVersion else {
      // Own version string failed to parse -- nothing to compare against, and worth knowing about
      // during development, but not something to retry or alert on.
      log.error("Update check skipped: could not parse this build's own version string")
      return
    }

    let request = URLRequest(url: Constants.releasesEndpoint)
    let task = session.dataTask(with: request) { [weak self] data, _, error in
      if let error {
        log.debug("Update check failed: \(error.localizedDescription, privacy: .public)")
        return
      }
      guard let data, let info = Self.parseRelease(data) else {
        log.debug("Update check: no usable release info in response")
        return
      }
      Task { @MainActor [weak self] in
        self?.handle(info, currentVersion: currentVersion)
      }
    }
    task.resume()
  }

  private func handle(_ info: UpdateInfo, currentVersion: SemVer) {
    guard let remoteVersion = SemVer(info.version), remoteVersion > currentVersion else { return }
    guard available != info else { return }  // already known; don't re-fire the callback
    available = info
    onUpdateFound?(info)
  }

  /// Pure parse of a GitHub "latest release" response into `UpdateInfo`. `nonisolated` and `static`
  /// so it can run off the main actor on whatever queue `URLSession` calls back on, without needing
  /// to hop first just to decode JSON. Internal (not `private`) so `UpdateCheckerTests` can exercise
  /// malformed/missing-field responses directly, without standing up a full mocked network round
  /// trip for every case.
  nonisolated static func parseRelease(_ data: Data) -> UpdateInfo? {
    struct Release: Decodable {
      let tagName: String
      let htmlURL: String

      enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
      }
    }

    guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
    guard let url = URL(string: release.htmlURL) else { return nil }
    return UpdateInfo(version: release.tagName, releaseURL: url)
  }
}
