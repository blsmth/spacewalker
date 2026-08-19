import Foundation

/// Defense-in-depth text scrub applied to the one field in `DiagnosticsSnapshot` that carries free
/// text pulled from the live system rather than a value this code constructed itself — the
/// harvested `os.Logger` messages in `recentLogs`.
///
/// `os.Logger`'s `.private` privacy annotations (PR-A, issue #25) already keep paths out of what
/// `OSLogStore` hands back: a `.private` interpolation reads back as the literal string
/// `<private>`, even from this same process (verified live — see the PR body for the
/// reproduction). This exists only as a backstop for a future log call site that forgets to mark
/// a path `.private`, so it must never *reduce* an existing `<private>` marker — only catch an
/// absolute path that slipped through unmarked.
enum DiagnosticsRedactor {

  /// `/Users/<name>` — matched first and narrowly (stops at the next `/`) so the abbreviation
  /// keeps the rest of the path, matching the "abbreviate as `~/Library/...`" policy.
  private static let homePathPattern = #"/Users/[^/\s"']+"#
  /// Any remaining absolute path: a `/` not preceded by a word character or `~` (so "and/or",
  /// "1/2", "w/o", and the `~/...` this function just produced above are all left alone) followed
  /// by a run of non-whitespace, non-quote characters.
  private static let absolutePathPattern = #"(?<![\w~])/[^\s"']+"#

  /// Replaces home-directory paths with `~` (keeping the remainder, e.g. `~/Library/...`) and
  /// masks any other absolute path entirely with `<path>`.
  static func redactPaths(in text: String) -> String {
    var result = replaceAll(homePathPattern, in: text, with: "~")
    result = replaceAll(absolutePathPattern, in: result, with: "<path>")
    return result
  }

  private static func replaceAll(_ pattern: String, in text: String, with replacement: String)
    -> String
  {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let fullRange = NSRange(text.startIndex..., in: text)
    var result = text
    for match in regex.matches(in: text, range: fullRange).reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      result.replaceSubrange(range, with: replacement)
    }
    return result
  }
}
