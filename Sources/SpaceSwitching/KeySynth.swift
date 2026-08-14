import AppKit
import Carbon.HIToolbox

/// Abstraction over key synthesis so `SpaceService` can be driven and tested without touching real
/// AppleScript/System Events. `KeySynth` is the only production conformer — tests substitute a
/// fake via `SpaceService`'s test-only initializer (see `Tests/SpaceServiceTests`).
@MainActor
public protocol KeySynthesizing: AnyObject {
  func step(_ direction: SwitchDirection) -> Result<Void, KeySynth.SynthError>
  func switchToDesktop(_ n: Int) -> Result<Void, KeySynth.SynthError>
}

/// Synthesizes the move-space keystrokes through **System Events** — the only synthetic path macOS
/// honors for Space switching (native `CGEvent` is filtered; proven in the spike).
///
/// Scripts are compiled once and reused, so each switch is a fast `executeAndReturnError`. Requires
/// Accessibility + Automation ("control System Events") permissions.
@MainActor
public final class KeySynth: KeySynthesizing {

  public enum SynthError: Error {
    case compileFailed
    /// Script executed but returned an error. `code` is the AppleScript error number
    /// (e.g. -1743 = not authorized to send Apple Events / Automation denied).
    case failed(message: String, code: Int)
  }

  private let leftScript: NSAppleScript
  private let rightScript: NSAppleScript
  /// Compiled ⌃N scripts, cached lazily per desktop number.
  private var desktopScripts: [Int: NSAppleScript] = [:]

  public init() {
    // key code 123 = Left arrow, 124 = Right arrow; Ctrl+arrow = "Move left/right a space".
    leftScript = NSAppleScript(
      source: #"tell application "System Events" to key code 123 using control down"#)!
    rightScript = NSAppleScript(
      source: #"tell application "System Events" to key code 124 using control down"#)!
    leftScript.compileAndReturnError(nil)
    rightScript.compileAndReturnError(nil)
  }

  @discardableResult
  public func step(_ direction: SwitchDirection) -> Result<Void, SynthError> {
    run(direction == .left ? leftScript : rightScript)
  }

  /// Direct one-hop jump to desktop N via ⌃N. Requires the "Switch to Desktop N" shortcut to be
  /// enabled (see `DesktopShortcuts`).
  @discardableResult
  public func switchToDesktop(_ n: Int) -> Result<Void, SynthError> {
    guard let keycode = DesktopShortcuts.keycode(desktop: n) else {
      return .failure(.failed(message: "desktop \(n) has no ⌃N shortcut", code: 0))
    }
    let script =
      desktopScripts[n]
      ?? {
        let s = NSAppleScript(
          source: "tell application \"System Events\" to key code \(keycode) using control down")!
        s.compileAndReturnError(nil)
        desktopScripts[n] = s
        return s
      }()
    return run(script)
  }

  private func run(_ script: NSAppleScript) -> Result<Void, SynthError> {
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    if let errorInfo {
      let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
      let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
      return .failure(.failed(message: message, code: code))
    }
    return .success(())
  }

  /// True once the process holds Accessibility trust (required for System Events to post keys).
  public static var hasAccessibility: Bool { AXIsProcessTrusted() }

  /// Prompt for Accessibility if not yet granted (shows the system dialog + deep-links Settings).
  @discardableResult
  public static func requestAccessibility() -> Bool {
    // kAXTrustedCheckOptionPrompt is an imported mutable global (not concurrency-safe to touch);
    // its documented CFString value is "AXTrustedCheckOptionPrompt".
    return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }
}
