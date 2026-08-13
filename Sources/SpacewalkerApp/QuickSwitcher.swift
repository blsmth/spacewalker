import AppKit
import SpaceModel
import SpaceService

/// Dark HUD palette: deep purple-black with violet selection and lime accents.
private enum Theme {
  static let base = NSColor(srgbRed: 0.05, green: 0.03, blue: 0.09, alpha: 0.62)  // darken blur
  static let veil = NSColor(srgbRed: 0.20, green: 0.11, blue: 0.34, alpha: 0.30)  // purple wash
  static let border = NSColor(srgbRed: 0.58, green: 0.40, blue: 0.98, alpha: 0.45)  // violet hairline
  static let selection = NSColor(srgbRed: 0.49, green: 0.24, blue: 0.93, alpha: 1.00)  // #7C3AED
  static let textPrimary = NSColor(srgbRed: 0.97, green: 0.96, blue: 1.00, alpha: 1)
  static let textSecondary = NSColor(srgbRed: 0.70, green: 0.65, blue: 0.82, alpha: 1)
  static let lime = NSColor(srgbRed: 0.67, green: 0.93, blue: 0.29, alpha: 1)  // #A3E635
  static let onSelection = NSColor.white

  /// Distinct default dot colors, cycled by Space index, so unstyled Spaces still look intentional.
  static let palette: [NSColor] = [
    NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1),  // violet
    NSColor(srgbRed: 0.67, green: 0.93, blue: 0.29, alpha: 1),  // lime
    NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 1),  // cyan
    NSColor(srgbRed: 0.96, green: 0.45, blue: 0.71, alpha: 1),  // pink
    NSColor(srgbRed: 0.98, green: 0.75, blue: 0.14, alpha: 1),  // amber
    NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1),  // emerald
    NSColor(srgbRed: 0.51, green: 0.55, blue: 0.97, alpha: 1),  // indigo
  ]
  static func dotColor(_ index: Int) -> NSColor { palette[index % palette.count] }
}

/// Borderless floating panel that can take key focus (so we can type-to-filter).
final class QuickSwitcherPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// The ⌘0 Quick Switcher: fuzzy-filter Spaces, pick with number keys / arrows / Return, Esc to
/// dismiss. Thin over `SpaceService` — it renders `allSpaces` and calls `switchTo`.
@MainActor
final class QuickSwitcherController: NSObject, NSWindowDelegate {

  private let service: SpaceService
  private let panel: QuickSwitcherPanel
  private let switcher = SwitcherView()
  private let effect = NSVisualEffectView()
  private var keyMonitor: Any?

  private let width: CGFloat = 460

  init(service: SpaceService) {
    self.service = service
    // NOT .nonactivatingPanel: the switcher must take keyboard focus every time it opens, even
    // when another app is frontmost on the Space we just landed on. Otherwise the key monitor
    // (which only sees events while our app is active) goes silent after the first switch.
    panel = QuickSwitcherPanel(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
      styleMask: [.borderless],
      backing: .buffered, defer: true)
    super.init()

    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovable = false
    panel.delegate = self
    panel.appearance = NSAppearance(named: .darkAqua)

    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.translatesAutoresizingMaskIntoConstraints = false

    // Darken the blur, then a purple wash on top → deep, clean, Mac-like.
    let base = NSView()
    base.wantsLayer = true
    base.layer?.backgroundColor = Theme.base.cgColor
    base.translatesAutoresizingMaskIntoConstraints = false

    let veil = NSView()
    veil.wantsLayer = true
    veil.layer?.backgroundColor = Theme.veil.cgColor
    veil.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.wantsLayer = true
    content.layer?.cornerRadius = 22
    content.layer?.masksToBounds = true
    content.layer?.borderWidth = 1
    content.layer?.borderColor = Theme.border.cgColor
    switcher.translatesAutoresizingMaskIntoConstraints = false
    for v in [effect, base, veil, switcher] { content.addSubview(v) }
    for v in [effect, base, veil, switcher] {
      NSLayoutConstraint.activate([
        v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        v.topAnchor.constraint(equalTo: content.topAnchor),
        v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      ])
    }
    panel.contentView = content

    switcher.onPick = { [weak self] space in self?.pick(space) }
    switcher.onDismiss = { [weak self] in self?.hide() }
  }

