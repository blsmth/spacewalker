import CGSPrivate
import SpaceModel
import XCTest

@testable import SpaceService

/// Covers #5 (post-switch verification) and the `isSwitching` bookkeeping around it. `SpaceService`
/// is `@MainActor`-isolated, so the whole suite runs there; the fake `KeySynthesizing` and the
/// `DeferredScheduler` (see `Fakes.swift`) keep every test synchronous and system-free — no real
/// AppleScript, no real ~250ms sleeps.
@MainActor
final class SpaceServiceTests: XCTestCase {

  /// Two displays, with `current` and `target` both on `displayA` — the shape that matters for
  /// issue #23: a same-display switch with a second, unrelated display attached. `makeService`
  /// defaults `desktopShortcutsSatisfied` to `{ _ in false }` (always take the walk path) so most
  /// of this suite stays free of `DesktopShortcuts.allEnabled`'s real
  /// `com.apple.symbolichotkeys` read; `SpaceServiceDirectJumpGateTests` below overrides it to
  /// exercise the direct-jump path deterministically instead.
  private enum Fixture {
    static let currentID64: UInt64 = 101
    static let targetID64: UInt64 = 102

    static func twoDisplays() -> [RawDisplay] {
      let current = RawSpace(
        managedID: 1, id64: Int(currentID64), uuid: "current-uuid", isFullscreen: false)
      let target = RawSpace(
        managedID: 2, id64: Int(targetID64), uuid: "target-uuid", isFullscreen: false)
      let displayA = RawDisplay(displayID: "A", currentManagedID: 1, spaces: [current, target])

      // A second display, otherwise irrelevant, purely to prove same-display gating doesn't
      // depend on `displays.count`.
      let other = RawSpace(managedID: 10, id64: 999, uuid: "other-uuid", isFullscreen: false)
      let displayB = RawDisplay(displayID: "B", currentManagedID: 10, spaces: [other])
      return [displayA, displayB]
    }

    /// `current` active on `displayA`, `target` living only on `displayB` — an actual
    /// cross-display switch attempt.
    static func crossDisplay() -> [RawDisplay] {
      let current = RawSpace(
        managedID: 1, id64: Int(currentID64), uuid: "current-uuid", isFullscreen: false)
      let displayA = RawDisplay(displayID: "A", currentManagedID: 1, spaces: [current])

      let target = RawSpace(
        managedID: 2, id64: Int(targetID64), uuid: "target-uuid", isFullscreen: false)
      let displayB = RawDisplay(displayID: "B", currentManagedID: 99, spaces: [target])
      return [displayA, displayB]
    }

    static var currentKey: String { SpaceIdentity(uuid: "current-uuid", id64: 101).key }
    static var targetKey: String { SpaceIdentity(uuid: "target-uuid", id64: 102).key }
  }

  private func makeService(
    activeID: UInt64?, keySynth: FakeKeySynth = FakeKeySynth(),
    fastPollScheduler: DeferredScheduler = DeferredScheduler(),
    rawDisplays: [RawDisplay] = Fixture.twoDisplays(),
    desktopShortcutsSatisfied: @escaping (Int) -> Bool = { _ in false }
  ) -> (service: SpaceService, api: FakeSpacesReading, scheduler: DeferredScheduler) {
    let api = FakeSpacesReading(displays: rawDisplays, activeID: activeID)
    let scheduler = DeferredScheduler()
    let service = SpaceService(
      api: api, store: SpaceStore(fileURL: nil), keySynth: keySynth,
      verificationDelay: 0.25, scheduleAfterDelay: scheduler.schedule,
      scheduleFastPollExpiry: fastPollScheduler.schedule,
      desktopShortcutsSatisfied: desktopShortcutsSatisfied)
    service.refresh()
    // #19: `switchTo`/`noteExternalSwitchKeySeen` can arm a real `.common`-mode `Timer` on
    // `RunLoop.main`. Tear it down after every test instead of leaking a live 33Hz timer into
    // the rest of the suite (harmless once `service` itself deallocates — the timer's closure
    // only holds a weak reference — but there's no reason to let it keep firing until then).
    addTeardownBlock { service.stop() }
    return (service, api, scheduler)
  }

