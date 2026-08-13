import AppKit
import Carbon.HIToolbox
import SpaceModel
import SpaceService
import SpaceSwitching

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

  private var statusItem: NSStatusItem!
  private let service = SpaceService(store: SpaceStore(fileURL: SpaceStore.defaultFileURL()))
  private lazy var quickSwitcher = QuickSwitcherController(service: service)
  private var hotKey: HotKey?
  private let switchHUD = SwitchHUD()
  private let mcProbe = MissionControlProbe()
  private lazy var mcOverlay = MissionControlOverlay(spaces: { [weak self] in
    self?.service.allSpaces ?? []
  })
  private var dumpHotKey: HotKey?
  private var switchKeyMonitor: Any?
  /// Destination of an in-flight app-initiated switch (suppresses lagging notification flashes).
  private var expectedSpaceKey: String?
  private var expectedClear: DispatchWorkItem?

  /// Virtual key codes for macOS Space-switch shortcuts: ⌃← ⌃→ and ⌃1…⌃9.
  private static let switchKeyCodes: Set<UInt16> = [123, 124, 18, 19, 20, 21, 23, 22, 26, 28, 25]

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.imagePosition = .imageLeading

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    service.onChange = { [weak self] in self?.updateStatusTitle() }
    // App-initiated switch: flash the known destination immediately (no lag).
    service.onSwitchInitiated = { [weak self] space in
      guard let self else { return }
      self.expectedSpaceKey = space.id
      self.expectedClear?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.expectedSpaceKey = nil }
      self.expectedClear = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
      self.switchHUD.flash(space)
    }
    // External switch (trackpad / direct ⌃arrow): flash on the notification — but ignore the
    // lagging/stale notifications for a switch we already flashed on initiation.
    service.onSpaceChanged = { [weak self] space in
      guard let self else { return }
      if let expected = self.expectedSpaceKey {
        if space.id == expected {
          self.expectedSpaceKey = nil
          self.expectedClear?.cancel()
        }
        return
      }
      self.switchHUD.flash(space)
    }
    service.start()
    updateStatusTitle()

    // Paint custom Space names inside Mission Control (headline feature).
    mcOverlay.start()

    // Blank the HUD the instant a Space-switch shortcut is pressed — the true start of a switch,
    // well before CGSGetActiveSpace reports the new Space — so the old name never lingers. The
    // poll then fills in the new name. Skipped for our own app-initiated switches (which already
    // flashed their destination and set expectedSpaceKey).
    let handler: (NSEvent) -> Void = { [weak self] event in
      let keyCode = event.keyCode
      let hasControl = event.modifierFlags.contains(.control)
      MainActor.assumeIsolated {
        guard let self, hasControl, Self.switchKeyCodes.contains(keyCode),
          self.expectedSpaceKey == nil
        else { return }
        self.switchHUD.clear()
      }
    }
    switchKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)

    // ⌘0 toggles the Quick Switcher. keyCode 0x1D = "0"; cmdKey = Carbon command mask.
    hotKey = HotKey(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey)) { [weak self] in
      self?.quickSwitcher.toggle()
    }

    // ⌃⌥⌘D dumps the Dock AX tree — a global hotkey fires while Mission Control is open (a menu
    // click would dismiss MC first). Spike-only.
    dumpHotKey = HotKey(
      keyCode: UInt32(kVK_ANSI_D),
      modifiers: UInt32(cmdKey | optionKey | controlKey)
    ) { [weak self] in
      let result = self?.mcProbe.dumpDockAX() ?? ""
      self?.switchHUD.flashMessage("AX dumped")
      NSLog("Spacewalker MC AX dump: \(result)")
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    service.stop()
  }

  // MARK: Status-bar title

  private func updateStatusTitle() {
    guard let button = statusItem.button else { return }
    guard service.isAvailable else {
      button.image = nil
      button.title = "⚠︎ Spaces N/A"
      return
    }
    let current = service.current
    button.image = symbolImage(for: current)
    button.title = current?.displayName ?? "—"
  }

  /// Small icon: the Space's custom SF Symbol tinted with its color, else a neutral default.
  private func symbolImage(for space: ResolvedSpace?) -> NSImage? {
    let name = space?.metadata?.symbolName ?? "square.on.square"
    let image = NSImage(systemSymbolName: name, accessibilityDescription: "Space")
    if let hex = space?.metadata?.colorHex, let color = NSColor(hex: hex) {
      let config = NSImage.SymbolConfiguration(paletteColors: [color])
      return image?.withSymbolConfiguration(config)
    }
    return image
  }

  // MARK: Menu (rebuilt each open so it always reflects live state)

  func menuNeedsUpdate(_ menu: NSMenu) {
    service.refresh()
    menu.removeAllItems()

    let header = NSMenuItem(title: "Spacewalker", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    guard service.isAvailable else {
      let item = NSMenuItem(
        title: "Spaces API unavailable on this macOS", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      addQuit(to: menu)
      return
    }

    let displays = service.displays
    for (di, display) in displays.enumerated() {
      if displays.count > 1 {
        let label = NSMenuItem(title: "Display \(di + 1)", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
      }
      for space in display.spaces {
        let item = NSMenuItem(
          title: space.displayName,
          action: #selector(switchToSpace(_:)),
          keyEquivalent: "")
        item.target = self
        item.representedObject = Box(space.identity)
        item.state = space.isCurrent ? .on : .off
        item.image = smallSymbol(for: space)
        item.toolTip = space.isCurrent ? "Current Space" : "Click to switch to this Space"
        menu.addItem(item)
      }
    }

    menu.addItem(.separator())

    let switcher = NSMenuItem(
      title: "Quick Switcher", action: #selector(openSwitcher), keyEquivalent: "0")
    switcher.target = self
    menu.addItem(switcher)

    let jumpBack = NSMenuItem(
      title: "Jump Back", action: #selector(jumpBack), keyEquivalent: "")
    jumpBack.target = self
    jumpBack.isEnabled = service.previousSpaceKey != nil
    menu.addItem(jumpBack)

    let renameCurrent = NSMenuItem(
      title: "Rename Current Space…", action: #selector(renameCurrent), keyEquivalent: "r")
    renameCurrent.target = self
    menu.addItem(renameCurrent)

    // --- Spikes (experimental) ---
    menu.addItem(.separator())
    let spikeHeader = NSMenuItem(title: "Spikes", action: nil, keyEquivalent: "")
    spikeHeader.isEnabled = false
    menu.addItem(spikeHeader)

    let flashTest = NSMenuItem(
      title: "Test Switch Flash", action: #selector(testFlash), keyEquivalent: "")
    flashTest.target = self
    menu.addItem(flashTest)

    let dumpAX = NSMenuItem(
      title: "Dump Dock AX (while MC open)", action: #selector(dumpDockAX), keyEquivalent: "")
    dumpAX.target = self
    menu.addItem(dumpAX)

    addQuit(to: menu)
  }

  private func smallSymbol(for space: ResolvedSpace) -> NSImage? {
    guard let name = space.metadata?.symbolName else { return nil }
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    if let hex = space.metadata?.colorHex, let color = NSColor(hex: hex) {
      return image?.withSymbolConfiguration(.init(paletteColors: [color]))
    }
    return image
  }

  private func addQuit(to menu: NSMenu) {
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit Spacewalker", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
  }

  // MARK: Actions

  @objc private func renameCurrent() {
    guard let current = service.current else { return }
    promptRename(identity: current.identity, currentName: current.displayName)
  }

  @objc private func switchToSpace(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? Box<SpaceIdentity> else { return }
    service.switchTo(key: box.value.key) { [weak self] result in
      self?.handle(result)
    }
  }

  @objc private func openSwitcher() {
    quickSwitcher.show()
  }

  @objc private func jumpBack() {
    service.jumpBack { [weak self] result in self?.handle(result) }
  }

  private func handle(_ result: SpaceService.SwitchResult) {
    switch result {
    case .ok, .alreadyThere, .notFound, .busy:
      break
    case .crossDisplayUnsupported:
      NSLog("Spacewalker: cross-display switching not yet supported")
    case .notPermitted(let message, let code):
      presentPermissionHelp(message: message, code: code)
    }
  }

  /// Switching drives System Events, which needs Automation (control System Events) and, to post
  /// keys, Accessibility. The error code tells us which is missing so we can point precisely.
  private func presentPermissionHelp(message: String, code: Int) {
    let automationDenied = (code == -1743)  // errAEEventNotPermitted
    let pane: String
    let paneURL: String
    if automationDenied {
      pane = "Automation"
      paneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    } else {
      _ = KeySynth.requestAccessibility()  // surfaces the system Accessibility prompt
      pane = "Accessibility"
      paneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }

    let alert = NSAlert()
    alert.messageText = "Spacewalker needs \(pane) permission to switch Spaces"
    alert.informativeText = """
      Spacewalker switches Spaces by sending ⌃← / ⌃→ through System Events. macOS is blocking \
      that until you grant \(pane) permission.

      Turn Spacewalker ON in System Settings ▸ Privacy & Security ▸ \(pane), then relaunch.

      (error \(code): \(message))
      """
    alert.addButton(withTitle: "Open \(pane) Settings")
    alert.addButton(withTitle: "Relaunch Spacewalker")
    alert.addButton(withTitle: "Later")
    NSApp.activate(ignoringOtherApps: true)

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      NSWorkspace.shared.open(URL(string: paneURL)!)
    case .alertSecondButtonReturn:
      relaunch()
    default:
      break
    }
  }

  /// TCC grants on ad-hoc dev builds often aren't picked up until the process restarts.
  private func relaunch() {
    let url = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }
  }

  private func promptRename(identity: SpaceIdentity, currentName: String) {
    let alert = NSAlert()
    alert.messageText = "Rename Space"
    alert.informativeText = "Give this Space a name. Leave empty to reset to the default."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = currentName
    field.placeholderString = "e.g. Email, Build, Design"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      service.rename(identity, to: trimmed.isEmpty ? nil : trimmed)
      updateStatusTitle()
    }
  }

  // MARK: Spike actions

  @objc private func testFlash() {
    if let current = service.current { switchHUD.flash(current) }
  }

  @objc private func dumpDockAX() {
    let result = mcProbe.dumpDockAX()
    NSLog("Spacewalker MC AX dump: \(result)")
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}

/// Boxes a value type so it can ride in `NSMenuItem.representedObject` (which wants a class).
private final class Box<T> {
  let value: T
  init(_ value: T) { self.value = value }
}
