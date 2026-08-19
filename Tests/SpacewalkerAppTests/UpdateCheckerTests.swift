import XCTest

@testable import SpacewalkerApp

/// Issue #32. Covers the two halves separately: `parseRelease` (pure JSON decode) for
/// malformed/missing-field responses, and a `URLProtocol`-mocked `UpdateChecker` for the
/// end-to-end "should this fire" behavior -- including the 24h throttle that keeps this from
/// undoing issue #19's idle work.
final class UpdateCheckerTests: XCTestCase {

  // MARK: parseRelease

  func testParseReleaseExtractsTagAndURL() {
    let json = Data(
      """
      {"tag_name": "v0.2.0", "html_url": "https://github.com/blsmth/spacewalker/releases/tag/v0.2.0"}
      """.utf8)
    let info = UpdateChecker.parseRelease(json)
    XCTAssertEqual(info?.version, "v0.2.0")
    XCTAssertEqual(
      info?.releaseURL, URL(string: "https://github.com/blsmth/spacewalker/releases/tag/v0.2.0"))
  }

  func testParseReleaseHandlesMissingFields() {
    XCTAssertNil(UpdateChecker.parseRelease(Data("{}".utf8)))
    XCTAssertNil(UpdateChecker.parseRelease(Data(#"{"tag_name": "v1.0.0"}"#.utf8)))
  }

  func testParseReleaseHandlesGarbageWithoutCrashing() {
    XCTAssertNil(UpdateChecker.parseRelease(Data("not json at all".utf8)))
    XCTAssertNil(UpdateChecker.parseRelease(Data()))
    XCTAssertNil(UpdateChecker.parseRelease(Data("null".utf8)))
  }

  // MARK: End-to-end (mocked network)

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    return UserDefaults(suiteName: suiteName)!
  }

  @MainActor
  func testNewerReleaseFiresOnUpdateFound() async {
    MockURLProtocol.stub = .json(#"{"tag_name": "v0.2.0", "html_url": "https://example.com/r"}"#)
    let checker = UpdateChecker(
      currentVersion: "0.1.0", session: makeSession(), defaults: makeDefaults())

    let expectation = expectation(description: "onUpdateFound")
    checker.onUpdateFound = { info in
      XCTAssertEqual(info.version, "v0.2.0")
      expectation.fulfill()
    }

    checker.checkNow()
    await fulfillment(of: [expectation], timeout: 2)
    XCTAssertEqual(checker.available?.version, "v0.2.0")
  }

  @MainActor
  func testSameOrOlderReleaseDoesNotFire() async {
    MockURLProtocol.stub = .json(#"{"tag_name": "v0.1.0", "html_url": "https://example.com/r"}"#)
    let checker = UpdateChecker(
      currentVersion: "0.1.0", session: makeSession(), defaults: makeDefaults())
    checker.onUpdateFound = { _ in XCTFail("should not fire for a non-newer release") }

    checker.checkNow()
    // No completion signal to await on the "nothing happens" path -- give the mocked, synchronous
    // URLProtocol a moment to round-trip, then assert the observable state never changed.
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertNil(checker.available)
  }

  @MainActor
  func testNetworkErrorFailsSilently() async {
    MockURLProtocol.stub = .error(URLError(.notConnectedToInternet))
    let checker = UpdateChecker(
      currentVersion: "0.1.0", session: makeSession(), defaults: makeDefaults())
    checker.onUpdateFound = { _ in XCTFail("must not fire on a network error") }

    checker.checkNow()
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertNil(checker.available)
  }

  @MainActor
  func testMalformedResponseFailsSilently() async {
    MockURLProtocol.stub = .json("not json")
    let checker = UpdateChecker(
      currentVersion: "0.1.0", session: makeSession(), defaults: makeDefaults())
    checker.onUpdateFound = { _ in XCTFail("must not fire on a malformed response") }

    checker.checkNow()
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertNil(checker.available)
  }

  @MainActor
  func testCheckIfDueSkipsWithinTwentyFourHours() {
    MockURLProtocol.stub = .json(#"{"tag_name": "v0.2.0", "html_url": "https://example.com/r"}"#)
    let defaults = makeDefaults()
    let checker = UpdateChecker(currentVersion: "0.1.0", session: makeSession(), defaults: defaults)
    checker.onUpdateFound = { _ in XCTFail("must not check again inside the 24h window") }

    defaults.set(Date(), forKey: "UpdateCheckLastCheckDate")
    checker.checkIfDue()

    XCTAssertNil(checker.available, "a due-but-throttled check must not have run at all")
  }

  @MainActor
  func testCheckIfDueRunsAfterTwentyFourHours() async {
    MockURLProtocol.stub = .json(#"{"tag_name": "v0.2.0", "html_url": "https://example.com/r"}"#)
    let defaults = makeDefaults()
    let checker = UpdateChecker(currentVersion: "0.1.0", session: makeSession(), defaults: defaults)

    let expectation = expectation(description: "onUpdateFound")
    checker.onUpdateFound = { _ in expectation.fulfill() }

    defaults.set(Date().addingTimeInterval(-25 * 60 * 60), forKey: "UpdateCheckLastCheckDate")
    checker.checkIfDue()

    await fulfillment(of: [expectation], timeout: 2)
  }

  @MainActor
  func testCheckNowIgnoresThrottle() async {
    MockURLProtocol.stub = .json(#"{"tag_name": "v0.2.0", "html_url": "https://example.com/r"}"#)
    let defaults = makeDefaults()
    let checker = UpdateChecker(currentVersion: "0.1.0", session: makeSession(), defaults: defaults)

    let expectation = expectation(description: "onUpdateFound")
    checker.onUpdateFound = { _ in expectation.fulfill() }

    defaults.set(Date(), forKey: "UpdateCheckLastCheckDate")  // just checked a moment ago
    checker.checkNow()  // manual check must run anyway

    await fulfillment(of: [expectation], timeout: 2)
  }
}

/// Intercepts every request made through a session configured with it, so tests never touch the
/// real network. `stub` is process-global but each test builds its own `URLSession`/`UserDefaults`
/// suite and awaits its own expectation before the next test's stub is installed, so tests don't
/// interleave.
private final class MockURLProtocol: URLProtocol {

  enum Stub {
    case json(String)
    case error(Error)
  }

  nonisolated(unsafe) static var stub: Stub = .json("{}")

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    switch Self.stub {
    case .json(let body):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    case .error(let error):
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
