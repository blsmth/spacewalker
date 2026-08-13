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
  // Rapid-switch handling: while hammering, blank the HUD and settle on the final Space.
  private var lastRequest = Date.distantPast
  private var debounceWork: DispatchWorkItem?
  private var pending: ResolvedSpace?

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
    let now = Date()
    let rapid = now.timeIntervalSince(lastRequest) < 0.22
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

  /// Hide instantly (no fade) — drops a stale name the moment a switch begins.
  func clear() {
    hideWork?.cancel()
    debounceWork?.cancel()
    panel.alphaValue = 0
    panel.orderOut(nil)
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
    panel.alphaValue = 1  // snap in immediately so it tracks fast switching
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
          // Only finish hiding if a newer flash didn't re-show it.
          if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
        })
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
  }
}
