import CGSPrivate
import Foundation
import SpaceSwitching

@testable import SpaceService

/// Test double for `SpacesReading` — the seam `SpacesAPI.swift` was built to be mocked through,
/// and never had a fake written for it until now (#5's ask).
///
/// `@unchecked Sendable`: `SpacesReading` refines `Sendable` (so `SpaceService` can hold one as a
/// stored property under Swift 6 strict concurrency), but this fake needs plain `var` state that
/// tests mutate directly (`activeID`) to simulate the WindowServer's Space changing mid-switch.
/// Safe because every instance is constructed and touched from a single `@MainActor` test method
/// and never shared across concurrency domains — the same "provably single-threaded" justification
/// this codebase already uses for `nonisolated(unsafe)` storage (see `SwitchKeyTap`).
final class FakeSpacesReading: SpacesReading, @unchecked Sendable {

  var isAvailable: Bool = true
  var rawDisplays: [RawDisplay]
  /// Mutate directly to simulate the WindowServer's active Space id64 changing (or staying put)
  /// between `switchTo`'s pre-synthesis baseline read and its post-verification re-read.
  var activeID: UInt64?

  init(displays: [RawDisplay], activeID: UInt64?) {
    self.rawDisplays = displays
    self.activeID = activeID
  }

  func displays() -> [RawDisplay] { rawDisplays }
  func activeSpaceID() -> UInt64? { activeID }
}

/// Test double for `KeySynthesizing` — lets `SpaceService` be driven through a switch without
/// spawning real `osascript`/System Events processes.
@MainActor
final class FakeKeySynth: KeySynthesizing {

  var stepResult: Result<Void, KeySynth.SynthError> = .success(())
  var switchToDesktopResult: Result<Void, KeySynth.SynthError> = .success(())
  private(set) var stepCallCount = 0
  private(set) var switchToDesktopCallCount = 0

  func step(_ direction: SwitchDirection) -> Result<Void, KeySynth.SynthError> {
    stepCallCount += 1
    return stepResult
  }

  func switchToDesktop(_ n: Int) -> Result<Void, KeySynth.SynthError> {
    switchToDesktopCallCount += 1
    return switchToDesktopResult
  }
}

/// Captures the work `SpaceService` schedules for post-switch verification instead of running it
/// after a real ~250ms delay, so tests control exactly when it fires (and what `FakeSpacesReading`
/// reports at that moment) — deterministic, no `sleep`-based timing.
@MainActor
final class DeferredScheduler {

  private(set) var pending: (() -> Void)?
  /// Fires the instant work is scheduled, so a test can `await` it instead of polling.
  var onScheduled: (() -> Void)?

  func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
    pending = work
    onScheduled?()
  }

  /// Run the pending work, if any, and clear it.
  func fire() {
    let work = pending
    pending = nil
    work?()
  }
}
