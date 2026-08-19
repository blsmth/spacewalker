import Foundation

/// A minimal semantic-version value for comparing Spacewalker's own version against a GitHub
/// release tag (issue #32). Deliberately not a general-purpose semver library: it only needs to
/// answer "is X newer than Y", tolerating the two real-world irregularities a release tag actually
/// has — a leading "v" (GitHub tag convention, e.g. "v0.10.0") and a pre-release/build suffix
/// ("-beta.1", "+abc123").
///
/// Comparison is numeric on (major, minor, patch), never string comparison — `"0.10.0"` must sort
/// above `"0.9.0"`, which a naive string compare gets backwards.
struct SemVer: Comparable, Equatable, Sendable {
  let major: Int
  let minor: Int
  let patch: Int

  /// Fails (returns `nil`) rather than crashing or guessing on anything that isn't recognizably
  /// `major[.minor[.patch]]` — a malformed or missing tag from the GitHub API must never be treated
  /// as "obviously older" or "obviously newer" by accident.
  init?(_ raw: String) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if text.hasPrefix("v") || text.hasPrefix("V") {
      text.removeFirst()
    }

    // Drop a pre-release/build suffix. Precedence between e.g. "1.0.0" and "1.0.0-beta.1" is
    // deliberately not modeled -- Spacewalker doesn't publish pre-release tags, and treating the
    // suffixed form as equal-version is safer than guessing wrong in either direction.
    if let suffixStart = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
      text = String(text[text.startIndex..<suffixStart])
    }

    let components = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(components.count) else { return nil }

    let numbers = components.map { Int($0) }
    guard numbers.allSatisfy({ $0 != nil }) else { return nil }
    let values = numbers.compactMap { $0 }

    major = values[0]
    minor = values.count > 1 ? values[1] : 0
    patch = values.count > 2 ? values[2] : 0
  }

  static func < (lhs: SemVer, rhs: SemVer) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}
