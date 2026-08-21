#!/usr/bin/env swift
//
// dump-mc-ax.swift — dumps the Dock's AX tree with Mission Control open, so this app's Spaces Bar
// detection can be checked against a real, measured tree instead of a spike's notes or an
// assumption.
//
// PR #63's second review used this (in its original, ad hoc form) to catch two blockers that
// unit tests alone had missed: `MissionControlOverlay`'s screen-attribution gate silently
// dropping every real Spaces Bar row (issue F1 — the row sits collapsed *above* the physical
// screen's top edge as MC's normal resting state, which a synthetic fixture had never modeled),
// and an incidental cluster of digit-titled windows almost being promotable to a second, bogus
// "Spaces Bar" (issue F3). Landed here as a permanent, documented diagnostic rather than a
// throwaway `/tmp` script, since it converts a whole class of "unverified, reasoned from the old
// spike" claims about Mission Control's AX shape into a two-second, re-runnable measurement.
//
// Deliberately a standalone script (not a SwiftPM target or test): it needs to actually open and
// close Mission Control on the machine it runs on, which is exactly the kind of live,
// hardware/session-dependent side effect this repo's unit tests are supposed to stay free of
// (see `LiveMissionControlVerificationTests`'s doc comment for the same reasoning, applied to a
// gated XCTest instead of a script). Requires this shell/terminal to already hold the
// Accessibility TCC grant — run it directly (`swift scripts/dump-mc-ax.swift`), not through
// another tool that might have a different code identity and no grant of its own.
//
// Saves and restores the mouse position, and makes a best effort to close Mission Control again
// (Escape, with a re-open/re-close fallback if that didn't work) before exiting, so running this
// doesn't leave the pointer moved or Mission Control sitting open on a real desktop.
//
// Usage: swift scripts/dump-mc-ax.swift [--hover]
//   --hover   also capture the tree with the mouse hovering the very top edge of the main
//             screen, which expands a collapsed Spaces Bar — useful for comparing the
//             collapsed vs. expanded button geometry directly.

import AppKit
import ApplicationServices
import Foundation

private func str(_ el: AXUIElement, _ attr: String) -> String? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
  return v as? String
}

private func children(_ el: AXUIElement) -> [AXUIElement] {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success
  else { return [] }
  return (v as? [AXUIElement]) ?? []
}

private func frame(_ el: AXUIElement) -> CGRect? {
  var pv: CFTypeRef?
  var sv: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
    let p = pv, let s = sv, CFGetTypeID(p) == AXValueGetTypeID(),
    CFGetTypeID(s) == AXValueGetTypeID()
  else { return nil }
  var origin = CGPoint.zero
  var size = CGSize.zero
  let pointValue = unsafeDowncast(p, to: AXValue.self)
  let sizeValue = unsafeDowncast(s, to: AXValue.self)
  guard AXValueGetValue(pointValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &size)
  else { return nil }
  return CGRect(origin: origin, size: size)
}

private func dump(_ el: AXUIElement, depth: Int, path: String) {
  guard depth < 13 else { return }
  let role = str(el, kAXRoleAttribute) ?? "?"
  let sub = str(el, kAXSubroleAttribute) ?? ""
  let title = str(el, kAXTitleAttribute) ?? ""
  let ident = str(el, kAXIdentifierAttribute) ?? ""
  let desc = str(el, kAXDescriptionAttribute) ?? ""
  let f = frame(el)
  let kids = children(el)
  let fs =
    f.map {
      "x=\(Int($0.origin.x)) y=\(Int($0.origin.y)) w=\(Int($0.width)) h=\(Int($0.height))"
    } ?? "no-frame"
  print(
    "\(String(repeating: "  ", count: depth))[\(path)] \(role)\(sub.isEmpty ? "" : "/\(sub)") "
      + "title=\"\(title)\" desc=\"\(desc)\" id=\"\(ident)\" \(fs) kids=\(kids.count)")
  for (i, k) in kids.enumerated() {
    dump(k, depth: depth + 1, path: "\(path).\(i)")
  }
}

private func dumpDock(_ label: String) {
  print("\n########## \(label) ##########")
  guard
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
      .first?.processIdentifier
  else {
    print("no dock")
    return
  }
  let app = AXUIElementCreateApplication(pid)
  print("dock top-level children: \(children(app).count)")
  for (i, c) in children(app).enumerated() {
    dump(c, depth: 0, path: "\(i)")
  }
}

private func run(_ args: [String]) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  p.arguments = args
  try? p.run()
  p.waitUntilExit()
}

private func missionControlIsOpen() -> Bool {
  guard
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
      .first?.processIdentifier
  else { return false }
  let app = AXUIElementCreateApplication(pid)
  return children(app).contains { str($0, kAXRoleAttribute) == kAXGroupRole }
}

guard AXIsProcessTrusted() else {
  print(
    "This process/shell does not hold the Accessibility TCC grant — grant it in System Settings "
      + "> Privacy & Security > Accessibility, then re-run.")
  exit(1)
}

let hoverRequested = CommandLine.arguments.contains("--hover")

let savedMouse = CGEvent(source: nil)?.location ?? .zero
print("screens: \(NSScreen.screens.map(\.frame))")
print("saved mouse: \(savedMouse)")

dumpDock("BEFORE (MC closed)")

run(["-a", "Mission Control"])
Thread.sleep(forTimeInterval: 2.0)
dumpDock("MC OPEN (bar not hovered)")

if hoverRequested, let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
  // Hover the very top edge of the main screen to expand the Spaces Bar. CGWarp uses CG's
  // top-left-origin display coordinates, not Cocoa's — y=2 is just below the physical top edge.
  let topCenter = CGPoint(x: main.frame.midX, y: 2)
  CGWarpMouseCursorPosition(topCenter)
  CGAssociateMouseAndMouseCursorPosition(1)
  Thread.sleep(forTimeInterval: 1.5)
  dumpDock("MC OPEN (top edge hovered)")
}

CGWarpMouseCursorPosition(savedMouse)

// Close Mission Control: Escape, then re-open/re-close as a fallback if that didn't work.
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 1.5)

if missionControlIsOpen() {
  print("\nMission Control still open after Escape — retrying via re-open/re-close")
  run(["-a", "Mission Control"])
  Thread.sleep(forTimeInterval: 1.5)
}
dumpDock("AFTER (should be closed)")
print("\nMission Control still open at exit: \(missionControlIsOpen())")
print("restored mouse to \(savedMouse)")
