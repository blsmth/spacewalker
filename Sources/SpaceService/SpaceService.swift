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
  private let keySynth: KeySynthesizing
  private var observer: NSObjectProtocol?
  private var lastCurrentKey: String?
  /// Last active Space id64 seen by the fast poll (raw, so fullscreen spaces don't thrash).
  private var lastActiveID: UInt64 = 0
  /// The 33Hz active-Space poll — armed on demand by `armFastPoll()`, not run continuously (#19).
  private var activePoll: Timer?
  /// Bumped by every `armFastPoll()` call; a scheduled expiry only tears `activePoll` down if
  /// it's still the most recent one, so an older, superseded expiry firing late (e.g. a second
  /// switch/keypress happened before the first window elapsed) is a no-op instead of cutting the
  /// poll short mid-walk.
  private var pollGeneration = 0
  /// True while the display or system is asleep. Blocks new `armFastPoll()` calls and tears down
  /// any poll already running — see the sleep/wake observers installed in `start()`.
  private var isSuspended = false
  private var sleepWakeObservers: [NSObjectProtocol] = []
  /// Guards against overlapping walk sequences.
  private var isSwitching = false
  /// How long to wait after a synthesized switch before re-reading `activeSpaceID()` to confirm
  /// it actually took (see `Constants.verificationDelay`).
  private let verificationDelay: TimeInterval
  /// How the post-switch verification delay is scheduled. Defaults to a real `asyncAfter`; tests
  /// substitute a fake so they can fire it deterministically instead of sleeping ~250ms.
  ///
  /// Typed `@MainActor` throughout (not `@Sendable`) rather than routing `work` through a plain
  /// `() -> Void`: a closure isolated to a global actor is itself safe to hand to any thread (only
  /// running its body requires the hop), so the compiler treats it as implicitly `Sendable` — the
  /// same reason the existing `DispatchQueue.main.asyncAfter { [weak self] in … }` call in
  /// `execute(steps:index:completion:)` below needs no annotation at all. Threading a bare
  /// non-isolated `() -> Void` through a stored property loses that inference and would force
  /// every caller to prove `Sendable` captures for what is, in practice, always MainActor-only code.
  private let scheduleAfterDelay: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
  /// How the fast-poll's self-expiry window (see `armFastPoll()`) is scheduled. Same seam pattern
  /// as `scheduleAfterDelay`, but kept as its own independent property/instance rather than
  /// reused — a single switch schedules both a fast-poll expiry and, separately, the post-switch
  /// verification read, and sharing one fake scheduler between them would make one clobber the
  /// other in tests.
  private let scheduleFastPollExpiry:
    @MainActor (TimeInterval, @escaping @MainActor () -> Void) ->
      Void

  private enum Constants {
    /// #5: `KeySynth` only reports whether the AppleScript errored, not whether the WindowServer
    /// honored the shortcut (PLAN.md §1 — a delivered-but-unbound shortcut returns success with no
    /// visible switch). 250ms is comfortably longer than the animation needs to *start* moving the
    /// active-Space pointer (the switches in the spike settled well under 100ms), short enough
    /// that a genuine failure is reported to the user promptly, and cheap either way — this reuses
    /// the same `CGSGetActiveSpace` call the 33Hz poll already makes.
    static let verificationDelay: TimeInterval = 0.25
    /// #19: how long the 33Hz active-Space poll stays armed after a switch is initiated (by us,
    /// via `switchTo`) or after `SwitchKeyTap` observes someone else's Space-switch keypress (via
    /// `noteExternalSwitchKeySeen`). Comfortably covers a typical walk's hop pacing plus
    /// `verificationDelay`; outside this window `activeSpaceDidChangeNotification` (wired in
    /// `start()`) is the only thing driving `current`, so the run loop can go idle and the
    /// process is eligible for App Nap the other 99%+ of its life.
    static let fastPollWindow: TimeInterval = 1.5
  }

  public convenience init(api: SpacesReading = CGSSpacesAPI(), store: SpaceStore) {
    self.init(
      api: api, store: store, keySynth: KeySynth(),
      verificationDelay: Constants.verificationDelay,
      scheduleAfterDelay: { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
      },
      scheduleFastPollExpiry: { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
      })
  }

  /// Test seam (`internal`, reached via `@testable import`): lets `SpaceServiceTests` substitute a
  /// fake `KeySynthesizing` (no real AppleScript/System Events) and run the post-switch
  /// verification delay synchronously and under test control, instead of sleeping ~250ms per test.
  internal init(
    api: SpacesReading,
    store: SpaceStore,
    keySynth: KeySynthesizing,
    verificationDelay: TimeInterval,
    scheduleAfterDelay: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) ->
      Void,
    scheduleFastPollExpiry: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) ->
      Void
  ) {
    self.api = api
    self.store = store
    self.keySynth = keySynth
    self.verificationDelay = verificationDelay
    self.scheduleAfterDelay = scheduleAfterDelay
    self.scheduleFastPollExpiry = scheduleFastPollExpiry
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

    // #19: the 33Hz active-Space poll used to run continuously for the app's entire life, which
    // is a `.common`-mode timer that never lets the run loop go idle — a permanent disqualifier
    // for App Nap. It's now armed on demand (`armFastPoll()`, called from `switchTo` and
    // `noteExternalSwitchKeySeen`) and self-invalidates; `activeSpaceDidChangeNotification`
    // (above) is sufficient the rest of the time.
    installSleepWakeObservers()
  }

  public func stop() {
    if let observer {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    observer = nil
    removeSleepWakeObservers()
    activePoll?.invalidate()
    activePoll = nil
    pollGeneration += 1  // any expiry already scheduled for the torn-down poll becomes a no-op
  }

  /// Arms (or, if already armed, extends) the 33Hz active-Space poll for
  /// `Constants.fastPollWindow`. Outside that window `activeSpaceDidChangeNotification` is the
  /// only thing driving `current` — see the doc comment on `start()`. Called when we initiate a
  /// switch ourselves (`switchTo`) and, via `noteExternalSwitchKeySeen()`, when `SwitchKeyTap`
  /// observes someone else's Space-switch keypress — that tap sits upstream of the WindowServer's
  /// own handling of the key (see its doc comment), so the poll is already armed by the time an
  /// external switch actually lands.
  private func armFastPoll() {
    guard !isSuspended else { return }  // asleep/display off — nothing to track live right now
    if activePoll == nil {
      let poll = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.pollActiveSpace() }
      }
      RunLoop.main.add(poll, forMode: .common)
      activePoll = poll
    }
    pollGeneration += 1
    let generation = pollGeneration
    scheduleFastPollExpiry(Constants.fastPollWindow) { [weak self] in
      // A later arm superseded this one — leave the newer window's poll alone.
      guard let self, self.pollGeneration == generation else { return }
      self.activePoll?.invalidate()
      self.activePoll = nil
    }
  }

  /// Called by `AppDelegate` when `SwitchKeyTap` observes a real Space-switch key (⌃←/→/1…9) —
  /// covers external switches (trackpad gesture, hardware keypress) the same way `switchTo`
  /// covers our own. See `armFastPoll()` for what this actually does and why.
  public func noteExternalSwitchKeySeen() {
    armFastPoll()
  }

  /// Test seam (`internal`, reached via `@testable import`): lets `SpaceServiceTests` observe
  /// whether the fast poll is currently armed without spinning a real 0.03s timer to prove it
  /// indirectly.
  internal var isFastPollArmedForTesting: Bool { activePoll != nil }

  /// #19: suspend the fast poll (and refuse new arms) while the display/system is asleep — there
  /// is no user to switch Spaces, and a timer that keeps firing into sleep is exactly the kind of
  /// thing that blocks App Nap. `screensDidSleepNotification` covers display sleep (lid closed on
  /// a plugged-in Mac, an idle display, etc.) in addition to full system sleep, which fires both.
  private func installSleepWakeObservers() {
    let nc = NSWorkspace.shared.notificationCenter
    sleepWakeObservers = [
      nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.suspendFastPoll() }
      },
      nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.suspendFastPoll() }
      },
      nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.isSuspended = false }
      },
      nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.isSuspended = false }
      },
    ]
  }

  private func removeSleepWakeObservers() {
    let nc = NSWorkspace.shared.notificationCenter
    for sleepWakeObserver in sleepWakeObservers {
      nc.removeObserver(sleepWakeObserver)
    }
    sleepWakeObservers = []
  }

  private func suspendFastPoll() {
    isSuspended = true
    pollGeneration += 1  // let any pending expiry closure no-op instead of double-invalidating
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

  public enum SwitchResult: Sendable, Equatable {
    case ok
    case alreadyThere
    /// Script errored. `code` is the AppleScript error number (-1743 = Automation denied).
    case notPermitted(message: String, code: Int)
    case crossDisplayUnsupported
    case notFound
    case busy
    /// #5: the synthesized shortcut ran without error, but `activeSpaceID()` reported the same
    /// Space after a follow-up read — the WindowServer never honored it. Usually means the
    /// underlying ⌃N / ⌃←/→ "Switch to Desktop" shortcut is disabled or has been rebound in
    /// System Settings ▸ Keyboard ▸ Keyboard Shortcuts.
    case switchDidNotTake
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
    armFastPoll()  // #19: track this switch live for its window, then fall back to idle
    // #5: baseline reading, taken before synthesis, so we can tell after the fact whether the
    // WindowServer actually moved or just silently ate the shortcut.
    let beforeID = api.activeSpaceID()
    onSwitchInitiated?(targetSpace)  // instant HUD — we already know the destination

    let desktopNumber = targetSpace.userIndex + 1
    let singleDisplay = displays.count == 1
    if singleDisplay, desktopNumber <= DesktopShortcuts.maxDirectDesktop,
      DesktopShortcuts.allEnabled(upTo: desktopNumber)
    {
      // One-hop direct jump via ⌃N.
      finishAfterSynthesis(
        keySynth.switchToDesktop(desktopNumber), beforeID: beforeID, completion: completion)
    } else {
      // Walk ⌃←/→ hop-by-hop (multi-display, or beyond ⌃9). Verification must happen once the
      // *whole* walk lands, not after each hop — a mid-walk hop looking unchanged is expected.
      let steps = SwitchPlanner.walk(
        fromIndex: currentSpace.userIndex, toIndex: targetSpace.userIndex)
      execute(steps: steps, index: 0) { [weak self] result in
        guard let self else { return }
        guard case .ok = result else {
          self.finish(result, completion: completion)  // a hop itself errored — nothing to verify
          return
        }
        self.verifyAndFinish(beforeID: beforeID, completion: completion)
      }
    }
  }

  private func finish(_ result: SwitchResult, completion: ((SwitchResult) -> Void)?) {
    isSwitching = false
    refresh()
    completion?(result)
  }

  private func finishAfterSynthesis(
    _ synthResult: Result<Void, KeySynth.SynthError>,
    beforeID: UInt64?,
    completion: ((SwitchResult) -> Void)?
  ) {
    switch synthResult {
    case .success:
      verifyAndFinish(beforeID: beforeID, completion: completion)
    case .failure(.failed(let message, let code)):
      finish(.notPermitted(message: message, code: code), completion: completion)
    case .failure(.compileFailed):
      finish(
        .notPermitted(message: "Could not compile switch script", code: 0), completion: completion)
    }
  }

  /// #5: the script itself reported success — now confirm the WindowServer actually honored it by
  /// re-reading `activeSpaceID()` after `verificationDelay` and comparing against the baseline
  /// taken before synthesis. Not run for `.alreadyThere` (that path returns long before this is
  /// reachable), so a same-Space no-op switch never pays this delay or flips to `.switchDidNotTake`.
  private func verifyAndFinish(beforeID: UInt64?, completion: ((SwitchResult) -> Void)?) {
    guard let beforeID else {
      // No baseline to compare against (private API unavailable) — report success rather than a
      // failure we have no way to actually substantiate.
      finish(.ok, completion: completion)
      return
    }
    scheduleAfterDelay(verificationDelay) { [weak self] in
      guard let self else { return }
      let afterID = self.api.activeSpaceID()
      if let afterID, afterID != beforeID {
        self.finish(.ok, completion: completion)
      } else {
        self.finish(.switchDidNotTake, completion: completion)
      }
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
