/// Pure planning of how to get from one Space to another by walking left/right.
///
/// macOS only reliably honors *adjacent* move-space shortcuts (Ctrl+←/→) for synthetic input, so a
/// jump to an arbitrary Space becomes a sequence of single steps. (Direct "Switch to Desktop N"
/// jumps are a later optimization gated on enabling those shortcuts — see PLAN.md §1.)
public enum SwitchDirection: Equatable, Sendable {
  case left, right
}

public enum SwitchPlanner {

  /// Steps to walk from one strip position to another. Empty when already there.
  ///
  /// Both arguments must be `ResolvedSpace.stripIndex` values — positions in the display's full
  /// Mission Control strip, *counting fullscreen tiles*. ⌃←/→ steps through every tile on the
  /// strip, so passing `userIndex` (which skips fullscreen tiles) under-counts hops and silently
  /// lands on the wrong Space. The parameter labels say `strip` to make that misuse loud.
  public static func walk(fromStripIndex: Int, toStripIndex: Int) -> [SwitchDirection] {
    guard fromStripIndex != toStripIndex else { return [] }
    let direction: SwitchDirection = toStripIndex > fromStripIndex ? .right : .left
    return Array(repeating: direction, count: abs(toStripIndex - fromStripIndex))
  }
}
