import AppKit
import ApplicationServices
import XCTest

@testable import SpacewalkerApp

/// Opens a real Mission Control on the machine running this test and re-verifies findings F1
/// (`MissionControlOverlayGeometry.screenFrame`'s collapsed-bar attribution) and F3
/// (`MissionControlMatching.allButtonRows`'s decoy-row rejection) against production code — not a
/// synthetic fixture, and not a reimplementation of the matching logic — from PR #63's second
/// review.
///
/// **Skipped by default.** This needs a live Dock, Mission Control able to actually open, and
/// this process holding the Accessibility TCC grant — none of which CI or a typical dev machine
/// running `swift test` unattended can assume. Opt in with
/// `SPACEWALKER_LIVE_MC_VERIFY=1 swift test --filter LiveMissionControlVerificationTests`. Every
/// assertion here failing silently-skipped is expected and correct on any machine without that
/// grant; a failure while opted in means an actual regression against a live Mission Control.
///
/// Mirrors `scripts/dump-mc-ax.swift`'s save/restore-mouse, open/close-MC discipline so running
/// this doesn't leave Mission Control open or the pointer moved.
///
/// Note on this test's own provenance: when this file was written (PR #63's second review pass),
/// `open -a "Mission Control"` reliably opened it when run as `scripts/dump-mc-ax.swift` (a
/// standalone compiled binary — see its captured tree, which every F1/F3 regression test in
/// `MissionControlOverlayGeometryTests`/`MissionControlMatchingTests`/
/// `MissionControlRowResolutionTests` uses as its live-measured ground truth). Re-attempting the
/// same open from *inside* an ad-hoc-signed `swift test` XCTest bundle in the same session did
/// not reopen Mission Control (confirmed with a longer, polled wait) — plausibly session/focus
/// state that had changed by that point, not a TCC/trust problem (`AXIsProcessTrusted()` was
/// still `true` and the Dock's own children were still readable). This test is kept as real
/// opt-in infrastructure for whenever it can run, rather than removed, but its own success on
/// this specific machine on this specific day is unconfirmed — see the PR body.
final class LiveMissionControlVerificationTests: XCTestCase {

  private func requireOptIn() throws {
    guard ProcessInfo.processInfo.environment["SPACEWALKER_LIVE_MC_VERIFY"] == "1" else {
      throw XCTSkip(
        "requires a live Dock/Mission Control + Accessibility grant — opt in with "
          + "SPACEWALKER_LIVE_MC_VERIFY=1")
    }
  }

  /// F1: a real, currently-open Mission Control's Spaces Bar row (which normally sits collapsed
  /// above the physical screen's top edge) must still resolve to a screen via
  /// `MissionControlOverlayGeometry.screenFrame(containing:among:)` — not silently dropped, which
  /// is exactly what regressed on a single-display machine before the fix.
  ///
  /// F3: whatever row(s) `MissionControlMatching.desktopRows` finds must not include an
  /// incidental cluster of digit-titled windows as a spurious extra "Spaces Bar" — every returned
  /// row's screen-resolved rect must correspond to a button whose title (when present) actually
  /// looks like a desktop label, not an arbitrary window title.
  func testRealMissionControlRowsResolveToAScreenAndExcludeDecoys() throws {
    try requireOptIn()
    let savedMouse = CGEvent(source: nil)?.location ?? .zero
    defer { CGWarpMouseCursorPosition(savedMouse) }

    guard let dockPID = AXUtil.dockPID() else {
      return XCTFail("Dock isn't running")
    }
    let dock = AXUtil.dockElement(forPID: dockPID)

    openMissionControl()
    defer { closeMissionControl() }

    guard
      let mc = AXUtil.children(dock).first(where: {
        AXUtil.string($0, kAXRoleAttribute) == kAXGroupRole
      })
    else {
      return XCTFail("Mission Control's AXGroup did not appear — cannot verify live")
    }

    let node = AXUtil.snapshot(mc, maxDepth: MissionControlMatching.RowMatching.maxTraversalDepth)
    let rows = MissionControlMatching.desktopRows(in: node)
    XCTAssertFalse(rows.isEmpty, "F1/F5 regression: no desktop button row was found at all")

    // F3: on this single-display machine there is exactly one real Spaces Bar — more than one
    // row means an incidental digit-ending window cluster elsewhere got promoted to a second,
    // bogus "Spaces Bar" (the actual F3 bug).
    XCTAssertEqual(
      rows.count, 1,
      "F3 regression: more than one row found on a single-display machine — a decoy row was "
        + "likely promoted alongside the real Spaces Bar")

    let anchorHeight =
      (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?.frame.height
      ?? 0
    let screenFrames = NSScreen.screens.map(\.frame)

    for row in rows {
      XCTAssertFalse(row.isEmpty, "a returned row must not be empty")
      for (_, axRect) in row {
        let cocoa = MissionControlOverlayGeometry.cocoaGlobalRect(
          fromAX: axRect, mainScreenHeight: anchorHeight)
        let screen = MissionControlOverlayGeometry.screenFrame(
          containing: cocoa, among: screenFrames)
        XCTAssertNotNil(
          screen, "F1 regression: a real desktop button rect failed to resolve to any screen")
      }
    }
  }

  private func openMissionControl() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Mission Control"]
    try? p.run()
    p.waitUntilExit()
    Thread.sleep(forTimeInterval: 2.0)
  }

  private func closeMissionControl() {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 1.0)
  }
}
