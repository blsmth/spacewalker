// SpaceSpike — de-risking the private-API foundation of Spacewalker.
//
// Proves, on THIS machine (Apple Silicon, macOS 15, SIP on), that we can:
//   1. Resolve the private SkyLight/CGS symbols at runtime (dlsym — no link-time guessing)
//   2. Enumerate the real Space topology with the OS's stable per-space UUIDs
//   3. Read the active Space
//   4. Subscribe to space-change notifications
//   5. Trigger an actual Space switch (synthesized Ctrl+Arrow, the SIP-on approach)
//
// Nothing here is production code — it's a viability probe. Run: swift run SpaceSpike

import AppKit
import Foundation

// MARK: - Private symbol resolution (dlsym against SkyLight, with CoreGraphics fallback)

typealias MainConnFn   = @convention(c) () -> Int32
typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64

func loadSym<T>(_ name: String, as type: T.Type) -> T? {
    // RTLD_DEFAULT-style search: try already-loaded images, then explicitly dlopen SkyLight.
    let handles: [UnsafeMutableRawPointer?] = [
        nil, // default: whatever is already loaded into the process
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
    ]
    for h in handles {
        if let sym = dlsym(h ?? UnsafeMutableRawPointer(bitPattern: -2), name) {
            return unsafeBitCast(sym, to: T.self)
        }
    }
    return nil
}

let CGSMainConnectionID = loadSym("CGSMainConnectionID", as: MainConnFn.self)
let CGSCopyManagedDisplaySpaces = loadSym("CGSCopyManagedDisplaySpaces", as: CopySpacesFn.self)
let CGSGetActiveSpace = loadSym("CGSGetActiveSpace", as: ActiveSpaceFn.self)

func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
}

print("=== Spacewalker viability spike ===\n")
print("[1] Resolving private symbols via dlsym")
check("CGSMainConnectionID", CGSMainConnectionID != nil)
check("CGSCopyManagedDisplaySpaces", CGSCopyManagedDisplaySpaces != nil)
check("CGSGetActiveSpace", CGSGetActiveSpace != nil)

guard let mainConn = CGSMainConnectionID, let copySpaces = CGSCopyManagedDisplaySpaces else {
    print("\n❌ FATAL: core symbols unavailable — the whole approach is non-viable on this OS.")
    exit(1)
}

let cid = mainConn()
print("\n  connection id = \(cid)")

// MARK: - Topology enumeration

func dumpTopology() {
    guard let arr = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
        print("  ❌ could not parse CGSCopyManagedDisplaySpaces result")
        return
    }
    for (di, display) in arr.enumerated() {
        let displayID = display["Display Identifier"] as? String ?? "?"
        let current = display["Current Space"] as? [String: Any]
        let currentUUID = current?["uuid"] as? String ?? "?"
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        print("  Display[\(di)] id=\(displayID)  currentSpaceUUID=\(currentUUID)")
        for (si, sp) in spaces.enumerated() {
            let uuid = sp["uuid"] as? String ?? "?"
            let managed = sp["ManagedSpaceID"] as? Int ?? -1
            let id64 = sp["id64"] as? Int ?? -1
            let type = sp["type"] as? Int ?? -1
            let typeLabel = type == 0 ? "user" : (type == 4 ? "fullscreen" : "type\(type)")
            let mark = uuid == currentUUID ? " ◀ ACTIVE" : ""
            print("     Space[\(si)] \(typeLabel)  uuid=\(uuid)  managed=\(managed)  id64=\(id64)\(mark)")
        }
    }
}

print("\n[2] Enumerating Space topology (stable UUIDs — our identity key)")
dumpTopology()

print("\n[3] Reading active Space id")
if let active = CGSGetActiveSpace {
    print("  ✅ CGSGetActiveSpace(cid) = \(active(cid))")
} else {
    print("  ⚠️  CGSGetActiveSpace unavailable — we can still derive active from 'Current Space'.")
}

// MARK: - Space-change notifications

print("\n[4] Subscribing to space-change notifications (NSWorkspace, public + reliable)")
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
) { _ in
    let uuid = (copySpaces(cid)?.takeRetainedValue() as? [[String: Any]])?
        .first?["Current Space"] as? [String: Any]
    print("  🔔 activeSpaceDidChange → now on uuid=\(uuid?["uuid"] as? String ?? "?")")
}
check("registered NSWorkspace.activeSpaceDidChangeNotification observer", true)

// MARK: - Trigger a real switch (synthesized Ctrl+Right — the SIP-on path)

print("\n[5] Attempting a real Space switch via synthesized Ctrl+→")
let trusted = AXIsProcessTrusted()
check("Accessibility permission (AXIsProcessTrusted) for this process", trusted)
if !trusted {
    print("     ⚠️  Grant the running terminal Accessibility access to test switching:")
    print("        System Settings ▸ Privacy & Security ▸ Accessibility")
    print("     (Detection [1–4] above is the load-bearing result; switching just needs the grant.)")
}

func synthCtrlArrow(right: Bool) {
    let key: CGKeyCode = right ? 0x7C : 0x7B // → / ←
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    let up   = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    down?.flags = .maskControl
    up?.flags = .maskControl
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func currentUUID() -> String {
    guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]],
          let current = displays.first?["Current Space"] as? [String: Any],
          let uuid = current["uuid"] as? String else { return "?" }
    return uuid
}

let before = currentUUID()
print("  before switch: currentSpaceUUID=\(before)")
synthCtrlArrow(right: true)

// Give the WindowServer a beat, then re-check and switch back.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    let after = currentUUID()
    print("  after  switch: currentSpaceUUID=\(after)")
    if after != before && after != "?" {
        print("  ✅ SWITCH CONFIRMED — active space changed. Returning to original…")
    } else {
        print("  ⚠️  No change detected (only one Space? shortcut disabled? permission missing?).")
        print("      Add a 2nd desktop in Mission Control and enable 'Move left/right a space'.")
    }
    synthCtrlArrow(right: false) // go back
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        print("\n=== Spike complete. Detection is the key result; see checks above. ===")
        exit(0)
    }
}

// Run loop so notifications + async switch checks can fire.
RunLoop.main.run()
