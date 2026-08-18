import XCTest

@testable import SpaceSwitching

/// Covers the "completion fires exactly once" invariant required by issue #20: bounding a
/// subprocess wait with a timeout introduces a real race between the process's
/// `terminationHandler` firing and the deadline elapsing. `SingleResolution` is the seam that
/// isolates that race from `Process`/`DispatchQueue`/wall-clock time, so it can be driven directly
/// here with synthetic "resolve" calls instead of spawning a real subprocess or sleeping for a
/// real timeout.
final class SingleResolutionTests: XCTestCase {

  func testDeliversResultToCompletion() {
    let expectation = expectation(description: "completion called")
    let resolution = SingleResolution<Bool> { result in
      XCTAssertTrue(result)
      expectation.fulfill()
    }
    resolution.resolve(true)
    wait(for: [expectation], timeout: 1)
  }

  func testSecondResolveIsDiscarded() {
    var callCount = 0
    let resolution = SingleResolution<Bool> { _ in callCount += 1 }

    resolution.resolve(true)
    resolution.resolve(false)
    resolution.resolve(true)

    XCTAssertEqual(callCount, 1, "completion must fire exactly once, not on every resolve() call")
  }

  /// The scenario issue #20 actually describes: a subprocess exit and a timeout deadline racing
  /// to resolve the same outcome. Whichever wins, the loser must be silently discarded — the
  /// completion must never fire twice and must never fail to fire.
  func testTerminationAndTimeoutRaceResolvesExactlyOnce() {
    let expectation = expectation(description: "completion called exactly once")
    expectation.assertForOverFulfill = true
    var receivedResults: [Bool] = []
    let lock = NSLock()

    let resolution = SingleResolution<Bool> { result in
      lock.lock()
      receivedResults.append(result)
      lock.unlock()
      expectation.fulfill()
    }

    // Simulate "process exited successfully" and "timed out" firing concurrently from two
    // different queues, exactly as `terminationHandler` and the timeout's `asyncAfter` block
    // would in the real bounded-wait path.
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      resolution.resolve(true)
      group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
      resolution.resolve(false)
      group.leave()
    }
    group.wait()

    wait(for: [expectation], timeout: 1)
    XCTAssertEqual(receivedResults.count, 1, "exactly one of the two racing results must win")
  }

  /// Stress the same race across many iterations and many concurrent callers, since a single run
  /// racing two threads may not reliably exercise the lock if the two dispatches happen to be
  /// serialized by scheduling luck.
  func testManyConcurrentResolveCallsFireExactlyOnce() {
    for _ in 0..<200 {
      var callCount = 0
      let lock = NSLock()
      let resolution = SingleResolution<Int> { _ in
        lock.lock()
        callCount += 1
        lock.unlock()
      }

      let group = DispatchGroup()
      for i in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
          resolution.resolve(i)
          group.leave()
        }
      }
      group.wait()

      lock.lock()
      let finalCount = callCount
      lock.unlock()
      XCTAssertEqual(finalCount, 1, "completion fired \(finalCount) times instead of exactly once")
    }
  }
}
