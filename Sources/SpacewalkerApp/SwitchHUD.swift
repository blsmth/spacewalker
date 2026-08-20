import AppKit
import SpaceModel

/// A brief, centered heads-up flash naming the Space you just switched to — like the macOS
/// volume/brightness HUD. Transparent, click-through, joins all Spaces so it rides along.
@MainActor
final class SwitchHUD {

  private let panel: NSPanel
  private let iconDot = NSView()
  private let iconImage = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private var hideWork: DispatchWorkItem?
  /// Bumped every `present()`; lets a stale fade's completion handler tell it's been superseded
  /// and must not `orderOut` a newer flash it knows nothing about. See `FadeGenerationTracker`
  /// (SwitchHUDTiming.swift) for the pure decision logic this delegates to, and
  /// `SwitchHUDTimingTests`/`FadeGenerationTrackerTests` for its coverage.
  private var fadeGeneration = FadeGenerationTracker()
  // Rapid-switch handling: while hammering, blank the HUD and settle on the final Space.
  private var lastRequest = Date.distantPast
  private var debounceWork: DispatchWorkItem?
  private var pending: ResolvedSpace?
  /// When the most recent flash was *requested* (`CACurrentMediaTime()`, the same clock as
  /// `NSEvent.timestamp`) — lets `clearIfStale` tell whether a key event predates or postdates
  /// the freshest thing we've shown.
  private var lastFlashRequestedAt: TimeInterval = 0

  // Palette (shared spirit with the switcher).
  private static let bg = NSColor(srgbRed: 0.06, green: 0.04, blue: 0.10, alpha: 0.90)
  private static let border = NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 0.55)
  private static let text = NSColor(srgbRed: 0.97, green: 0.96, blue: 1.0, alpha: 1)
  private static let lime = NSColor(srgbRed: 0.67, green: 0.93, blue: 0.29, alpha: 1)

  init() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 96),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    panel.level = .screenSaver
    panel.isFloatingPanel = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
    ]
    panel.alphaValue = 0

    let card = NSView()
    card.wantsLayer = true
    card.layer?.backgroundColor = Self.bg.cgColor
    card.layer?.cornerRadius = 22
    card.layer?.borderWidth = 1
    card.layer?.borderColor = Self.border.cgColor
    card.translatesAutoresizingMaskIntoConstraints = false

    iconDot.wantsLayer = true
    iconDot.layer?.cornerRadius = 9
    iconDot.translatesAutoresizingMaskIntoConstraints = false
    iconImage.translatesAutoresizingMaskIntoConstraints = false

    label.font = .systemFont(ofSize: 22, weight: .semibold)
    label.textColor = Self.text
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail

    let stack = NSStackView(views: [iconDot, iconImage, label])
    stack.orientation = .horizontal
    stack.spacing = 12
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false

    card.addSubview(stack)
    NSLayoutConstraint.activate([
      iconDot.widthAnchor.constraint(equalToConstant: 18),
      iconDot.heightAnchor.constraint(equalToConstant: 18),
      iconImage.widthAnchor.constraint(equalToConstant: 24),
      iconImage.heightAnchor.constraint(equalToConstant: 24),
      stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 26),
    ])
    panel.contentView = card
  }

  func flash(_ space: ResolvedSpace) {
    lastFlashRequestedAt = CACurrentMediaTime()
    let now = Date()
    let rapid = SwitchHUDTiming.isRapidSuccession(now: now, previousRequestAt: lastRequest)
    lastRequest = now
    debounceWork?.cancel()

    if rapid {
      // Hammering: drop the stale previous name instantly, then show only the Space we settle
      // on once switching pauses.
      pending = space
      clear()
      let work = DispatchWorkItem { [weak self] in
        guard let self, let latest = self.pending else { return }
        self.showSpace(latest)
      }
      debounceWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
    } else {
      showSpace(space)
    }
  }

  private func showSpace(_ space: ResolvedSpace) {
    let color = space.metadata?.colorHex.flatMap(NSColor.init(hex:)) ?? Self.lime
    if let symbol = space.metadata?.symbolName,
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    {
      iconImage.image = image.withSymbolConfiguration(.init(paletteColors: [color]))
      iconImage.isHidden = false
      iconDot.isHidden = true
    } else {
      iconDot.layer?.backgroundColor = color.cgColor
      iconDot.isHidden = false
      iconImage.isHidden = true
    }
    label.stringValue = space.displayName
    present()
  }

  /// Hide instantly (no fade) — drops a stale name the moment a switch begins. Unconditional:
  /// callers must know the displayed content is actually stale. External, async-delivered
  /// triggers should use `clearIfStale` instead.
  func clear() {
    hideWork?.cancel()
    debounceWork?.cancel()
    panel.alphaValue = 0
    panel.orderOut(nil)
  }

  /// Like `clear()`, but only actually clears if nothing newer has already arrived.
  ///
  /// The global keyDown monitor that drives this is delivered asynchronously and can lag behind
  /// the 30ms active-Space poll — if the poll already detected the switch and flashed the
  /// destination *before* this call runs, an unconditional `clear()` would wipe that correct,
  /// fresher HUD. `eventTimestamp` (from `NSEvent.timestamp`, which shares `CACurrentMediaTime()`'s
  /// clock) lets us tell the two cases apart by real event ordering rather than by execution
  /// order: a flash can only exist because of a key event that happened before it, so if the
  /// last flash was requested at or after this event, it must belong to this switch (or a later
  /// one) and must be left alone.
  func clearIfStale(asOf eventTimestamp: TimeInterval) {
    guard
      SwitchHUDTiming.isClearStillValid(
        lastFlashRequestedAt: lastFlashRequestedAt, eventTimestamp: eventTimestamp)
    else { return }
    clear()
  }

  /// Text-only flash (used by spikes for quick feedback).
  func flashMessage(_ text: String) {
    iconDot.isHidden = true
    iconImage.isHidden = true
    label.stringValue = text
    present()
  }

  private func present() {
    panel.layoutIfNeeded()
    let fit = panel.contentView!.fittingSize
    let w = max(220, fit.width + 60)
    let h: CGFloat = 92
    if let screen = NSScreen.main {
      let f = screen.frame
      // Eye level: vertically centered, nudged slightly above the midline.
      panel.setFrame(
        NSRect(x: f.midX - w / 2, y: f.midY - h / 2 + f.height * 0.08, width: w, height: h),
        display: true)
    }

    hideWork?.cancel()
    let generation = fadeGeneration.advance()

    // `hideWork?.cancel()` above only stops a *pending* fade from starting — if a previous fade
    // is already in flight (its hideWork already fired), cancelling is a no-op and a bare
    // `panel.alphaValue = 1` doesn't stop it either: the animator keeps interpolating alpha back
    // toward 0 on its own schedule regardless of what we assign directly, so this new flash would
    // silently fade back out underneath us. Starting a fresh zero-duration animation on the same
    // property supersedes whatever animation was running, snapping us back to fully visible.
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0
      panel.animator().alphaValue = 1
    }
    panel.orderFrontRegardless()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      NSAnimationContext.runAnimationGroup(
        { ctx in
          ctx.duration = 0.55
          ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
          self.panel.animator().alphaValue = 0
        },
        completionHandler: { [weak self] in
          // Guard with the generation token, not just alphaValue: a newer flash may have
          // re-shown the panel and started its *own* fade, which could coincidentally also land
          // on alpha 0 by the time this stale completion runs. Only the fade that's still the
          // current one is allowed to order the panel out.
          guard let self, self.fadeGeneration.isCurrent(generation) else { return }
          if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
        })
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
  }
}
