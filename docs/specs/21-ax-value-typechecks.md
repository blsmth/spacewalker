# Spacewalker #21 — harden Dock AX value extraction

Issue: https://github.com/blsmth/spacewalker/issues/21
Base: main @ 914b31c. Branch: fix/ax-value-typechecks

## Problem
Four force-casts (`as! AXValue`) on values from the Dock's accessibility tree —
a tree we do not control:
  Sources/SpacewalkerApp/AXUtil.swift:34-35
  Sources/SpacewalkerApp/MissionControlProbe.swift:132-133
`AXUIElementCopyAttributeValue` returning `.success` does NOT guarantee the value
is an AXValue wrapping CGPoint/CGSize. AXUtil.frame(_:) runs every 150ms from
MissionControlOverlay.tick() while walking the live Dock tree, so one bad element
— or any macOS revision of the Mission Control UI — is a repeating hard crash of
a menu-bar agent the user cannot see.

## Required fix
- Replace every force-cast with a guarded path:
    guard let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    guard let axv = v as? AXValue else { return nil }
- Check AXValueGetType(axv) matches the expected type (.cgPoint / .cgSize)
  BEFORE calling AXValueGetValue. Bail out returning nil on mismatch.
- Check AXValueGetValue's Bool return; do not trust the out-param on false.
- Grep the whole tree for any other `as! AXValue` / force-cast on AX or CF values
  and fix those too. The issue lists four; verify that number rather than assume it.

## Constraints
- Failure must be silent-and-safe (return nil), never fatal. The caller already
  handles nil frames.
- Do not change AXUtil.frame's signature or any call site's behavior on the happy path.
- MissionControlProbe.swift may be at a different path/line than the issue states —
  the issue's line numbers predate several merges. Locate by symbol, not line.

## Tests
Add unit coverage where the seam allows. If AX values cannot be faked in-process,
say so explicitly in the PR rather than writing a test that asserts nothing.

## Deliverable
Branch, commit (imperative mood), push, open PR against main. Include a short
Test Plan section. Do not amend existing commits. Do not `git add -A`.

## Deviations

- **Force-cast count was 2, not 4.** `MissionControlProbe.swift` (removed in commit
  `441d83a`, "Remove Dock AX dump spike and Spikes menu from the release build") no
  longer exists — its frame-reading logic was consolidated into `AXUtil.frame(_:)`,
  which `MissionControlOverlay.tick()` calls. A repo-wide grep for `as!` (and other
  `as! AX*`/`as! CF*` patterns) turned up exactly the two force-casts named in the
  issue body, both on `AXUtil.swift:34-35`. No other force-casts on AX/CF values
  exist anywhere in `Sources/`.
- **`v as? AXValue` does not compile.** `AXValue` is a toll-free-bridged CF type, so
  Swift 6 treats a conditional downcast to it as a *compile error*
  ("conditional downcast to CoreFoundation type 'AXValue' will always succeed"),
  not a runtime check — the compiler's own suggested fix is to compare
  `CFGetTypeID`s explicitly, which the guard already does. Used `unsafeDowncast`
  (per the compiler's follow-up warning, over `unsafeBitCast`) instead, with a
  comment explaining why it's safe only because the preceding `CFGetTypeID`
  comparison already confirmed the runtime type.
- **Extracted `AXUtil.point(from:)`/`size(from:)`** rather than inlining the guards
  in `frame(_:)`, so the type-check/decode logic is a pure, testable seam. Added a
  `SpacewalkerAppTests` test target (SwiftPM supports test targets depending on an
  `executableTarget`) with `AXValueCreate`-built fixtures covering: nil input, a
  non-`AXValue` `CFTypeRef`, an `AXValue` of the wrong encoded type, and the valid
  round-trip — all in-process, no live Dock AX tree needed.
