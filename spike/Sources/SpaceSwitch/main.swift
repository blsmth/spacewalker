// SpaceSwitch — test a keyboard-shortcut-INDEPENDENT space switch.
//
// The first spike proved detection. It also proved synthesized Ctrl+Arrow is fragile:
// the events leaked into the terminal as escape codes instead of switching Spaces, i.e.
// the WindowServer didn't claim them. This tests the direct private primitive instead:
//   CGSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID)
// which switches Spaces with no dependency on the user's keyboard-shortcut config.
//
// Safety: it switches to an ADJACENT existing user Space and switches BACK after 1.2s,
// so you are never stranded. Run: swift run SpaceSwitch

import AppKit
import Foundation

typealias MainConnFn   = @convention(c) () -> Int32
typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SetSpaceFn   = @convention(c) (Int32, CFString, Int32) -> Void
typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Void

func loadSym<T>(_ name: String, as type: T.Type) -> T? {
    let handles: [UnsafeMutableRawPointer?] = [
        nil,
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
let CGSManagedDisplaySetCurrentSpace = loadSym("CGSManagedDisplaySetCurrentSpace", as: SetSpaceFn.self)
// Optional companions some macOS versions want for a clean visual switch:
let CGSShowSpaces = loadSym("CGSShowSpaces", as: ShowSpacesFn.self)
let CGSHideSpaces = loadSym("CGSHideSpaces", as: ShowSpacesFn.self)

print("=== SpaceSwitch: direct-API switch test (no keyboard shortcuts) ===\n")
print("[1] Symbol availability")
print(CGSMainConnectionID != nil ? "  ✅ CGSMainConnectionID" : "  ❌ CGSMainConnectionID")
print(CGSCopyManagedDisplaySpaces != nil ? "  ✅ CGSCopyManagedDisplaySpaces" : "  ❌ CGSCopyManagedDisplaySpaces")
print(CGSManagedDisplaySetCurrentSpace != nil ? "  ✅ CGSManagedDisplaySetCurrentSpace" : "  ❌ CGSManagedDisplaySetCurrentSpace (this OS may not export it)")

guard let mainConn = CGSMainConnectionID,
      let copySpaces = CGSCopyManagedDisplaySpaces,
      let setSpace = CGSManagedDisplaySetCurrentSpace else {
    print("\n❌ Cannot test — a required symbol is missing.")
    exit(1)
}

let cid = mainConn()

struct Sp { let id: Int32; let uuid: String }
func topology() -> (display: String, currentID: Int32, spaces: [Sp])? {
    guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]],
          let d = displays.first else { return nil }
    let displayID = d["Display Identifier"] as? String ?? "Main"
    let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
    let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s -> Sp? in
        guard (s["type"] as? Int ?? 0) == 0, let mid = s["ManagedSpaceID"] as? Int else { return nil }
        return Sp(id: Int32(mid), uuid: s["uuid"] as? String ?? "")
    }
    return (displayID, Int32(cur), spaces)
}

guard let topo = topology(), topo.spaces.count >= 2 else {
    print("\n⚠️  Need ≥2 user Spaces on the primary display to test. Add one in Mission Control.")
    exit(1)
}

let display = topo.display as CFString
let currentIdx = topo.spaces.firstIndex { $0.id == topo.currentID } ?? 0
let target = topo.spaces[currentIdx == topo.spaces.count - 1 ? currentIdx - 1 : currentIdx + 1]

print("\n[2] Plan")
print("  display          = \(topo.display)")
print("  current spaceID  = \(topo.currentID)")
print("  target  spaceID  = \(target.id)  (uuid=\(target.uuid.isEmpty ? "<empty>" : target.uuid))")
print("  → switching to target, then back after 1.2s (you won't be stranded)\n")

@MainActor func switchTo(_ spaceID: Int32) {
    // Some macOS builds need show/hide bracketing for a clean switch; harmless if absent.
    if let show = CGSShowSpaces { show(cid, [NSNumber(value: spaceID)] as CFArray) }
    setSpace(cid, display, spaceID)
    if let hide = CGSHideSpaces { hide(cid, [NSNumber(value: topo.currentID)] as CFArray) }
}

print("[3] Switching → \(target.id)")
switchTo(target.id)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    let now = topology()?.currentID ?? -1
    if now == target.id {
        print("  ✅ SWITCH CONFIRMED via direct API — now on spaceID \(now).")
        print("     Keyboard-shortcut independence achieved. Returning…")
    } else {
        print("  ⚠️  Reported current is \(now), expected \(target.id).")
        print("     (Direct set may need show/hide bracketing or a window-activate nudge on this OS.)")
    }
    switchTo(topo.currentID) // go home
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        print("\n  restored to spaceID \(topology()?.currentID ?? -1). Done.")
        exit(0)
    }
}

RunLoop.main.run()
