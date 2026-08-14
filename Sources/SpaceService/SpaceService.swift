import AppKit
import CGSPrivate
import SpaceModel
import SpaceSwitching

/// Owns the live Space state: reads topology from the private API, reconciles it against the
/// persisted metadata, and republishes whenever the active Space changes. UI observes via `onChange`.
///
/// Confined to the main actor — it touches AppKit notifications and drives menu-bar UI.
@MainActor
public final class SpaceService {

  public private(set) var displays: [ResolvedDisplay] = []
  public private(set) var current: ResolvedSpace?
  /// Identity key of the Space we were on before the current one — powers "Jump Back".
  public private(set) var previousSpaceKey: String?

  /// Called on the main actor after every refresh. UI re-reads `displays`/`current`.
  public var onChange: (() -> Void)?
  /// Fired only when the active Space actually changes to a different one (not on first load).
  /// This rides the OS notification + a topology read, so it can lag during fast switching.
  public var onSpaceChanged: ((ResolvedSpace) -> Void)?
  /// Fired the instant an app-initiated switch begins, with the known destination — use this for
  /// immediate UI (the HUD) instead of waiting for the lagging `onSpaceChanged`.
  public var onSwitchInitiated: ((ResolvedSpace) -> Void)?
  /// Fired when the OS reports a Space change is happening, before the new Space is resolved —
  /// use it to clear stale UI immediately (the destination arrives via `onSpaceChanged`).
  public var onSwitchDetected: (() -> Void)?

  private let api: SpacesReading
  private let store: SpaceStore
  private let keySynth = KeySynth()
  private var observer: NSObjectProtocol?
  private var lastCurrentKey: String?
  /// Last active Space id64 seen by the fast poll (raw, so fullscreen spaces don't thrash).
  private var lastActiveID: UInt64 = 0
  private var activePoll: Timer?
  /// Guards against overlapping walk sequences.
  private var isSwitching = false

  public init(api: SpacesReading = CGSSpacesAPI(), store: SpaceStore) {
    self.api = api
    self.store = store
  }

  /// True when the private API is usable on this OS. When false, UI should show a degraded state.
  public var isAvailable: Bool { api.isAvailable }

  public func start() {
    // Deliberately does NOT touch system preferences (⌃1…⌃9 shortcuts, mru-spaces) here —
    // that decision requires explicit user consent and lives above this layer, in
    // SystemPrefsCoordinator. See issue #2 / PLAN.md §4.7.
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // Notification is delivered on the main queue; hop to the main actor explicitly for Swift 6.
      MainActor.assumeIsolated {
        self?.onSwitchDetected?()  // clear stale UI now; new Space resolves just below
        self?.refresh()
      }
    }
    refresh()
    // The first WindowServer topology read right after launch can race empty; warm it up so the
    // first ⌘0 already has data.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }

