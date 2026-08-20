import AppKit
import SpaceModel
import SpaceService

/// Dark HUD palette: deep purple-black with violet selection and lime accents.
private enum Theme {
  static let base = NSColor(srgbRed: 0.05, green: 0.03, blue: 0.09, alpha: 0.62)  // darken blur
  static let veil = NSColor(srgbRed: 0.20, green: 0.11, blue: 0.34, alpha: 0.30)  // purple wash
  // violet hairline
  static let border = NSColor(srgbRed: 0.58, green: 0.40, blue: 0.98, alpha: 0.45)
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

/// Pure geometry for the switcher panel's height clamp and its row list's scroll-into-view
/// behaviour. Kept free of AppKit so it's unit-testable without a live panel — see issue #29:
/// macOS allows 16 desktops per display, and across two displays `allSpaces` can flatten to 32
/// rows, far taller than any screen.
enum QuickSwitcherGeometry {

  /// Natural (unclamped) content height for `rows` rows, clamped to `maxHeight`. Never returns
  /// less than enough room for one row, so a pathologically small `maxHeight` still yields a
  /// usable panel rather than a zero-height one.
  static func panelHeight(
    rows: Int,
    headerHeight: CGFloat,
    footerHeight: CGFloat,
    rowHeight: CGFloat,
    rowGap: CGFloat,
    maxHeight: CGFloat
  ) -> CGFloat {
    let rows = max(1, rows)
    let natural =
      headerHeight + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap + footerHeight
    let minimum = headerHeight + rowHeight + footerHeight
    return min(natural, max(minimum, maxHeight))
  }

  /// Top-down (document-space, y grows downward) offset of row `index`'s top edge.
  static func rowTop(_ index: Int, rowHeight: CGFloat, rowGap: CGFloat) -> CGFloat {
    CGFloat(index) * (rowHeight + rowGap)
  }

  /// The minimal-scroll offset (top-down, document space) that brings row `index` fully into a
  /// viewport of `visibleHeight` starting at `currentOffset`. Scrolls up if the row is above the
  /// viewport, down if it's below, and leaves the offset untouched if the row is already fully
  /// visible — so repeated calls while the selection stays put never jitter the scroll position.
  /// The result is clamped to the valid scroll range for `rowCount` total rows.
  static func scrollOffset(
    toReveal index: Int,
    rowCount: Int,
    rowHeight: CGFloat,
    rowGap: CGFloat,
    visibleHeight: CGFloat,
    currentOffset: CGFloat
  ) -> CGFloat {
    guard rowCount > 0, visibleHeight > 0 else { return 0 }
    let top = rowTop(index, rowHeight: rowHeight, rowGap: rowGap)
    let bottom = top + rowHeight
    let totalHeight = CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * rowGap
    let maxOffset = max(0, totalHeight - visibleHeight)

    var offset = currentOffset
    if top < offset {
      offset = top
    } else if bottom > offset + visibleHeight {
      offset = bottom - visibleHeight
    }
    return min(max(0, offset), maxOffset)
  }

  /// Frame for a `width` x `height` panel, biased upward within `visibleFrame` by `verticalBias`
  /// (a fraction of the screen height) for a more pleasing position than dead-center — but always
  /// fully contained in `visibleFrame`, even when a tall (clamped) panel would otherwise push the
  /// biased top edge past the screen's top edge. This supersedes hand-tuning the bias against the
  /// height clamp fraction: a frame clamp is robust by construction, where tuned constants drift
  /// the moment either one changes.
  static func panelFrame(
    width: CGFloat,
    height: CGFloat,
    visibleFrame: NSRect,
    verticalBias: CGFloat
  ) -> NSRect {
    let x = visibleFrame.midX - width / 2
    let y = visibleFrame.midY - height / 2 + visibleFrame.height * verticalBias
    return clamped(NSRect(x: x, y: y, width: width, height: height), into: visibleFrame)
  }

  /// Translates `frame` by the minimal amount needed to fit entirely within `bounds`. If `frame`
  /// is larger than `bounds` along an axis, it's pinned to `bounds`'s minimum edge on that axis —
  /// there's no translation that fits it either way, so there's nothing better to do.
  private static func clamped(_ frame: NSRect, into bounds: NSRect) -> NSRect {
    var origin = frame.origin

    let overflowRight = frame.maxX - bounds.maxX
    if overflowRight > 0 { origin.x -= overflowRight }
    if origin.x < bounds.minX { origin.x = bounds.minX }

    let overflowTop = frame.maxY - bounds.maxY
    if overflowTop > 0 { origin.y -= overflowTop }
    if origin.y < bounds.minY { origin.y = bounds.minY }

    return NSRect(origin: origin, size: frame.size)
  }
}

/// The ⌘0 Quick Switcher: fuzzy-filter Spaces, pick with number keys / arrows / Return, Esc to
/// dismiss. Thin over `SpaceService` — it renders `allSpaces` and calls `switchTo`.
@MainActor
final class QuickSwitcherController: NSObject, NSWindowDelegate {

  /// #29: the panel's row list can be far taller than any screen (16 desktops/display, 2
  /// displays flatten to 32 rows in `allSpaces`), so its height is clamped to a fraction of the
  /// screen and the excess scrolls.
  private enum Constants {
    static let heightClampFraction: CGFloat = 0.8
    static let fallbackScreenHeight: CGFloat = 900
    /// Upward bias, as a fraction of screen height, applied to the panel's centered position —
    /// purely cosmetic (dead-center reads a touch low). `QuickSwitcherGeometry.panelFrame` clamps
    /// the biased frame into `visibleFrame`, so this can't push a tall panel off-screen.
    static let verticalBias: CGFloat = 0.12
  }

