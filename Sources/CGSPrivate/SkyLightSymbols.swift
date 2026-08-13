import Foundation

/// Runtime resolution of private SkyLight / CoreGraphics ("CGS") symbols via `dlsym`.
///
/// We deliberately resolve at runtime rather than link against the private framework:
/// - No fragile link-time dependency on a private `.tbd`.
/// - A missing symbol becomes a `nil` we can detect and degrade around, not a crash.
///
/// This is the ONLY file in the codebase that touches raw private symbols. Verified working on
/// macOS 15 / Apple Silicon in the `/spike` probe.
enum SkyLightSymbols {

  // MARK: Function-pointer typealiases (C calling convention)

  typealias MainConnectionID = @convention(c) () -> Int32
  typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
  typealias GetActiveSpace = @convention(c) (Int32) -> UInt64

  // MARK: Resolved symbols (nil if unavailable on this OS)

  static let mainConnectionID: MainConnectionID? =
    load("CGSMainConnectionID", as: MainConnectionID.self)

  static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? =
    load("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)

  static let getActiveSpace: GetActiveSpace? =
    load("CGSGetActiveSpace", as: GetActiveSpace.self)

  // MARK: dlsym plumbing

  private static func load<T>(_ name: String, as type: T.Type) -> T? {
    // dlopen is idempotent/refcounted, so resolving handles per (rare) lookup is cheap and
    // sidesteps sharing non-Sendable pointers across a static. RTLD_DEFAULT is (void*)-2.
    let handles: [UnsafeMutableRawPointer?] = [
      UnsafeMutableRawPointer(bitPattern: -2),  // already-loaded images (RTLD_DEFAULT)
      dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
      dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
    ]
    for handle in handles {
      if let handle, let sym = dlsym(handle, name) {
        return unsafeBitCast(sym, to: T.self)
      }
    }
    return nil
  }
}