  func toggle() { panel.isVisible ? hide() : show() }

  func show() {
    layoutContent()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(switcher)

    // Drive all key handling from a local monitor rather than the responder chain — this
    // reliably captures 1–9/arrows/Return/typing for a HUD panel and never system-beeps.
    if keyMonitor == nil {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        let handled = MainActor.assumeIsolated { self.switcher.handleKey(event) }
        return handled ? nil : event
      }
    }

    // First open after launch can race the WindowServer and come up empty — re-read and
    // repopulate the (already visible) panel instead of making the user close/reopen.
    retryIfEmpty(attempt: 0)
  }

  /// Refresh state and (re)lay out the switcher content + panel frame.
  private func layoutContent() {
    service.refresh()
    let height = switcher.configure(
      spaces: service.allSpaces,
      currentKey: service.current?.id,
      width: width)
    if let screen = NSScreen.main {
      let f = screen.visibleFrame
      let origin = NSPoint(x: f.midX - width / 2, y: f.midY - height / 2 + f.height * 0.12)
      panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
    }
  }

  private func retryIfEmpty(attempt: Int) {
    guard service.allSpaces.isEmpty, attempt < 6 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self, self.panel.isVisible else { return }
      self.layoutContent()
      self.panel.makeFirstResponder(self.switcher)
      self.retryIfEmpty(attempt: attempt + 1)
    }
  }

  func hide() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    panel.orderOut(nil)
  }

  private func pick(_ space: ResolvedSpace) {
    let key = space.id
    hide()
    // Yield focus back and let the transition settle before firing ⌃N — a shortcut synthesized
    // while our app is grabbing focus gets dropped by the WindowServer.
    NSApp.deactivate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      self?.service.switchTo(key: key) { _ in }
    }
  }

  // Dismiss when focus is lost (click elsewhere, another app).
  func windowDidResignKey(_ notification: Notification) { hide() }
}

// MARK: - The key-driven list view

private final class SwitcherView: NSView {

  var onPick: ((ResolvedSpace) -> Void)?
  var onDismiss: (() -> Void)?

  private var all: [ResolvedSpace] = []
  private var filtered: [ResolvedSpace] = []
  private var currentKey: String?
  private var query = ""
  private var selection = 0
  private var contentWidth: CGFloat = 460  // known panel width; bounds isn't laid out on first show

  private let searchIcon = NSImageView()
  private let queryLabel = NSTextField(labelWithString: "")
  private let divider = NSView()
  private let stack = NSStackView()
  private let footer = NSTextField(labelWithString: "")

  private let rowHeight: CGFloat = 46
  private let rowGap: CGFloat = 4
  private let headerHeight: CGFloat = 62
  private let footerHeight: CGFloat = 34
  private let hInset: CGFloat = 20
  private let sideInset: CGFloat = 12  // rows/selection float inside this margin

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    let glyph = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
    searchIcon.image = glyph?.withSymbolConfiguration(
      .init(pointSize: 16, weight: .bold).applying(.init(paletteColors: [Theme.lime])))
    searchIcon.translatesAutoresizingMaskIntoConstraints = false

    queryLabel.font = .systemFont(ofSize: 19, weight: .medium)
    queryLabel.textColor = Theme.textSecondary
    queryLabel.translatesAutoresizingMaskIntoConstraints = false
    queryLabel.lineBreakMode = .byTruncatingTail

    divider.wantsLayer = true
    divider.layer?.backgroundColor = Theme.border.withAlphaComponent(0.30).cgColor
    divider.translatesAutoresizingMaskIntoConstraints = false

    stack.orientation = .vertical
    stack.spacing = rowGap
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false

    footer.font = .systemFont(ofSize: 11, weight: .medium)
    footer.textColor = Theme.textSecondary.withAlphaComponent(0.85)
    footer.attributedStringValue = footerHint()
    footer.translatesAutoresizingMaskIntoConstraints = false