  // MARK: .ok / .switchDidNotTake

  func testSwitchReportsOkWhenActiveSpaceChanges() async {
    let (service, api, scheduler) = makeService(activeID: Fixture.currentID64)

    let scheduled = expectation(description: "verification scheduled")
    scheduler.onScheduled = { scheduled.fulfill() }
    var result: SpaceService.SwitchResult?
    let completed = expectation(description: "switch completed")
    service.switchTo(key: Fixture.targetKey) {
      result = $0
      completed.fulfill()
    }

    await fulfillment(of: [scheduled], timeout: 2)
    api.activeID = Fixture.targetID64  // the WindowServer actually moved
    scheduler.fire()

    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(result, .ok)
  }

  func testSwitchReportsDidNotTakeWhenActiveSpaceUnchanged() async {
    let (service, _, scheduler) = makeService(activeID: Fixture.currentID64)

    let scheduled = expectation(description: "verification scheduled")
    scheduler.onScheduled = { scheduled.fulfill() }
    var result: SpaceService.SwitchResult?
    let completed = expectation(description: "switch completed")
    service.switchTo(key: Fixture.targetKey) {
      result = $0
      completed.fulfill()
    }

    await fulfillment(of: [scheduled], timeout: 2)
    // api.activeID left unchanged — the shortcut was delivered but never honored.
    scheduler.fire()

    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(result, .switchDidNotTake)
  }

  // MARK: .alreadyThere short-circuits verification

  func testAlreadyThereSkipsVerification() {
    let (service, _, scheduler) = makeService(activeID: Fixture.currentID64)

    var result: SpaceService.SwitchResult?
    service.switchTo(key: Fixture.currentKey) { result = $0 }

    XCTAssertEqual(result, .alreadyThere)
    XCTAssertNil(scheduler.pending, "alreadyThere must not schedule a verification read")
  }

  func testAlreadyThereDoesNotDriveKeySynth() {
    let keySynth = FakeKeySynth()
    let (service, _, _) = makeService(activeID: Fixture.currentID64, keySynth: keySynth)

    service.switchTo(key: Fixture.currentKey) { _ in }

    XCTAssertEqual(keySynth.stepCallCount, 0)
    XCTAssertEqual(keySynth.switchToDesktopCallCount, 0)
  }

  // MARK: isSwitching is always cleared

  func testIsSwitchingClearedAfterSuccess() async {
    let (service, api, scheduler) = makeService(activeID: Fixture.currentID64)

    let scheduled = expectation(description: "verification scheduled")
    scheduler.onScheduled = { scheduled.fulfill() }
    let completed = expectation(description: "switch completed")
    service.switchTo(key: Fixture.targetKey) { _ in completed.fulfill() }

    await fulfillment(of: [scheduled], timeout: 2)
    api.activeID = Fixture.targetID64
    scheduler.fire()
    await fulfillment(of: [completed], timeout: 1)

    // If isSwitching were still true, this would report `.busy` instead of `.alreadyThere` — the
    // fake topology's `currentManagedID` is static, so `currentKey` reads as "current" regardless
    // of the switch that just happened; this test only cares whether `isSwitching` unblocked.
    var second: SpaceService.SwitchResult?
    service.switchTo(key: Fixture.currentKey) { second = $0 }
    XCTAssertEqual(second, .alreadyThere)
  }

  func testIsSwitchingClearedAfterFailure() async {
    let (service, _, scheduler) = makeService(activeID: Fixture.currentID64)

    let scheduled = expectation(description: "verification scheduled")
    scheduler.onScheduled = { scheduled.fulfill() }
    let completed = expectation(description: "switch completed")
    service.switchTo(key: Fixture.targetKey) { _ in completed.fulfill() }

    await fulfillment(of: [scheduled], timeout: 2)
    // api.activeID left unchanged — this switch fails with .switchDidNotTake.
    scheduler.fire()
    await fulfillment(of: [completed], timeout: 1)

    // isSwitching must not be wedged by the new failure case — a subsequent attempt should
    // proceed normally (not report .busy) rather than being stuck forever.
    var second: SpaceService.SwitchResult?
    service.switchTo(key: Fixture.currentKey) { second = $0 }
    XCTAssertEqual(second, .alreadyThere)
  }

