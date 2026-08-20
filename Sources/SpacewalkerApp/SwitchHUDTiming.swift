import Foundation

/// Pure decision logic behind `SwitchHUD`'s async fade/debounce state machine — extracted so the
/// tricky invariants (generation-token staleness, rapid-switch debouncing, out-of-order clear
/// requests) are unit-testable without a live `NSPanel`/`NSAnimationContext`, which in turn keeps
/// `SwitchHUD` itself a thin AppKit shell. This file only re-states the invariants `SwitchHUD`'s
/// own doc comments already explain as pure functions — it does not change or rediscover them.
enum SwitchHUDTiming {

  /// How close together two flash requests have to land to count as "hammering" — see
  /// `SwitchHUD.flash(_:)`.
  static let rapidSuccessionThreshold: TimeInterval = 0.22

  /// True when `now` falls within `threshold` of `previousRequestAt` — the switch-hammering case
  /// where `SwitchHUD.flash(_:)` blanks the HUD instantly and defers to the Space it finally
  /// settles on, rather than flashing every intermediate one.
  static func isRapidSuccession(
    now: Date, previousRequestAt: Date, threshold: TimeInterval = rapidSuccessionThreshold
  ) -> Bool {
    now.timeIntervalSince(previousRequestAt) < threshold
  }

  /// True when a `clearIfStale(asOf:)` request is still valid — i.e. no flash has been requested
  /// since the event that's asking to clear, so nothing fresher would be wiped out. False means a
  /// flash newer than `eventTimestamp` already superseded this clear request, which must then be
  /// left alone (see `SwitchHUD.clearIfStale(asOf:)`'s doc comment for the race this guards
  /// against).
  static func isClearStillValid(lastFlashRequestedAt: TimeInterval, eventTimestamp: TimeInterval)
    -> Bool
  {
    lastFlashRequestedAt < eventTimestamp
  }
}

/// Tracks the fade-out generation token `SwitchHUD.present()` uses to tell a stale fade's
/// completion handler apart from the current one.
///
/// `hideWork?.cancel()` only stops a *pending* fade from starting; once a fade is already in
/// flight (`NSAnimationContext`'s own animator has taken over `alphaValue`), cancelling the
/// `DispatchWorkItem` is a no-op — the animator keeps interpolating back toward 0 on its own
/// schedule no matter what the property is reassigned to directly. `SwitchHUD.present()` instead
/// starts a fresh zero-duration animation that supersedes whatever is running, and gates every
/// fade's completion handler on this token, so a superseded fade can recognize itself as stale
/// even if it lands after the panel coincidentally already reads `alphaValue == 0` (e.g. because
/// something else, like an explicit `clear()`, already snapped it there).
struct FadeGenerationTracker: Equatable {

  private(set) var current = 0

  /// Called every time a new flash is presented. Returns the generation token that presentation
  /// now owns — the caller passes this into its fade's completion handler.
  @discardableResult
  mutating func advance() -> Int {
    current += 1
    return current
  }

  /// True if `generation` is still the current one, i.e. nothing newer has been presented since —
  /// so a fade completion carrying this token is allowed to actually order the panel out.
  func isCurrent(_ generation: Int) -> Bool {
    generation == current
  }
}
