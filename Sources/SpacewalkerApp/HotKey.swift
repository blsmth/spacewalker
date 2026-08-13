import AppKit
import Carbon.HIToolbox

/// A single global hotkey via Carbon's `RegisterEventHotKey` (still the only way to get a
/// system-wide hotkey without an event tap). Fires `action` on the main actor.
@MainActor
final class HotKey {

  private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
  private nonisolated(unsafe) var eventHandler: EventHandlerRef?
  private let action: @MainActor () -> Void
  private let id: UInt32
  private static var nextID: UInt32 = 1

  /// `keyCode` is a virtual key code; `modifiers` are Carbon masks (e.g. `cmdKey`).
  init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
    self.action = action
    self.id = HotKey.nextID
    HotKey.nextID += 1

    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    // Every HotKey installs a handler on the shared app event target, so each handler must only
    // act on ITS hotkey id — otherwise one keypress fires all registered actions.
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData -> OSStatus in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
        var firedID = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &firedID)
        guard status == noErr, firedID.id == me.id else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated { me.action() }  // Carbon delivers on the main thread
        return noErr
      },
      1, &spec, selfPtr, &eventHandler)
    guard installStatus == noErr else { return nil }

    let hotKeyID = EventHotKeyID(signature: OSType(0x5357_4C4B /* 'SWLK' */), id: id)
    let registerStatus = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    guard registerStatus == noErr else {
      if let eventHandler { RemoveEventHandler(eventHandler) }
      return nil
    }
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let eventHandler { RemoveEventHandler(eventHandler) }
  }
}
