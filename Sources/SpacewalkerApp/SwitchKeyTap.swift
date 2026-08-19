import AppKit
import CoreGraphics

/// Watches keyDown events system-wide via a **listen-only `CGEventTap`** so Spacewalker can react
/// to the Space-switch shortcuts (⌃←/⌃→/⌃1…⌃9) the instant they're pressed.
///
/// ## Why not `NSEvent.addGlobalMonitorForEvents`
/// Verified empirically: ⌃←/⌃→/⌃N are **symbolic hotkeys** — the
/// WindowServer intercepts them off the raw HID/session event stream for Mission Control's own
/// handling *before* Cocoa's normal event-dispatch machinery ever sees them. An `NSEvent` global
/// monitor sits downstream of that interception, so it never receives these keyDowns at all —
/// confirmed live: five real, confirmed Space switches (driven the same way `KeySynth` drives
/// them, `osascript ... key code 124 using control down`), zero `keyDown` events observed by the
/// global monitor with the Control modifier set. That's exactly the bug: nothing was blanking the
/// HUD on keypress, so only the slower `CGSGetActiveSpace` poll ever updated it, producing the
/// "stale name lingers, then settles" symptom.
///
/// A `CGEventTap` installed at `.cgSessionEventTap` with `.headInsertEventTap` sits *upstream* of
/// that interception and does see the raw keyDown, before the WindowServer consumes it as a
/// symbolic hotkey. It must be `.listenOnly` — Spacewalker only ever wants to *react* to the
/// user's switch, never swallow, delay, or transform it (this app already learned the hard way,
/// per `PLAN.md` §1, not to fight the WindowServer's Space-switch handling: native `CGEvent`
/// synthesis toward it is filtered outright). Requires Accessibility trust, which Spacewalker
/// already needs for `KeySynth`, so this adds no new permission.
///
/// Caveat: this was verified against **synthetic** (System Events) keydowns, not physical hardware
/// ones, because there's no way to script a real keypress. Symbolic hotkeys are a WindowServer-level
/// interception keyed on the event stream itself (not its origin), so physical presses should be
/// intercepted identically — but that inference hasn't been confirmed on real hardware in this pass.
@MainActor
final class SwitchKeyTap {

  /// `keyCode` is the virtual key code; `timestamp` is on the same monotonic clock as
  /// `CACurrentMediaTime()` / `NSEvent.timestamp` (both derive from `mach_absolute_time`), so
  /// callers can compare it directly against `SwitchHUD.clearIfStale(asOf:)`'s expectations.
  private let onControlKeyDown: @MainActor (_ keyCode: UInt16, _ timestamp: TimeInterval) -> Void

  // `CFMachPort`/`CFRunLoopSource` aren't `Sendable`, but `CGEvent.tapEnable`/`CFMachPortInvalidate`/
  // `CFRunLoopRemoveSource` are plain thread-safe C calls — safe to reach from a nonisolated
  // `deinit`, which can't otherwise touch main-actor-isolated storage (same pattern as `HotKey`).
  private nonisolated(unsafe) var eventTap: CFMachPort?
  private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?

  init(
    onControlKeyDown: @escaping @MainActor (_ keyCode: UInt16, _ timestamp: TimeInterval) -> Void
  ) {
    self.onControlKeyDown = onControlKeyDown
    install()
  }

  /// True once the tap was actually created. `install()` failing (almost always missing
  /// Accessibility trust) leaves this object alive but inert, so callers need a way to tell
  /// "installed" from "constructed" -- see `retryInstallIfNeeded()`.
  var isInstalled: Bool { eventTap != nil }

  /// #18: re-attempts installation if it previously failed, so Spacewalker can self-heal the
  /// moment Accessibility trust is granted at runtime instead of requiring a relaunch. No-op if
  /// already installed -- `install()` isn't idempotent (it would leak a second tap/run-loop
  /// source), so this must only ever call it while `eventTap` is still nil.
  func retryInstallIfNeeded() {
    guard eventTap == nil else { return }
    install()
  }

  func invalidate() {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    runLoopSource = nil
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    eventTap = nil
  }

  deinit {
    // CFMachPortInvalidate/CFRunLoopRemoveSource are plain C calls, safe to run off the main
    // actor at teardown; `invalidate()` itself is main-actor-isolated for normal callers.
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
  }

  private func install() {
    // Only need keyDown; a listen-only tap on a narrower mask is cheaper and less likely to be
    // penalized as a slow tap by the WindowServer.
    let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: Self.callback,
        userInfo: selfPtr)
    else {
      // Most likely cause: Accessibility trust not (yet) granted. KeySynth's switching already
      // needs that permission. #18's `Onboarding` polls for the grant and calls
      // `retryInstallIfNeeded()` the moment it lands, so this self-heals without a relaunch.
      log.error("Failed to create Space-switch CGEventTap (needs Accessibility trust)")
      return
    }

    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    runLoopSource = source
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  /// The WindowServer disables a tap (without removing it) if its callback is ever slow enough to
  /// look like a hang, or on `.tapDisabledByUserInput`. `.listenOnly` taps are cheap and this
  /// callback does effectively nothing, but re-enabling defensively costs nothing and avoids a
  /// silent, permanent loss of HUD-blanking if it ever happens.
  ///
  /// Only called from `Self.callback` via `MainActor.assumeIsolated` — see the soundness note
  /// there.
  private func reenable() {
    guard let eventTap else { return }
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  private func handleKeyDown(keyCode: UInt16, hasControl: Bool, timestamp: TimeInterval) {
    guard hasControl else { return }
    onControlKeyDown(keyCode, timestamp)
  }

  private static let callback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<SwitchKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    // `MainActor.assumeIsolated` below is sound only because `install()` adds this tap's
    // `CFRunLoopSource` exclusively to `CFRunLoopGetMain()` (see `install()` above) — CFMachPort
    // callbacks run on whichever run loop the source was registered with, so registering only on
    // the main run loop guarantees this callback always fires on the main thread. If this tap
    // were ever added to any other run loop (or run in more than one place), that guarantee would
    // break and these `assumeIsolated` calls would become unsound.
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      MainActor.assumeIsolated { tap.reenable() }
    case .keyDown:
      // Pull the plain, Sendable fields out of `event` here, in the tap's own (nonisolated)
      // callback context, rather than passing the non-Sendable CGEvent itself across into the
      // main-actor closure below.
      let hasControl = event.flags.contains(.maskControl)
      let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
      // CGEventTimestamp is nanoseconds on the same mach_absolute_time-derived clock as
      // CACurrentMediaTime(); convert so callers can compare directly against it.
      let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
      MainActor.assumeIsolated {
        tap.handleKeyDown(keyCode: keyCode, hasControl: hasControl, timestamp: timestamp)
      }
    default:
      break
    }
    // Listen-only: always hand the event back unmodified.
    return Unmanaged.passUnretained(event)
  }
}
