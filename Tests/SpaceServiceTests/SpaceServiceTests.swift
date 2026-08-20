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

  /// Two displays so `SpaceService.switchTo` always takes the `execute` (walk) path: the direct
  /// ⌃N jump path additionally gates on `DesktopShortcuts.allEnabled`, which reads this machine's
  /// *real* `com.apple.symbolichotkeys` — a live-system dependency these tests must not touch.
  /// `displays.count == 1` short-circuits that check before it's ever evaluated.
  private enum Fixture {
    static let currentID64: UInt64 = 101
    static let targetID64: UInt64 = 102

    static func twoDisplays() -> [RawDisplay] {
      let current = RawSpace(
        managedID: 1, id64: Int(currentID64), uuid: "current-uuid", isFullscreen: false)
      let target = RawSpace(
        managedID: 2, id64: Int(targetID64), uuid: "target-uuid", isFullscreen: false)
      let displayA = RawDisplay(displayID: "A", currentManagedID: 1, spaces: [current, target])

      // A second display, otherwise irrelevant, purely to make `displays.count == 1` false.
      let other = RawSpace(managedID: 10, id64: 999, uuid: "other-uuid", isFullscreen: false)
      let displayB = RawDisplay(displayID: "B", currentManagedID: 10, spaces: [other])
      return [displayA, displayB]
    }

    static var currentKey: String { SpaceIdentity(uuid: "current-uuid", id64: 101).key }
    static var targetKey: String { SpaceIdentity(uuid: "target-uuid", id64: 102).key }
  }

  private func makeService(
    activeID: UInt64?, keySynth: FakeKeySynth = FakeKeySynth(),
    fastPollScheduler: DeferredScheduler = DeferredScheduler()
  ) -> (service: SpaceService, api: FakeSpacesReading, scheduler: DeferredScheduler) {
    let api = FakeSpacesReading(displays: Fixture.twoDisplays(), activeID: activeID)
    let scheduler = DeferredScheduler()
    let service = SpaceService(
      api: api, store: SpaceStore(fileURL: nil), keySynth: keySynth,
      verificationDelay: 0.25, scheduleAfterDelay: scheduler.schedule,
      scheduleFastPollExpiry: fastPollScheduler.schedule)
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
}
