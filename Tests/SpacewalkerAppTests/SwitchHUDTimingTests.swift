import XCTest

@testable import SpacewalkerApp

/// Covers issue #27's remaining `SwitchHUD` item: the async fade/debounce state machine has ~20
/// lines of its own commentary explaining why a naive implementation is wrong, and had zero
/// tests. `SwitchHUD` itself is untestable without a live `NSPanel`/`NSAnimationContext` and real
/// wall-clock animation timing, so the pure decision logic behind it — rapid-succession
/// debouncing, clear-request staleness, and the fade generation token — is extracted into
/// `SwitchHUDTiming`/`FadeGenerationTracker` (SwitchHUDTiming.swift) and exercised directly here.
/// `SwitchHUD` itself stays an untested thin AppKit shell around these functions; see that file's
/// doc comments for why each invariant exists.
final class SwitchHUDTimingTests: XCTestCase {

  // MARK: isRapidSuccession

  func testWellWithinThresholdIsRapid() {
    let previous = Date()
    let now = previous.addingTimeInterval(0.05)
    XCTAssertTrue(SwitchHUDTiming.isRapidSuccession(now: now, previousRequestAt: previous))
  }

  func testExactlyAtThresholdIsNotRapid() {
    let previous = Date()
    let now = previous.addingTimeInterval(SwitchHUDTiming.rapidSuccessionThreshold)
    XCTAssertFalse(SwitchHUDTiming.isRapidSuccession(now: now, previousRequestAt: previous))
  }

  func testWellPastThresholdIsNotRapid() {
    let previous = Date()
    let now = previous.addingTimeInterval(1.0)
    XCTAssertFalse(SwitchHUDTiming.isRapidSuccession(now: now, previousRequestAt: previous))
  }

  func testCustomThresholdIsRespected() {
    let previous = Date()
    let now = previous.addingTimeInterval(0.5)
    XCTAssertTrue(
      SwitchHUDTiming.isRapidSuccession(now: now, previousRequestAt: previous, threshold: 1.0))
    XCTAssertFalse(
      SwitchHUDTiming.isRapidSuccession(now: now, previousRequestAt: previous, threshold: 0.1))
  }

  // MARK: isClearStillValid

  func testClearIsValidWhenNoFlashHasBeenRequestedSinceTheEvent() {
    // The ordinary case: the last flash we know about predates the event that's now asking to
    // clear, so nothing fresher exists to protect — the clear may proceed.
    XCTAssertTrue(
      SwitchHUDTiming.isClearStillValid(lastFlashRequestedAt: 100, eventTimestamp: 200))
  }

  func testClearIsInvalidWhenAFlashArrivedAtOrAfterTheEvent() {
    // The race #27/SwitchHUD's doc comment describes: the 30ms poll already flashed the
    // destination Space before this (async, laggy) clear request runs. The flash must win.
    XCTAssertFalse(
      SwitchHUDTiming.isClearStillValid(lastFlashRequestedAt: 200, eventTimestamp: 200))
    XCTAssertFalse(
      SwitchHUDTiming.isClearStillValid(lastFlashRequestedAt: 300, eventTimestamp: 200))
  }
}

// MARK: - FadeGenerationTracker

final class FadeGenerationTrackerTests: XCTestCase {

  func testStartsAtGenerationZero() {
    let tracker = FadeGenerationTracker()
    XCTAssertEqual(tracker.current, 0)
    XCTAssertTrue(tracker.isCurrent(0))
  }

  func testAdvanceReturnsSequentiallyIncreasingTokens() {
    var tracker = FadeGenerationTracker()
    XCTAssertEqual(tracker.advance(), 1)
    XCTAssertEqual(tracker.advance(), 2)
    XCTAssertEqual(tracker.advance(), 3)
  }

  func testOnlyTheLatestGenerationIsCurrent() {
    var tracker = FadeGenerationTracker()
    let first = tracker.advance()
    let second = tracker.advance()

    XCTAssertFalse(tracker.isCurrent(first), "a superseded fade must recognize itself as stale")
    XCTAssertTrue(tracker.isCurrent(second))
  }

  /// The exact sequence #27 calls out: flash (shows the destination Space) -> failure (a
  /// `flashMessage` like "That Space no longer exists" supersedes it) -> clear. Each `present()`
  /// call (flash and failure both route through it) advances the generation, so the flash's
  /// eventual fade completion must not be allowed to `orderOut` the panel out from under the
  /// failure message, and the failure's own fade completion must still be honored through a
  /// subsequent `clear()` (which does not itself advance the generation).
  func testFlashFailureClearSequencePreservesGenerationInvariant() {
    var tracker = FadeGenerationTracker()

    // 1. flash(space) -> present() advances to generation 1.
    let flashGeneration = tracker.advance()
    XCTAssertTrue(tracker.isCurrent(flashGeneration))

    // 2. failure: a flashMessage(...) supersedes it -> present() advances to generation 2.
    let failureGeneration = tracker.advance()
    XCTAssertFalse(
      tracker.isCurrent(flashGeneration),
      "the flash's fade completion must not fire now that the failure message replaced it")
    XCTAssertTrue(tracker.isCurrent(failureGeneration))

    // 3. clear(): does not advance the generation (it hides immediately, bypassing present()).
    // A late-arriving fade completion for the failure message is still "current" — harmless,
    // since clear() has already driven alphaValue to 0 and ordered the panel out.
    XCTAssertTrue(
      tracker.isCurrent(failureGeneration),
      "clear() must not retroactively invalidate the generation it never advanced past")

    // A subsequent flash after the clear must still supersede correctly.
    let nextFlashGeneration = tracker.advance()
    XCTAssertFalse(tracker.isCurrent(failureGeneration))
    XCTAssertTrue(tracker.isCurrent(nextFlashGeneration))
  }

  func testEquatable() {
    var a = FadeGenerationTracker()
    var b = FadeGenerationTracker()
    XCTAssertEqual(a, b)

    a.advance()
    XCTAssertNotEqual(a, b)

    b.advance()
    XCTAssertEqual(a, b)
  }
}
