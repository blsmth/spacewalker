import CGSPrivate
import XCTest

@testable import SpacewalkerApp

/// Covers issue #25's "Copy Diagnostics" — the redaction test here (`testRenderRedactsAbsolute...`)
/// is the most valuable test in this PR: "Copy Diagnostics" only exists so a user can paste its
/// output into a **public** GitHub issue, so proving the renderer never leaks a path (and can't
/// even structurally carry a Space name) matters more than any other behavior in this feature.
final class DiagnosticsFormatterTests: XCTestCase {

  private func makeSnapshot(
    displaySpaceCounts: [Int] = [4, 2],
    topologyShapeValid: Bool = true,
    recentLogs: LogHarvest = .entries(["10:00:00 [SpaceService] Switch result: ok"])
  ) -> DiagnosticsSnapshot {
    DiagnosticsSnapshot(
      macOSVersion: "Version 15.1 (Build 24B83)",
      appVersion: "0.1.0",
      appBuild: "1",
      architecture: "arm64",
      symbolAvailability: SkyLightSymbolAvailability(
        mainConnectionID: true, copyManagedDisplaySpaces: true, getActiveSpace: true),
      accessibilityTrusted: true,
      desktopShortcutsBound: true,
      moveSpaceShortcutsBound: true,
      displaySpaceCounts: displaySpaceCounts,
      topologyShapeValid: topologyShapeValid,
      recentLogs: recentLogs
    )
  }

  // MARK: Redaction — the one test that matters most in this PR

  /// Simulates the exact scenario the PR body calls out as the risk: a future log call site that
  /// forgets to mark a path `.private`, so a raw home-directory path reaches `OSLogStore`'s
  /// `composedMessage` unredacted. The renderer must still never let it out as an absolute path.
  func testRenderRedactsAbsoluteHomePathsFromLogEntries() {
    let snapshot = makeSnapshot(
      recentLogs: .entries([
        "10:00:00 [SpaceModel] Loaded metadata from "
          + "/Users/alice/Library/Application Support/Spacewalker/spaces.json"
      ]))

    let output = DiagnosticsFormatter.render(snapshot)

    XCTAssertFalse(output.contains("/Users/alice"), "leaked an absolute home-directory path")
    XCTAssertFalse(output.contains("/Users/"), "leaked an absolute path prefix")
    XCTAssertTrue(
      output.contains("~/Library/Application Support/Spacewalker/spaces.json"),
      "expected the path abbreviated to ~/... rather than dropped entirely")
  }

  /// A non-home absolute path (no username to abbreviate) must still never appear literally.
  func testRenderRedactsOtherAbsolutePathsFromLogEntries() {
    let snapshot = makeSnapshot(
      recentLogs: .entries([
        "10:00:01 [SpaceSwitching] Saved system prefs backup to /private/var/db/backup.plist"
      ]))

    let output = DiagnosticsFormatter.render(snapshot)

    XCTAssertFalse(output.contains("/private/var/db"), "leaked a non-home absolute path")
    XCTAssertTrue(output.contains("<path>"), "expected the path masked with a placeholder")
  }

  /// PR-A already marks paths/errors `.private` in every log call site — this proves the
  /// formatter doesn't defeat that redaction by "fixing up" or re-expanding an already-redacted
  /// `<private>` marker into something else.
  func testRenderNeverUnredactsAnAlreadyPrivateLogEntry() {
    let snapshot = makeSnapshot(
      recentLogs: .entries([
        "10:00:02 [SpaceModel] Failed to persist to <private>: <private>"
      ]))

    let output = DiagnosticsFormatter.render(snapshot)

    XCTAssertTrue(output.contains("Failed to persist to <private>: <private>"))
  }

  /// `DiagnosticsSnapshot` has no field typed to hold a Space name, custom symbol/color, window
  /// title, or username — the only way free text enters the render at all is `recentLogs`, and
  /// every real log call site in the app (see PR body) never interpolates a Space name. This
  /// mirror-based check is a tripwire: if a future refactor ever adds a String-bearing field to
  /// `DiagnosticsSnapshot` beyond the documented, reviewed ones, this test fails and forces a
  /// redaction-policy review rather than silently shipping a new leak surface.
  func testSnapshotHasNoUndocumentedStringField() {
    let allowedStringFields: Set<String> = [
      "macOSVersion", "appVersion", "appBuild", "architecture",
    ]
    let snapshot = makeSnapshot()
    let mirror = Mirror(reflecting: snapshot)

    for child in mirror.children {
      guard child.value is String, let label = child.label else { continue }
      XCTAssertTrue(
        allowedStringFields.contains(label),
        "DiagnosticsSnapshot gained an undocumented String field '\(label)' — review whether it "
          + "could carry a Space name, path, or other user data before adding it to the allowlist")
    }
  }

  // MARK: Required content

