import CGSPrivate

/// Sanity-checks already-parsed `RawDisplay`/`RawSpace` values before they ever reach
/// `Reconciler`/`SpaceStore` — issue #24.
///
/// `CGSPrivate`'s `parseDisplay`/`parseSpace` already reject a dictionary with a missing or
/// wrong-typed key (a symbol renamed/restructuring what it returns). This validator catches the
/// narrower, sneakier failure that survives type-correct parsing: values that cast fine but are
/// semantically nonsense, most importantly two Spaces on the same display resolving to the same
/// `SpaceIdentity.key`. That is exactly what would happen if every Space's `id64`/`uuid` came back
/// `-1`/`""` — every one of them collapses to the single key `"id64:-1"`, silently merging distinct
/// Spaces into one in the UI and misdirecting every switch. `SpaceIdentity`'s own doc comment says
/// this must never happen; this is what makes that a checked invariant instead of a hope.
///
/// Pure and dependency-free (no private symbol, no I/O) so it is fully unit-testable — see
/// `TopologyValidatorTests`.
public enum TopologyValidator {

  /// One thing wrong with a display's Spaces. Carries only counts/identity keys (never a Space
  /// name) so a caller can log a `Problem` without violating the diagnostics redaction policy.
  public enum Problem: Equatable, Sendable {
    /// Two (or more) Spaces on `displayID` resolved to the same `SpaceIdentity.key`. Catches the
    /// collapse case where distinct Spaces become indistinguishable (e.g. all garbage `uuid=""`).
    case duplicateIdentity(displayID: String, key: String)
    /// Two (or more) Spaces on `displayID` reported the same `id64` — checked independently of
    /// `duplicateIdentity` because a shared `id64` with two *different* real uuids would otherwise
    /// slip through the key-based check (uuid wins the key when present) while still being a
    /// WindowServer-level id collision `id64` is supposed to make impossible.
    case duplicateID64(displayID: String, id64: Int)
    /// A Space's `id64` was negative — CGS never legitimately returns one (`RawSpace.id64` is
    /// meant to be a real WindowServer id; `-1` is this codebase's own "couldn't parse" sentinel
    /// from before issue #24, never a value CGS itself returns for a real Space).
    case negativeID64(displayID: String, id64: Int)
  }

  /// The outcome of validating a topology read. `isValid` is the only thing most callers need;
  /// `problems` exists for logging/diagnostics detail without exposing anything sensitive.
  public struct Result: Equatable, Sendable {
    public let problems: [Problem]
    public var isValid: Bool { problems.isEmpty }

    public init(problems: [Problem]) {
      self.problems = problems
    }
  }

  /// Validates a full topology read. Duplicate-identity detection is scoped **per display** —
  /// the same `id64` legitimately recurs across different displays (each display has its own
  /// WindowServer-assigned id space), so only a collision *within* one display's Space list is a
  /// problem.
  public static func validate(_ displays: [RawDisplay]) -> Result {
    var problems: [Problem] = []
    for display in displays {
      var seenKeys: Set<String> = []
      var seenID64s: Set<Int> = []
      for space in display.spaces {
        if space.id64 < 0 {
          problems.append(.negativeID64(displayID: display.displayID, id64: space.id64))
        }
        if !seenID64s.insert(space.id64).inserted {
          problems.append(.duplicateID64(displayID: display.displayID, id64: space.id64))
        }
        let key = SpaceIdentity(raw: space).key
        if !seenKeys.insert(key).inserted {
          problems.append(.duplicateIdentity(displayID: display.displayID, key: key))
        }
      }
    }
    return Result(problems: problems)
  }
}
