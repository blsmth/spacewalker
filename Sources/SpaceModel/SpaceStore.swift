import Foundation

/// Persists per-Space metadata keyed by `SpaceIdentity.key`.
///
/// Serialized as a flat `{ key: SpaceMetadata }` JSON at
/// `~/Library/Application Support/Spacewalker/spaces.json`. Missing Spaces are **kept, not
/// deleted**, so replugging a display or rebooting restores custom names. Pass `fileURL: nil` for
/// an in-memory store (tests).
public final class SpaceStore {

  private var byKey: [String: SpaceMetadata]
  private let fileURL: URL?

  public init(fileURL: URL?) {
    self.fileURL = fileURL
    self.byKey = SpaceStore.read(from: fileURL) ?? [:]
  }

  // MARK: Lookup

  public func metadata(for identity: SpaceIdentity) -> SpaceMetadata? {
    byKey[identity.key]
  }

  public var allKeys: [String] { Array(byKey.keys) }

  // MARK: Mutation (auto-persists)

  /// Set the custom name. Passing nil/empty clears it (and drops the entry if nothing remains).
  public func setName(_ name: String?, for identity: SpaceIdentity) {
    update(identity) { $0.name = (name?.isEmpty ?? true) ? nil : name }
  }

  public func setSymbol(_ symbolName: String?, for identity: SpaceIdentity) {
    update(identity) { $0.symbolName = (symbolName?.isEmpty ?? true) ? nil : symbolName }
  }

  public func setColor(_ colorHex: String?, for identity: SpaceIdentity) {
    update(identity) { $0.colorHex = (colorHex?.isEmpty ?? true) ? nil : colorHex }
  }

  private func update(_ identity: SpaceIdentity, _ mutate: (inout SpaceMetadata) -> Void) {
    var meta = byKey[identity.key] ?? SpaceMetadata()
    mutate(&meta)
    if meta.isEmpty {
      byKey.removeValue(forKey: identity.key)
    } else {
      byKey[identity.key] = meta
    }
    persist()
  }

  // MARK: Persistence

  private func persist() {
    guard let fileURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(byKey).write(to: fileURL, options: .atomic)
    } catch {
      // Non-fatal: a failed write just means custom names don't survive relaunch.
      NSLog("SpaceStore: failed to persist: \(error)")
    }
  }

  private static func read(from fileURL: URL?) -> [String: SpaceMetadata]? {
    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? JSONDecoder().decode([String: SpaceMetadata].self, from: data)
  }

  // MARK: Default location

  public static func defaultFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Spacewalker/spaces.json")
  }
}
