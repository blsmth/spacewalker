/// Tiny subsequence fuzzy matcher for the Quick Switcher's type-to-filter.
/// Case-insensitive; rewards contiguous runs and a prefix match. Pure + testable.
public enum FuzzyMatch {

  /// Score for `query` against `text` (higher = better), or nil if `query` isn't a subsequence.
  public static func score(query: String, in text: String) -> Int? {
    guard !query.isEmpty else { return 0 }
    let q = Array(query.lowercased())
    let t = Array(text.lowercased())
    var qi = 0
    var streak = 0
    var score = 0
    for ch in t {
      if qi < q.count, ch == q[qi] {
        qi += 1
        streak += 1
        score += 1 + streak  // contiguous matches worth more
      } else {
        streak = 0
      }
    }
    guard qi == q.count else { return nil }
    if t.first == q.first { score += 5 }  // prefix bonus
    return score
  }

  /// Filter + rank `items` by how well `name(item)` matches `query`. Empty query keeps order.
  public static func rank<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
    guard !query.isEmpty else { return items }
    return
      items
      .compactMap { item in score(query: query, in: name(item)).map { (item, $0) } }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }
}
