/// Pure planning of how to get from one Space to another by walking left/right.
///
/// macOS only reliably honors *adjacent* move-space shortcuts (Ctrl+←/→) for synthetic input, so a
/// jump to an arbitrary Space becomes a sequence of single steps. (Direct "Switch to Desktop N"
/// jumps are a later optimization gated on enabling those shortcuts — see PLAN.md §1.)
public enum SwitchDirection: Equatable, Sendable {
  case left, right
}

public enum SwitchPlanner {

  /// Steps to walk from `fromIndex` to `toIndex` among a display's ordered user Spaces.
  /// Empty when already there.
  public static func walk(fromIndex: Int, toIndex: Int) -> [SwitchDirection] {
    guard fromIndex != toIndex else { return [] }
    let direction: SwitchDirection = toIndex > fromIndex ? .right : .left
    return Array(repeating: direction, count: abs(toIndex - fromIndex))
  }
}