  func testOverlappingSwitchReportsBusy() {
    let (service, _, _) = makeService(activeID: Fixture.currentID64)

    service.switchTo(key: Fixture.targetKey) { _ in }  // left in flight — verification never fires

    var second: SpaceService.SwitchResult?
    service.switchTo(key: Fixture.currentKey) { second = $0 }

    XCTAssertEqual(second, .busy)
  }

  // MARK: Fast poll gating (#19)

  func testSwitchArmsFastPoll() {
    let (service, _, _) = makeService(activeID: Fixture.currentID64)
    XCTAssertFalse(service.isFastPollArmedForTesting, "not armed before any switch")

    service.switchTo(key: Fixture.targetKey) { _ in }

    XCTAssertTrue(service.isFastPollArmedForTesting, "switchTo should arm the fast poll")
  }

  func testExternalSwitchKeySeenArmsFastPoll() {
    let (service, _, _) = makeService(activeID: Fixture.currentID64)

    service.noteExternalSwitchKeySeen()

    XCTAssertTrue(service.isFastPollArmedForTesting)
  }

  func testFastPollExpiresAfterWindow() {
    let pollScheduler = DeferredScheduler()
    let (service, _, _) = makeService(
      activeID: Fixture.currentID64, fastPollScheduler: pollScheduler)

    service.noteExternalSwitchKeySeen()
    XCTAssertTrue(service.isFastPollArmedForTesting)

    pollScheduler.fire()

    XCTAssertFalse(
      service.isFastPollArmedForTesting, "should self-invalidate once the window elapses")
  }

  /// Guards the generation-counter logic in `armFastPoll()`: a second trigger arriving before the
  /// first window elapses must extend the poll, not let the first (now-stale) expiry cut it short
  /// when it fires late.
  func testReArmingBeforeExpirySupersedesEarlierWindow() {
    let pollScheduler = DeferredScheduler()
    let (service, _, _) = makeService(
      activeID: Fixture.currentID64, fastPollScheduler: pollScheduler)

    service.noteExternalSwitchKeySeen()
    let staleExpiry = pollScheduler.pending  // captured before the second arm overwrites it

    service.noteExternalSwitchKeySeen()  // re-armed before the first window elapsed
    staleExpiry?()  // the superseded expiry firing late must be a no-op

    XCTAssertTrue(
      service.isFastPollArmedForTesting, "a superseded expiry must not cut the poll short")

    pollScheduler.fire()  // the latest scheduled expiry

    XCTAssertFalse(service.isFastPollArmedForTesting)
  }

  func testStopDisarmsFastPoll() {
    let (service, _, _) = makeService(activeID: Fixture.currentID64)
    service.noteExternalSwitchKeySeen()
    XCTAssertTrue(service.isFastPollArmedForTesting)

    service.stop()

    XCTAssertFalse(service.isFastPollArmedForTesting)
  }

  // MARK: Cross-display (issue #23)

  /// The active Space living on a different display than the requested target must never be
  /// walked or jumped to — `.crossDisplayUnsupported` short-circuits before either key-synthesis
  /// path runs.
  func testCrossDisplayTargetReportsUnsupportedWithoutSynthesizingAnyKeys() {
    let keySynth = FakeKeySynth()
    let (service, _, _) = makeService(
      activeID: Fixture.currentID64, keySynth: keySynth, rawDisplays: Fixture.crossDisplay())

    var result: SpaceService.SwitchResult?
    service.switchTo(key: Fixture.targetKey) { result = $0 }

    XCTAssertEqual(result, .crossDisplayUnsupported)
    XCTAssertEqual(keySynth.stepCallCount, 0)
    XCTAssertEqual(keySynth.switchToDesktopCallCount, 0)
  }
}