    addSubview(searchIcon)
    addSubview(queryLabel)
    addSubview(divider)
    addSubview(stack)
    addSubview(footer)
    NSLayoutConstraint.activate([
      searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hInset),
      searchIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: 32),
      queryLabel.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12),
      queryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hInset),
      queryLabel.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hInset),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hInset),
      divider.topAnchor.constraint(equalTo: topAnchor, constant: headerHeight - 10),
      divider.heightAnchor.constraint(equalToConstant: 1),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: headerHeight),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideInset),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideInset),
      footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hInset),
      footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
    ])
  }

  /// "↑↓ navigate   ⏎ switch   1–9 jump   esc close" with lime keycaps.
  private func footerHint() -> NSAttributedString {
    let s = NSMutableAttributedString()
    let pairs = [("↑↓", "navigate"), ("⏎", "switch"), ("1–9", "jump"), ("esc", "close")]
    for (i, pair) in pairs.enumerated() {
      s.append(
        NSAttributedString(
          string: pair.0,
          attributes: [
            .foregroundColor: Theme.lime,
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
          ]))
      s.append(
        NSAttributedString(
          string: " \(pair.1)",
          attributes: [
            .foregroundColor: Theme.textSecondary.withAlphaComponent(0.85),
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
          ]))
      if i < pairs.count - 1 {
        s.append(NSAttributedString(string: "    "))
      }
    }
    return s
  }

  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }

  /// Load spaces, reset query, default selection to the first non-current Space. Returns the
  /// panel height to use.
  func configure(spaces: [ResolvedSpace], currentKey: String?, width: CGFloat) -> CGFloat {
    all = spaces
    self.currentKey = currentKey
    contentWidth = width
    query = ""
    filtered = spaces
    selection = spaces.firstIndex { $0.id != currentKey } ?? 0
    render()
    let rows = max(1, filtered.count)
    return headerHeight + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap + footerHeight
  }

  override func keyDown(with event: NSEvent) {
    _ = handleKey(event)  // fallback; primary path is the controller's local monitor
  }

  /// Handle a key event. Returns true if consumed (so the monitor swallows it).
  func handleKey(_ event: NSEvent) -> Bool {
    // Ignore anything with command/control/option — let ⌘0 toggle etc. pass through.
    if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }

    switch Int(event.keyCode) {
    case 53:
      onDismiss?()
      return true  // esc
    case 36, 76:
      pickSelected()
      return true  // return / enter
    case 125:
      move(1)
      return true  // down
    case 126:
      move(-1)
      return true  // up
    case 51:  // delete
      if !query.isEmpty {
        query.removeLast()
        selection = 0
        rebuild()
      }
      return true
    default:
      guard let chars = event.charactersIgnoringModifiers, let c = chars.first, chars.count == 1
      else { return false }
      if let digit = c.wholeNumberValue, (1...9).contains(digit) {
        if digit - 1 < filtered.count { onPick?(filtered[digit - 1]) }
        return true
      } else if c.isLetter || c == " " || c == "-" || c == "_" {
        query.append(c)
        selection = 0
        rebuild()
        return true
      }
      return false
    }
  }

  private func move(_ delta: Int) {
    guard !filtered.isEmpty else { return }
    selection = max(0, min(filtered.count - 1, selection + delta))
    render()
  }

  private func pickSelected() {
    guard filtered.indices.contains(selection) else { return }
    onPick?(filtered[selection])
  }

  private func rebuild() {
    filtered = FuzzyMatch.rank(all, query: query, name: { $0.displayName })
    if selection >= filtered.count { selection = max(0, filtered.count - 1) }
    render()
  }

  private func render() {
    queryLabel.stringValue = query.isEmpty ? "Jump to a Space…" : query
    queryLabel.textColor = query.isEmpty ? Theme.textSecondary : Theme.textPrimary

    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if filtered.isEmpty {
      let empty = NSTextField(labelWithString: "No matching Space")
      empty.font = .systemFont(ofSize: 14)
      empty.textColor = Theme.textSecondary
      stack.addArrangedSubview(empty)
      return
    }
    for (i, space) in filtered.enumerated() {
      stack.addArrangedSubview(makeRow(index: i, space: space, selected: i == selection))
    }
  }

  private func makeRow(index: Int, space: ResolvedSpace, selected: Bool) -> NSView {
    let row = NSView()
    row.wantsLayer = true
    row.layer?.cornerRadius = 12
    row.layer?.backgroundColor = selected ? Theme.selection.cgColor : NSColor.clear.cgColor
    row.translatesAutoresizingMaskIntoConstraints = false
    row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
    row.widthAnchor.constraint(equalToConstant: contentWidth - sideInset * 2).isActive = true

    // Soft violet glow on the selected pill.
    if selected {
      row.layer?.masksToBounds = false
      row.layer?.shadowColor = Theme.selection.cgColor
      row.layer?.shadowOpacity = 0.55
      row.layer?.shadowRadius = 10
      row.layer?.shadowOffset = .zero

      let accent = NSView()
      accent.wantsLayer = true
      accent.layer?.cornerRadius = 2
      accent.layer?.backgroundColor = Theme.lime.cgColor
      accent.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(accent)
      NSLayoutConstraint.activate([
        accent.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
        accent.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        accent.widthAnchor.constraint(equalToConstant: 4),
        accent.heightAnchor.constraint(equalToConstant: 22),
      ])
    }

    let nameColor: NSColor = selected ? Theme.onSelection : Theme.textPrimary

    // Number badge (lime), 1–9 then "·".
    let badge = NSTextField(labelWithString: index < 9 ? "\(index + 1)" : "·")
    badge.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    badge.textColor = Theme.lime
    badge.alignment = .center

    // Optional per-Space glyph tinted with its color (falls back to a color dot, else nothing).
    let icon = iconView(for: space, selected: selected)

    let name = NSTextField(labelWithString: space.displayName)
    name.font = .systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
    name.textColor = nameColor
    name.lineBreakMode = .byTruncatingTail

    // Lime "current" dot on the trailing edge.
    let currentDot = NSView()
    currentDot.wantsLayer = true
    currentDot.layer?.cornerRadius = 4
    currentDot.layer?.backgroundColor =
      (space.id == currentKey ? Theme.lime : NSColor.clear).cgColor

    for v in [badge, icon, name, currentDot] {
      v.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(v)
    }
    NSLayoutConstraint.activate([
      badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
      badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      badge.widthAnchor.constraint(equalToConstant: 16),

      icon.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      icon.heightAnchor.constraint(equalToConstant: 18),

      name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      name.trailingAnchor.constraint(lessThanOrEqualTo: currentDot.leadingAnchor, constant: -8),

      currentDot.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
      currentDot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      currentDot.widthAnchor.constraint(equalToConstant: 8),
      currentDot.heightAnchor.constraint(equalToConstant: 8),
    ])
    return row
  }

  /// SF Symbol tinted with the Space's color if set; else a filled color dot (user color, or a
  /// palette default cycled by index so every Space looks intentional).
  private func iconView(for space: ResolvedSpace, selected: Bool) -> NSView {
    let color =
      space.metadata?.colorHex.flatMap(NSColor.init(hex:)) ?? Theme.dotColor(space.userIndex)
    if let symbolName = space.metadata?.symbolName,
      let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    {
      let iv = NSImageView()
      iv.image = image.withSymbolConfiguration(
        .init(paletteColors: [selected ? Theme.onSelection : color]))
      iv.imageScaling = .scaleProportionallyUpOrDown
      return iv
    }
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 5
    dot.layer?.backgroundColor = color.cgColor
    if selected {
      dot.layer?.borderWidth = 1.5
      dot.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    }
    // Center the bare dot within its 18pt slot.
    let holder = NSView()
    dot.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(dot)
    NSLayoutConstraint.activate([
      dot.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
      dot.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 10),
      dot.heightAnchor.constraint(equalToConstant: 10),
    ])
    return holder
  }
}