  func testRenderIncludesAllRequiredFields() {
    let output = DiagnosticsFormatter.render(makeSnapshot())

    XCTAssertTrue(output.contains("macOS: Version 15.1 (Build 24B83)"))
    XCTAssertTrue(output.contains("Spacewalker: 0.1.0 (1)"))
    XCTAssertTrue(output.contains("Architecture: arm64"))
    XCTAssertTrue(output.contains("CGSMainConnectionID: resolved"))
    XCTAssertTrue(output.contains("CGSCopyManagedDisplaySpaces: resolved"))
    XCTAssertTrue(output.contains("CGSGetActiveSpace: resolved"))
    XCTAssertTrue(output.contains("Accessibility: granted"))
    XCTAssertTrue(output.contains("Displays: 2"))
    XCTAssertTrue(output.contains("Spaces per display: 4, 2"))
    XCTAssertTrue(output.contains("Switch to Desktop 1-9 (⌃1…⌃9): bound"))
    XCTAssertTrue(output.contains("Move left/right a space (⌃←/⌃→): bound"))
    XCTAssertTrue(output.contains("Shape validation: ok"))
  }

  /// Issue #24: a topology read `TopologyValidator` rejected must be visible in the dump even when
  /// every symbol resolved — the two are independent failure modes.
  func testRenderReportsTopologyShapeValidationFailure() {
    let output = DiagnosticsFormatter.render(makeSnapshot(topologyShapeValid: false))
    XCTAssertTrue(output.contains("Shape validation: FAILED"))
  }

  func testRenderReportsMissingSymbolsAndUnboundShortcuts() {
    var snapshot = makeSnapshot()
    snapshot.symbolAvailability = SkyLightSymbolAvailability(
      mainConnectionID: false, copyManagedDisplaySpaces: true, getActiveSpace: false)
    snapshot.accessibilityTrusted = false
    snapshot.desktopShortcutsBound = false
    snapshot.moveSpaceShortcutsBound = false

    let output = DiagnosticsFormatter.render(snapshot)

    XCTAssertTrue(output.contains("CGSMainConnectionID: MISSING"))
    XCTAssertTrue(output.contains("CGSCopyManagedDisplaySpaces: resolved"))
    XCTAssertTrue(output.contains("CGSGetActiveSpace: MISSING"))
    XCTAssertTrue(output.contains("Accessibility: not granted"))
    XCTAssertTrue(output.contains("Switch to Desktop 1-9 (⌃1…⌃9): not bound"))
    XCTAssertTrue(output.contains("Move left/right a space (⌃←/⌃→): not bound"))
  }

  func testRenderHandlesUnavailableTopology() {
    let output = DiagnosticsFormatter.render(makeSnapshot(displaySpaceCounts: []))
    XCTAssertTrue(output.contains("Displays: 0"))
    XCTAssertTrue(output.contains("Spaces per display: (unavailable)"))
  }

  // MARK: Log-store fallback (verify #25's "do not ship a silently-empty section" requirement)

  func testRenderFallsBackToLogShowCommandWhenLogStoreUnavailable() {
    let output = DiagnosticsFormatter.render(
      makeSnapshot(recentLogs: .unavailable(reason: "log store access failed on this build")))

    XCTAssertTrue(output.contains("Could not read the log store"))
    XCTAssertTrue(output.contains("log show --predicate"))
    XCTAssertTrue(output.contains("app.spacewalker"))
  }

  func testRenderShowsPlaceholderWhenNoRecentEntries() {
    let output = DiagnosticsFormatter.render(makeSnapshot(recentLogs: .entries([])))
    XCTAssertTrue(output.contains("(none captured)"))
  }

  func testRenderAlwaysIncludesLiveTailingCommand() {
    let output = DiagnosticsFormatter.render(makeSnapshot())
    XCTAssertTrue(output.contains("log stream --predicate"))
  }
}

// MARK: - DiagnosticsRedactor

final class DiagnosticsRedactorTests: XCTestCase {

  func testRedactsHomeDirectoryPathToTilde() {
    let input =
      "Loaded metadata from /Users/alice/Library/Application Support/Spacewalker/spaces.json"
    let output = DiagnosticsRedactor.redactPaths(in: input)
    XCTAssertEqual(
      output,
      "Loaded metadata from ~/Library/Application Support/Spacewalker/spaces.json")
  }

  func testRedactsNonHomeAbsolutePath() {
    let input = "Saved to /private/var/db/backup.plist"
    let output = DiagnosticsRedactor.redactPaths(in: input)
    XCTAssertEqual(output, "Saved to <path>")
  }

  func testLeavesTextWithoutPathsUnchanged() {
    let input = "Switch result: ok"
    XCTAssertEqual(DiagnosticsRedactor.redactPaths(in: input), input)
  }

  func testDoesNotMangleNonPathSlashes() {
    // "and/or"-style slashes and fractions must survive untouched — only a `/` that looks like
    // the start of an absolute path (not preceded by a word character) is a candidate.
    let input = "Move left/right a space, roughly 1/2 of the time"
    XCTAssertEqual(DiagnosticsRedactor.redactPaths(in: input), input)
  }

  func testRedactsMultiplePathsInOneLine() {
    let input = "Moved /Users/bob/a.txt to /private/tmp/b.txt"
    let output = DiagnosticsRedactor.redactPaths(in: input)
    XCTAssertEqual(output, "Moved ~/a.txt to <path>")
  }
}
