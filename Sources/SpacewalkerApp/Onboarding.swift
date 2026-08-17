import AppKit
import SpaceSwitching

/// First-run onboarding for the two ways Spacewalker can launch into a silently broken state:
/// missing Accessibility trust (switching + HUD-blanking both depend on it) and a ⌘0 hotkey that
/// another app already owns. Extracted out of `AppDelegate` (already a refactor target, #31)
/// rather than growing it further -- this owns its own small slice of sticky state and nothing
/// above it needs to know how either check works.
///
/// Sequencing: `AppDelegate` calls `presentAccessibilityOnboardingIfNeeded()` before
/// `maybeRequestSystemPrefsConsent()`, so the two dialogs never compete for the screen at first
/// launch. Permissions come first deliberately -- Spacewalker cannot switch Spaces at all without
/// Accessibility, whereas the system-preference tweaks `SystemPrefsCoordinator` offers are purely
/// an optimization (⌃1…⌃9 direct jumps). Both are `NSAlert.runModal()`-based like every other
/// dialog in this app, which is what makes the ordering safe: each call is synchronous and returns
/// before the next one runs, so there's no way for both to be on screen at once.
@MainActor
final class Onboarding {

  /// Sticky: once the user has been shown the first-run Accessibility alert (whichever button
  /// they pressed), never show it again automatically. Mirrors
  /// `SystemPrefsCoordinator.Consent`'s pattern of a single sticky UserDefaults flag with no UI
  /// path back to "unasked" -- there's no scenario here where re-asking on every launch is more
  /// helpful than the background watcher (`startWatchingForGrant`) already self-healing.
  private static let accessibilityShownKey = "OnboardingAccessibilityShown"
  /// Sticky for the same reason: if ⌘0 is taken, it's very likely still taken next launch, and
  /// repeating the alert every time is exactly the nagging the issue calls out.
  private static let hotKeyUnavailableShownKey = "OnboardingHotKeyUnavailableShown"

  private static var hasShownAccessibilityPrompt: Bool {
    get { UserDefaults.standard.bool(forKey: accessibilityShownKey) }
    set { UserDefaults.standard.set(newValue, forKey: accessibilityShownKey) }
  }

  private static var hasShownHotKeyUnavailable: Bool {
    get { UserDefaults.standard.bool(forKey: hotKeyUnavailableShownKey) }
    set { UserDefaults.standard.set(newValue, forKey: hotKeyUnavailableShownKey) }
  }

  /// Re-attempts `SwitchKeyTap` installation and reports whether it's installed afterward.
  /// Injected so this type never has to know `AppDelegate`'s storage -- mirrors how
  /// `retryInstallIfNeeded()` itself is a thin re-run of `SwitchKeyTap`'s existing private
  /// `install()`, not new tap-creation logic.
  private let retryTapInstall: () -> Bool
  /// Relaunches the app; delegates to `AppDelegate.relaunch()` so there's exactly one
  /// `NSWorkspace.openApplication` call site in the app.
  private let relaunch: () -> Void

  private var pollTimer: Timer?
  /// Guards against announcing the grant twice: `AXIsProcessTrusted()` can briefly flap right
  /// after the user flips the Settings checkbox, and the poll fires on a plain repeating timer
  /// with no debounce.
  private var announcedGrant = false

  init(retryTapInstall: @escaping () -> Bool, relaunch: @escaping () -> Void) {
    self.retryTapInstall = retryTapInstall
    self.relaunch = relaunch
  }

  // MARK: Accessibility

  /// Call once at launch. Shows nothing and costs nothing beyond one `AXIsProcessTrusted()` call
  /// for a user who already granted trust (the common case for anyone who isn't on their very
  /// first launch).
  func presentAccessibilityOnboardingIfNeeded() {
    guard !AXIsProcessTrusted() else { return }

    // Runs regardless of whether we're about to show the first-run alert below, so "denied, then
    // granted later from Settings on their own initiative" self-heals without requiring the user
    // to relaunch or find their way back to any Spacewalker UI at all.
    startWatchingForGrant()

    guard !Self.hasShownAccessibilityPrompt else { return }  // already asked once; don't nag
    Self.hasShownAccessibilityPrompt = true
    presentFirstRunAccessibilityAlert()
  }