  private let service: SpaceService
  private let panel: QuickSwitcherPanel
  private let switcher = SwitcherView()
  private let effect = NSVisualEffectView()
  private var keyMonitor: Any?

  /// #3: reports the outcome of a switch triggered by picking a row. The panel itself has no error
  /// UI (it's usually already hidden by the time the result arrives, per the focus-yield delay in
  /// `pick`), so the app delegate is responsible for surfacing failures.
  var onSwitchResult: ((SpaceService.SwitchResult, String) -> Void)?

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
    let screen = NSScreen.main
    let screenHeight = screen?.visibleFrame.height ?? Constants.fallbackScreenHeight
    let maxHeight = screenHeight * Constants.heightClampFraction
    let height = switcher.configure(
      spaces: service.allSpaces,
      currentKey: service.current?.id,
      width: width,
      maxHeight: maxHeight)
    if let screen {
      let frame = QuickSwitcherGeometry.panelFrame(
        width: width, height: height, visibleFrame: screen.visibleFrame,
        verticalBias: Constants.verticalBias)
      panel.setFrame(frame, display: true)
    }
    // The row list's scroll view only has its final bounds after the frame above is applied, so
    // the initial scroll-to-selection has to happen after — a no-op call from inside `configure`
    // would see a stale (or zero) height.
    switcher.scrollSelectionIntoView()
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
      self?.service.switchTo(key: key) { [weak self] result in
        self?.onSwitchResult?(result, key)
      }
    }
  }

  // Dismiss when focus is lost (click elsewhere, another app).
  func windowDidResignKey(_ notification: Notification) { hide() }
}

/// Keeps document-space offset `0` at the top of the row list instead of AppKit's default
/// bottom-left origin, so `QuickSwitcherGeometry`'s top-down scroll math applies directly.
private final class FlippedClipView: NSClipView {
  override var isFlipped: Bool { true }
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
  // Known panel width; bounds isn't laid out on first show.
  private var contentWidth: CGFloat = 460

  private let searchIcon = NSImageView()
  private let queryLabel = NSTextField(labelWithString: "")
  private let divider = NSView()
  private let stack = NSStackView()
  private let scrollView = NSScrollView()
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

    // #29: rows no longer grow the panel without bound — the row list scrolls once the panel
    // height is clamped. A flipped clip view keeps document-space offset 0 at the top, matching
    // the top-down math in `QuickSwitcherGeometry`.
    let clipView = FlippedClipView()
    clipView.drawsBackground = false
    scrollView.contentView = clipView
    scrollView.documentView = stack
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    footer.font = .systemFont(ofSize: 11, weight: .medium)
    footer.textColor = Theme.textSecondary.withAlphaComponent(0.85)
    footer.attributedStringValue = footerHint()
    footer.translatesAutoresizingMaskIntoConstraints = false

    addSubview(searchIcon)
    addSubview(queryLabel)
    addSubview(divider)
    addSubview(scrollView)
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
      scrollView.topAnchor.constraint(equalTo: topAnchor, constant: headerHeight),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideInset),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideInset),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -footerHeight),
      stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
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
  /// panel height to use, clamped to `maxHeight` — see `QuickSwitcherGeometry`. Callers must
  /// still call `scrollSelectionIntoView()` once the panel has actually been resized to that
  /// height, since the row list's scroll view has no reliable bounds until then.
  func configure(spaces: [ResolvedSpace], currentKey: String?, width: CGFloat, maxHeight: CGFloat)
    -> CGFloat
  {
    all = spaces
    self.currentKey = currentKey
    contentWidth = width
    query = ""
    filtered = spaces
    selection = spaces.firstIndex { $0.id != currentKey } ?? 0
    render()
    return QuickSwitcherGeometry.panelHeight(
      rows: filtered.count, headerHeight: headerHeight, footerHeight: footerHeight,
      rowHeight: rowHeight, rowGap: rowGap, maxHeight: maxHeight)
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
    scrollSelectionIntoView()
  }

  private func pickSelected() {
    guard filtered.indices.contains(selection) else { return }
    onPick?(filtered[selection])
  }

  private func rebuild() {
    filtered = FuzzyMatch.rank(all, query: query, name: { $0.displayName })
    if selection >= filtered.count { selection = max(0, filtered.count - 1) }
    render()
    scrollSelectionIntoView()
  }

  /// #29: bring the current selection into view, scrolling as little as possible. A no-op until
  /// the panel has a real size (`visibleHeight` is 0 on the very first `configure`, before the
  /// controller has resized the panel) — the controller calls this again once it has.
  func scrollSelectionIntoView() {
    guard filtered.indices.contains(selection) else { return }
    layoutSubtreeIfNeeded()
    let visibleHeight = scrollView.contentView.bounds.height
    let currentOffset = scrollView.contentView.bounds.origin.y
    let target = QuickSwitcherGeometry.scrollOffset(
      toReveal: selection, rowCount: filtered.count, rowHeight: rowHeight, rowGap: rowGap,
      visibleHeight: visibleHeight, currentOffset: currentOffset)
    guard target != currentOffset else { return }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func render() {
    queryLabel.stringValue = query.isEmpty ? "Jump to a Space…" : query
    queryLabel.textColor = query.isEmpty ? Theme.textSecondary : Theme.textPrimary

    for view in stack.arrangedSubviews { view.removeFromSuperview() }
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

    // Number badge (lime): the row's position. Only 1–9 double as a jump-key shortcut (see
    // `handleKey`) — rows 10+ show their position too (issue #29: with the scroll view they're
    // now always reachable by arrow key, so a bare "·" for those rows would be a step backwards).
    let badge = NSTextField(labelWithString: "\(index + 1)")
    badge.font = .monospacedDigitSystemFont(ofSize: index < 9 ? 13 : 11, weight: .bold)
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
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),

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
