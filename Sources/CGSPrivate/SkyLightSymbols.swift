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
  /// Return width confirmed **empirically** (live on macOS 15 / Apple Silicon, in the `/spike`
  /// probe, which no longer lives in `main` — it is archived at the `spike-archive` tag:
  /// https://github.com/blsmth/spacewalker/tree/spike-archive/spike), not from a header —
  /// `CGSGetActiveSpace` has no public declaration, so nothing guarantees `UInt64` stays
  /// correct on a future OS. If a future macOS widens/narrows this or changes its calling
  /// convention, the ABI mismatch will NOT crash: `@convention(c)` + `unsafeBitCast` just reads
  /// whatever bits land in the return register as a `UInt64`, so the symptom is silent — "Space
  /// matching randomly fails" (`SpaceService.matches`/`pollActiveSpace` stop finding the active
  /// Space, or intermittently match the wrong one) rather than a trap. Issue #24.
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
    //
    // The explicit, SIP-protected framework paths MUST be searched before RTLD_DEFAULT, not after.
    // RTLD_DEFAULT walks every image already loaded into this process, in load order — that
    // includes anything injected ahead of the real framework, e.g. via a malicious
    // DYLD_INSERT_LIBRARIES or a hijacked plugin. A same-named symbol in one of those images would
    // shadow the genuine `CGS*` entry point, and the resolved pointer is `unsafeBitCast` straight
    // to a callable function — including on the 30Hz active-space poll — so a shadowed symbol here
    // means the app's entire view of Space topology comes from an attacker-controlled image
    // instead of the real one. Resolving the two absolute, SIP-protected paths first pins us to the
    // genuine framework whenever it's present; RTLD_DEFAULT is only a last-resort fallback for the
    // (expected-rare) case where dlopen itself fails, e.g. a future OS relocating the framework.
    let handles: [UnsafeMutableRawPointer?] = [
      dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
      dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
      // RTLD_DEFAULT, last-resort fallback only — see the rationale above.
      UnsafeMutableRawPointer(bitPattern: -2),
    ]
    for handle in handles {
      if let handle, let sym = dlsym(handle, name) {
        return unsafeBitCast(sym, to: T.self)
      }
    }
    // `name` is a hardcoded CGS/SkyLight symbol name baked into this file, not user data.
    log.error(
      """
      Failed to resolve private symbol \(name, privacy: .public) — Spacewalker's private-API \
      layer may need updating for this OS
      """)
    return nil
  }
}