  private func presentFirstRunAccessibilityAlert() {
    let alert = NSAlert()
    alert.messageText = "Spacewalker needs Accessibility permission"
    alert.informativeText = """
      Spacewalker switches Spaces by sending keystrokes through System Events, and watches for \
      your own Space-switch shortcuts to keep its HUD in sync. Both require Accessibility \
      permission.

      Turn Spacewalker ON in System Settings ▸ Privacy & Security ▸ Accessibility. Spacewalker \
      picks up the change automatically in the background -- no need to relaunch.
      """
    alert.addButton(withTitle: "Open Accessibility Settings")
    alert.addButton(withTitle: "Not Now")
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()

    // Harmless to call even after "Not Now": this only ever shows the system's own prompt, it
    // never grants anything, so it's a no-op once trust already exists and otherwise gives the
    // user the real system dialog (with its own "Open System Settings" button) in addition to our
    // deep link below.
    _ = KeySynth.requestAccessibility()
    if response == .alertFirstButtonReturn {
      let paneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      NSWorkspace.shared.open(URL(string: paneURL)!)
    }
  }

  /// Polls for the grant independently of the alert above, so a user who dismissed it (or never
  /// saw it, because this is a launch after the sticky flag was already set) still self-heals.
  /// 2s is frequent enough that the follow-up alert feels immediate after flipping the Settings
  /// checkbox, without polling so tightly it shows up in a energy-impact complaint for a check
  /// this cheap (`AXIsProcessTrusted()` is a lightweight cached lookup, not an XPC round trip).
  private func startWatchingForGrant() {
    guard pollTimer == nil else { return }
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollOnce() }
    }
    // .common: keeps firing while a modal alert (this one, the system-prefs consent sheet, or any
    // other) has the run loop parked in `.modalPanel`/`.eventTracking` mode -- otherwise granting
    // trust while some other Spacewalker dialog is on screen would never be observed until that
    // dialog closes on its own.
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  private func pollOnce() {
    guard AXIsProcessTrusted() else { return }
    pollTimer?.invalidate()
    pollTimer = nil
    guard !announcedGrant else { return }
    announcedGrant = true

    let tapReady = retryTapInstall()
    presentGrantedAlert(tapAlreadyWorking: tapReady)
  }

  private func presentGrantedAlert(tapAlreadyWorking: Bool) {
    let alert = NSAlert()
    alert.messageText = "Accessibility permission granted"
    alert.informativeText =
      tapAlreadyWorking
      ? "Spacewalker is ready to switch Spaces."
      : "Spacewalker saw the change but couldn't finish setting up right away. Relaunching "
        + "will make sure everything is working."
    alert.addButton(withTitle: tapAlreadyWorking ? "Great" : "Relaunch Spacewalker")
    alert.addButton(withTitle: tapAlreadyWorking ? "Relaunch Anyway" : "Not Now")
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()

    let shouldRelaunch =
      tapAlreadyWorking ? response == .alertSecondButtonReturn : response == .alertFirstButtonReturn
    if shouldRelaunch {
      relaunch()
    }
  }

  // MARK: HotKey conflict

  /// `HotKey.init` is failable and returns nil if `RegisterEventHotKey` fails -- almost always
  /// because another app already owns ⌘0. Call this right after a failed `HotKey(...)` so the
  /// user learns why the headline shortcut silently does nothing, instead of assuming Spacewalker
  /// is broken. Sticky like the Accessibility prompt: the condition is unlikely to change between
  /// launches, and re-showing it every time would be exactly the nagging the issue calls out.
  func presentHotKeyUnavailableIfNeeded() {
    guard !Self.hasShownHotKeyUnavailable else { return }
    Self.hasShownHotKeyUnavailable = true

    let alert = NSAlert()
    alert.messageText = "⌘0 is unavailable"
    alert.informativeText = """
      Another app already uses ⌘0, so Spacewalker's global Quick Switcher shortcut isn't active.

      You can still open the Quick Switcher from the menu bar icon's menu, or free up ⌘0 in the \
      other app and relaunch Spacewalker.
      """
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