/// Issue #23: `SpaceService.switchTo`'s direct ⌃N one-hop jump used to be gated on
/// `displays.count == 1`, disabling it entirely the moment any second display was attached — even
/// for a switch that stays on the same display as the active Space. It must instead depend only
/// on the target actually sharing a display with the active Space (already proven once
/// `crossDisplayUnsupported` hasn't fired) and on the injected `desktopShortcutsSatisfied` — never
/// on how many displays are attached in total.
@MainActor
final class SpaceServiceDirectJumpGateTests: XCTestCase {

  private enum Fixture {
    static let currentID64: UInt64 = 201
    static let targetID64: UInt64 = 202

    /// Two displays; `current` and `target` both live on `displayA` — a same-display switch with
    /// an unrelated second display attached.
    static func twoDisplaysSameDisplaySwitch() -> [RawDisplay] {
      let current = RawSpace(
        managedID: 1, id64: Int(currentID64), uuid: "current-uuid", isFullscreen: false)
      let target = RawSpace(
        managedID: 2, id64: Int(targetID64), uuid: "target-uuid", isFullscreen: false)
      let displayA = RawDisplay(displayID: "A", currentManagedID: 1, spaces: [current, target])

      let other = RawSpace(managedID: 10, id64: 999, uuid: "other-uuid", isFullscreen: false)
      let displayB = RawDisplay(displayID: "B", currentManagedID: 10, spaces: [other])
      return [displayA, displayB]
    }

    static var targetKey: String { SpaceIdentity(uuid: "target-uuid", id64: 202).key }
  }

  private func makeService(
    keySynth: FakeKeySynth, desktopShortcutsSatisfied: @escaping (Int) -> Bool
  ) -> (service: SpaceService, scheduler: DeferredScheduler) {
    let api = FakeSpacesReading(
      displays: Fixture.twoDisplaysSameDisplaySwitch(), activeID: Fixture.currentID64)
    let scheduler = DeferredScheduler()
    let service = SpaceService(
      api: api, store: SpaceStore(fileURL: nil), keySynth: keySynth,
      verificationDelay: 0.25, scheduleAfterDelay: scheduler.schedule,
      scheduleFastPollExpiry: scheduler.schedule,
      desktopShortcutsSatisfied: desktopShortcutsSatisfied)
    service.refresh()
    addTeardownBlock { service.stop() }
    return (service, scheduler)
  }

  /// The case issue #23 is actually about: two displays attached, but the switch stays within the
  /// display the active Space is already on, and the ⌃N shortcuts are bound — the direct one-hop
  /// jump must be used rather than falling back to the ⌃←/⌃→ walk just because a second display
  /// exists.
  func testSameDisplaySwitchTakesDirectJumpEvenWithASecondDisplayAttached() {
    let keySynth = FakeKeySynth()
    let (service, _) = makeService(keySynth: keySynth, desktopShortcutsSatisfied: { _ in true })

    service.switchTo(key: Fixture.targetKey) { _ in }

    XCTAssertEqual(
      keySynth.switchToDesktopCallCount, 1, "expected the one-hop ⌃N jump, not a walk")
    XCTAssertEqual(keySynth.stepCallCount, 0)
  }

  /// Same same-display shape, but the ⌃N shortcuts aren't actually bound — must fall back to the
  /// ⌃←/⌃→ walk rather than synthesizing a shortcut that isn't there.
  func testSameDisplaySwitchFallsBackToWalkWhenShortcutsUnsatisfied() {
    let keySynth = FakeKeySynth()
    let (service, _) = makeService(keySynth: keySynth, desktopShortcutsSatisfied: { _ in false })

    service.switchTo(key: Fixture.targetKey) { _ in }

    XCTAssertEqual(keySynth.switchToDesktopCallCount, 0)
    XCTAssertGreaterThan(keySynth.stepCallCount, 0, "expected the ⌃←/⌃→ walk")
  }
}