    // Fast active-Space poll: CGSGetActiveSpace reflects the WindowServer's current Space sooner
    // than activeSpaceDidChange + the topology read, so the HUD/menu-bar track switches snappily
    // (esp. rapid external ⌃arrow/⌃N switches). Cheap: it's a single lightweight CGS call.
    let poll = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollActiveSpace() }
    }
    RunLoop.main.add(poll, forMode: .common)
    activePoll = poll
  }

  public func stop() {
    if let observer {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    observer = nil
    activePoll?.invalidate()
    activePoll = nil
  }

  /// Re-read the system and rebuild resolved state.
  public func refresh() {
    // The private API can return an empty/partial topology mid-transition (e.g. right after we
    // activate for the switcher). Retry a few times, and never clobber good state with an empty
    // read — there is always ≥1 Space, so empty means "ask again later", not "no Spaces".
    var resolved = Reconciler.resolve(displays: api.displays(), store: store)
    var attempts = 0
    while !hasAnySpace(resolved) && attempts < 3 {
      attempts += 1
      resolved = Reconciler.resolve(displays: api.displays(), store: store)
    }
    guard hasAnySpace(resolved) || displays.isEmpty else { return }  // keep last good topology

    displays = resolved
    updateCurrent(resolvedCurrent())
  }

  /// Fast path: poll the active Space id and update `current` without re-reading the full topology.
  private func pollActiveSpace() {
    guard let activeID = api.activeSpaceID(), activeID != 0, activeID != lastActiveID else {
      return
    }
    lastActiveID = activeID
    if let space = allSpaces.first(where: { matches($0, activeID) }) {
      updateCurrent(space)
    } else {
      refresh()  // active id not in our cached topology (new/fullscreen Space) — rebuild once
    }
  }

  /// Current Space, preferring `CGSGetActiveSpace` (fresher) over the topology dict's Current Space.
  private func resolvedCurrent() -> ResolvedSpace? {
    if let activeID = api.activeSpaceID(), activeID != 0,
      let space = allSpaces.first(where: { matches($0, activeID) })
    {
      lastActiveID = activeID
      return space
    }
    return Reconciler.currentSpace(in: displays)
  }

  private func matches(_ space: ResolvedSpace, _ id64: UInt64) -> Bool {
    space.identity.id64 >= 0 && UInt64(space.identity.id64) == id64
  }

  /// Set `current`, tracking previous Space for Jump Back and firing change callbacks.
  private func updateCurrent(_ space: ResolvedSpace?) {
    current = space
    if let key = space?.id, key != lastCurrentKey {
      let hadPrevious = lastCurrentKey != nil
      if let last = lastCurrentKey { previousSpaceKey = last }
      lastCurrentKey = key
      if hadPrevious, let space { onSpaceChanged?(space) }
    }
    onChange?()
  }

  private func hasAnySpace(_ displays: [ResolvedDisplay]) -> Bool {
    displays.contains { !$0.spaces.isEmpty }
  }

  // MARK: Mutations

  public func rename(_ identity: SpaceIdentity, to name: String?) {
    store.setName(name, for: identity)
    refresh()
  }

  public func setSymbol(_ symbolName: String?, for identity: SpaceIdentity) {
    store.setSymbol(symbolName, for: identity)
    refresh()
  }

  public func setColor(_ colorHex: String?, for identity: SpaceIdentity) {
    store.setColor(colorHex, for: identity)
    refresh()
  }

  /// All user Spaces across displays, flattened in display+order.
  public var allSpaces: [ResolvedSpace] {
    displays.flatMap(\.spaces)
  }

  // MARK: Switching

  public enum SwitchResult: Sendable {
    case ok
    case alreadyThere
    /// Script errored. `code` is the AppleScript error number (-1743 = Automation denied).
    case notPermitted(message: String, code: Int)
    case crossDisplayUnsupported
    case notFound
    case busy
  }

  /// Switch to the Space with the given identity key by walking Ctrl+←/→ through System Events.
  /// Paced (~220ms/step) because each hop animates; completion fires on the main actor.
  public func switchTo(key: String, completion: ((SwitchResult) -> Void)? = nil) {
    guard !isSwitching else {
      completion?(.busy)
      return
    }
    guard
      let target = displays.flatMap({ d in d.spaces.map { (d, $0) } })
        .first(where: { $0.1.id == key })
    else {
      completion?(.notFound)
      return
    }

    let (targetDisplay, targetSpace) = target
    guard let currentSpace = targetDisplay.spaces.first(where: { $0.isCurrent }) else {
      // Active Space is on a different display — walking there isn't reliable yet.
      completion?(.crossDisplayUnsupported)
      return
    }

    guard currentSpace.id != targetSpace.id else {
      completion?(.alreadyThere)
      return
    }

    // No AXIsProcessTrusted pre-gate: just run the script and let macOS surface its own prompts
    // (the pre-gate blocked execution before the "control System Events" dialog could appear).
    isSwitching = true
    onSwitchInitiated?(targetSpace)  // instant HUD — we already know the destination

    let desktopNumber = targetSpace.userIndex + 1
    let singleDisplay = displays.count == 1
    if singleDisplay, desktopNumber <= DesktopShortcuts.maxDirectDesktop,
      DesktopShortcuts.allEnabled(upTo: desktopNumber)
    {
      // One-hop direct jump via ⌃N.
      finish(keySynth.switchToDesktop(desktopNumber), completion: completion)
    } else {
      // Walk ⌃←/→ hop-by-hop (multi-display, or beyond ⌃9).
      let steps = SwitchPlanner.walk(
        fromIndex: currentSpace.userIndex, toIndex: targetSpace.userIndex)
      execute(steps: steps, index: 0) { [weak self] result in
        self?.finish(result, completion: completion)
      }
    }
  }

  private func finish(_ result: SwitchResult, completion: ((SwitchResult) -> Void)?) {
    isSwitching = false
    refresh()
    completion?(result)
  }

  private func finish(
    _ synthResult: Result<Void, KeySynth.SynthError>,
    completion: ((SwitchResult) -> Void)?
  ) {
    switch synthResult {
    case .success:
      finish(.ok, completion: completion)
    case .failure(.failed(let message, let code)):
      finish(.notPermitted(message: message, code: code), completion: completion)
    case .failure(.compileFailed):
      finish(
        .notPermitted(message: "Could not compile switch script", code: 0), completion: completion)
    }
  }

  /// Jump back to the previously-active Space.
  public func jumpBack(completion: ((SwitchResult) -> Void)? = nil) {
    guard let key = previousSpaceKey else {
      completion?(.notFound)
      return
    }
    switchTo(key: key, completion: completion)
  }

  private func execute(
    steps: [SwitchDirection], index: Int, completion: @escaping (SwitchResult) -> Void
  ) {
    guard index < steps.count else {
      completion(.ok)
      return
    }
    switch keySynth.step(steps[index]) {
    case .failure(.failed(let message, let code)):
      completion(.notPermitted(message: message, code: code))
    case .failure(.compileFailed):
      completion(.notPermitted(message: "Could not compile switch script", code: 0))
    case .success:
      // Pace hops so the WindowServer doesn't coalesce rapid synthetic switches.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
        self?.execute(steps: steps, index: index + 1, completion: completion)
      }
    }
  }
}
