// KeySynthTest — does a properly-sequenced NATIVE CGEvent switch Spaces?
//
// The earlier spike's one-shot CGEvent (arrow with .maskControl, no separate modifier event)
// leaked into the terminal instead of switching. Hypothesis: the WindowServer's hotkey handler
// needs the Control modifier posted as its OWN key event first (a real flagsChanged), exactly like
// System Events does. If that's the difference, we can switch natively and skip osascript.
//
// Ground truth without watching: a keyboard-driven switch is real-or-nothing (never a phantom like
// CGSManagedDisplaySetCurrentSpace), so comparing the active Space UUID before/after is decisive.
//
// Run from a terminal that has Accessibility permission: swift run KeySynthTest

import AppKit
import Foundation

typealias MainConnFn   = @convention(c) () -> Int32
typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

func loadSym<T>(_ name: String, as type: T.Type) -> T? {
    let handles: [UnsafeMutableRawPointer?] = [
        UnsafeMutableRawPointer(bitPattern: -2),
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
    ]
    for h in handles { if let h, let s = dlsym(h, name) { return unsafeBitCast(s, to: T.self) } }
    return nil
}

let mainConn = loadSym("CGSMainConnectionID", as: MainConnFn.self)!
let copySpaces = loadSym("CGSCopyManagedDisplaySpaces", as: CopySpacesFn.self)!
let cid = mainConn()

func currentUUID() -> String {
    guard let ds = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]],
          let cur = ds.first?["Current Space"] as? [String: Any],
          let u = cur["uuid"] as? String else { return "?" }
    return u
}

let kControl: CGKeyCode = 0x3B
let kRight: CGKeyCode = 0x7C
let kLeft: CGKeyCode = 0x7B

/// Post Ctrl+<arrow> with the modifier as its own key event, mirroring System Events.
func ctrlArrow(_ arrow: CGKeyCode, tap: CGEventTapLocation) {
    let src = CGEventSource(stateID: .combinedSessionState)
    func post(_ vk: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down)
        e?.flags = flags
        e?.post(tap: tap)
    }
    post(kControl, true, .maskControl)   // modifier down (flagsChanged)
    post(arrow, true, .maskControl)      // arrow down, control held
    post(arrow, false, .maskControl)     // arrow up
    post(kControl, false, [])            // modifier up
}

print("=== KeySynthTest: native CGEvent space switch ===")
print("AXIsProcessTrusted = \(AXIsProcessTrusted())\n")

@MainActor
func trial(_ label: String, tap: CGEventTapLocation, done: @MainActor @escaping (Bool) -> Void) {
    let before = currentUUID()
    print("[\(label)] before=\(before) — posting Ctrl+→ …")
    ctrlArrow(kRight, tap: tap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        let after = currentUUID()
        let ok = after != before && after != "?"
        print("[\(label)] after =\(after)  →  \(ok ? "✅ SWITCHED" : "❌ no change")")
        if ok { ctrlArrow(kLeft, tap: tap) } // restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { done(ok) }
    }
}

// Try the session tap first (where symbolic hotkeys are evaluated), then the HID tap.
trial("session-tap", tap: .cgSessionEventTap) { ok1 in
    if ok1 {
        print("\n✅ NATIVE CGEvent works via .cgSessionEventTap — no osascript needed.")
        exit(0)
    }
    trial("hid-tap", tap: .cghidEventTap) { ok2 in
        if ok2 {
            print("\n✅ NATIVE CGEvent works via .cghidEventTap.")
        } else {
            print("\n⚠️  Native CGEvent did not switch on either tap — fall back to osascript/System Events.")
        }
        exit(ok2 ? 0 : 1)
    }
}

RunLoop.main.run()
