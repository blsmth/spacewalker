import Foundation

/// Manages the macOS "Move left a space" / "Move right a space" keyboard shortcuts (⌃←/⌃→) that
/// the walk path (`SwitchPlanner.walk` + `KeySynth.step`) depends on for every switch that isn't a
/// single-hop ⌃N jump — i.e. whenever `displays.count != 1` or the target desktop is beyond
/// `DesktopShortcuts.maxDirectDesktop`. That's every multi-monitor user, on every switch. These
/// live in `com.apple.symbolichotkeys` as ids **79** (move left) and **81** (move right). See
/// issue #7 — nothing in the codebase checked these ids at all before this file existed; a
/// rebound-away shortcut here produced exactly the same silent no-op-reported-as-success failure
/// mode as issue #6 did for "Switch to Desktop N".
///
/// Unlike `DesktopShortcuts` (ids 118…126, off by default until the user or Spacewalker turns them
/// on), ids 79/81 ship **enabled by default** at the OS level. Confirmed live on macOS 15 via
/// `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys`: an untouched entry for 79/81
/// reads as `{ enabled = 1; }` with **no `value` key at all** (the same shape ids 15…26, another
/// on-by-default Mission Control range, use). macOS only writes an explicit `value` once something
/// — System Settings, a remap tool, or Spacewalker — actually changes the binding away from the
/// factory default of Control+Left/Right (keycodes 123/124). So for these two ids specifically,
/// "enabled with no explicit `value`" means "still at the correct factory default", the opposite
/// of what an absent `value` would imply for `DesktopShortcuts`. Getting this backwards would nag
/// every user who has never opened Keyboard Shortcuts settings, which is nearly everyone.
///
/// Shares its binding predicate with `DesktopShortcuts` via `SymbolicHotKeyBinding` so the read
/// path (`allEnabled`/`isSatisfied`) and the write path (`plan`) can't independently disagree.
public enum MoveSpaceShortcuts {

  private static let domain = "com.apple.symbolichotkeys"
  private static let hotkeysKey = "AppleSymbolicHotKeys"

  /// symbolichotkeys entry ids for "Move left/right a space".
  public static let leftID = 79
  public static let rightID = 81

  /// Keycodes for the physical arrow keys ⌃← / ⌃→ synthesizes (`KeySynth.step`).
  private static let leftKeycode = 123
  private static let rightKeycode = 124

  public static func id(for direction: SwitchDirection) -> Int {
    direction == .left ? leftID : rightID
  }

  private static func keycode(for direction: SwitchDirection) -> Int {
    direction == .left ? leftKeycode : rightKeycode
  }

  /// True if both "Move left/right a space" shortcuts are ready for the walk path to rely on:
  /// enabled, and either still at the factory Control+arrow default (no explicit `value`) or
  /// explicitly bound to exactly that. Mirrors `DesktopShortcuts.allEnabled`.
  public static func allEnabled() -> Bool {
    isSatisfied(existing: current() ?? [:])
  }

  /// Pure read-side check, free of CFPreferences — see the type doc comment for why "enabled, no
  /// explicit `value`" is treated as satisfied here, unlike `DesktopShortcuts`.
  static func isSatisfied(existing: [String: Any]) -> Bool {
    [SwitchDirection.left, .right].allSatisfy { isSatisfied(existing: existing, direction: $0) }
  }

  static func isSatisfied(existing: [String: Any], direction: SwitchDirection) -> Bool {
    let entry = existing["\(id(for: direction))"] as? [String: Any]
    guard SymbolicHotKeyBinding.isEnabled(entry) else { return false }
    guard entry?["value"] != nil else {
      return true  // enabled, no explicit override recorded — still at the factory default
    }
    return SymbolicHotKeyBinding.isBoundToTarget(entry, keycode: keycode(for: direction))
  }

  /// Pure planning step, mirroring `DesktopShortcuts.plan`: decide the updated dictionary to write
  /// for 79/81. An entry is written only if it's missing, or explicitly disabled — never when it's
  /// already enabled, whether that's the factory default (no `value`) or an explicit binding that
  /// already matches ours (both cases become a harmless no-op rewrite that makes the binding
  /// explicit). An entry that's enabled and explicitly bound to something else is left untouched
  /// and its direction reported in `conflicts` — the user deliberately rebound it, and we must not
  /// silently take it back.
  static func plan(existing: [String: Any]) -> (
    updated: [String: Any], conflicts: [SwitchDirection]
  ) {
    var dict = existing
    var conflicts: [SwitchDirection] = []
    for direction in [SwitchDirection.left, .right] {
      let idKey = "\(id(for: direction))"
      let entry = dict[idKey] as? [String: Any]
      guard SymbolicHotKeyBinding.isEnabled(entry) else {
        dict[idKey] = target(for: direction)  // absent or explicitly disabled — safe to claim
        continue
      }
      if entry?["value"] == nil
        || SymbolicHotKeyBinding.isBoundToTarget(entry, keycode: keycode(for: direction))
      {
        dict[idKey] = target(for: direction)
      } else {
        conflicts.append(direction)
      }
    }
    return (dict, conflicts)
  }

  private static func target(for direction: SwitchDirection) -> [String: Any] {
    [
      "enabled": 1,
      "value": SymbolicHotKeyBinding.targetValue(
        asciiPlaceholder: SymbolicHotKeyBinding.nonPrintableAsciiPlaceholder,
        keycode: keycode(for: direction)),
    ]
  }

  /// Write the ⌃←/⌃→ shortcuts, preserving any other symbolichotkeys and never clobbering a
  /// deliberate user rebinding (see `plan`). Returns the directions left alone as conflicts (empty
  /// means both are now bound to Control+arrow). Callers must reload live settings afterward — see
  /// `DesktopShortcuts.reloadSettingsAsync` — this only writes the preference.
  @discardableResult
  public static func enable() -> [SwitchDirection] {
    let (updated, conflicts) = plan(existing: current() ?? [:])
    CFPreferencesSetAppValue(hotkeysKey as CFString, updated as CFDictionary, domain as CFString)
    CFPreferencesAppSynchronize(domain as CFString)
    return conflicts
  }

  private static func current() -> [String: Any]? {
    CFPreferencesCopyAppValue(hotkeysKey as CFString, domain as CFString) as? [String: Any]
  }
}
