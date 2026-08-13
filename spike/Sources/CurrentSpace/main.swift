// CurrentSpace — prints "<activeUserIndex>/<userSpaceCount>" for the main display.
// A tiny ground-truth reader so shell tests can detect real Space jumps. Reused by DirectJumpTest.
import Foundation

typealias MainConnFn = @convention(c) () -> Int32
typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

func sym<T>(_ n: String, _ t: T.Type) -> T? {
    for h in [UnsafeMutableRawPointer(bitPattern: -2),
              dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)] {
        if let h, let s = dlsym(h, n) { return unsafeBitCast(s, to: T.self) }
    }
    return nil
}

let cid = sym("CGSMainConnectionID", MainConnFn.self)!()
let copy = sym("CGSCopyManagedDisplaySpaces", CopyFn.self)!
guard let displays = copy(cid)?.takeRetainedValue() as? [[String: Any]],
      let d = displays.first else { print("?/?"); exit(1) }

let currentManaged = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
let userSpaces = (d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int ?? 0) == 0 }
let index = userSpaces.firstIndex { ($0["ManagedSpaceID"] as? Int) == currentManaged } ?? -1
print("\(index)/\(userSpaces.count)")
