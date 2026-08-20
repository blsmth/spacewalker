#!/usr/bin/env swift
//
// generate-icon.swift — renders Spacewalker's 1024x1024 master app icon.
//
// Issue #58: the icon derives from the SF Symbol vocabulary the status item already renders
// (see `symbolImage(for:)` in Sources/SpacewalkerApp/AppDelegate.swift) — "square.on.square" is
// the neutral default shown when a Space has no custom symbol, so it's the honest "this is a
// Space" glyph rather than a one-off pick. The violet is `Theme.selection` (#7C3AED), the same
// accent used by the Quick Switcher / HUD (see QuickSwitcher.swift's private `Theme` enum) — the
// menu-bar identity and the app identity should read as the same product.
//
// Deliberately a standalone script (not a SwiftPM target): it only needs to run once per icon
// change, has no need for tests, and this way `swift scripts/generate-icon.swift` requires no
// build step. Run via scripts/make-icon.sh, which wraps this with the sips/iconutil pipeline —
// that script is the one-command entry point; this one just draws.
//
// Usage: swift scripts/generate-icon.swift <output-1024.png>

import AppKit
import CoreGraphics
import Foundation

enum Constants {
  /// Master canvas size. macOS then downsamples via `sips` for every other iconset slot.
  static let canvasSize: CGFloat = 1024
  /// macOS Big Sur+ icons are a rounded rect, not full-bleed — this radius (~18% of canvas)
  /// matches Apple's own template proportions closely enough without needing the exact
  /// continuous-curvature superellipse math Apple's Icon Composer uses internally.
  static let cornerRadius: CGFloat = 184
  /// SF Symbol point size, chosen so the glyph's bounding box lands inside the "middle 80%"
  /// content-inset convention for macOS icons once symbol padding is accounted for.
  static let symbolPointSize: CGFloat = 560
  static let symbolWeight = NSFont.Weight.regular

  // Theme.selection (#7C3AED) — QuickSwitcher.swift's private Theme enum.
  static let accentTop = NSColor(srgbRed: 0.62, green: 0.42, blue: 0.98, alpha: 1)
  static let accentBottom = NSColor(srgbRed: 0.42, green: 0.20, blue: 0.82, alpha: 1)
  static let glyphColor = NSColor.white
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write("✗ \(message)\n".data(using: .utf8)!)
  exit(1)
}

guard CommandLine.arguments.count == 2 else {
  fail("usage: generate-icon.swift <output-1024.png>")
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let size = Constants.canvasSize
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
  fail("no CGContext available")
}

// Background: rounded-rect ("squircle") filled with a top-to-bottom violet gradient, matching
// the app's Quick Switcher / HUD accent rather than a flat fill.
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let backgroundPath = NSBezierPath(
  roundedRect: bounds, xRadius: Constants.cornerRadius, yRadius: Constants.cornerRadius)
context.saveGState()
backgroundPath.addClip()
let gradient = NSGradient(starting: Constants.accentTop, ending: Constants.accentBottom)
gradient?.draw(in: bounds, angle: 270)  // top -> bottom
context.restoreGState()

// Foreground glyph: the filled variant of "square.on.square", the same glyph family the status
// item falls back to when a Space has no custom symbol (AppDelegate.symbolImage(for:)). The
// outline form that the menu bar renders reads fine at menu-bar scale but its thin strokes
// smear into a blur once downsampled to a 16pt app icon; the filled variant keeps two legible
// solid squares at every size while still being the same symbol family.
guard
  let symbol = NSImage(
    systemSymbolName: "square.on.square.fill", accessibilityDescription: "Spacewalker")
else {
  fail("could not resolve SF Symbol 'square.on.square.fill'")
}
// NOTE: chaining two `withSymbolConfiguration` calls (size, then palette color) silently
// resets the image back to its unconfigured base size — the second call's configuration wins
// outright rather than merging. `applying(_:)` combines both into one configuration so size and
// color both take effect.
let sizeConfig = NSImage.SymbolConfiguration(
  pointSize: Constants.symbolPointSize, weight: Constants.symbolWeight)
let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [Constants.glyphColor])
guard let configured = symbol.withSymbolConfiguration(sizeConfig.applying(paletteConfig)) else {
  fail("could not configure SF Symbol")
}

let glyphSize = configured.size
let glyphOrigin = CGPoint(x: (size - glyphSize.width) / 2, y: (size - glyphSize.height) / 2)
configured.draw(
  in: CGRect(origin: glyphOrigin, size: glyphSize),
  from: .zero, operation: .sourceOver, fraction: 1)

image.unlockFocus()

guard
  let tiffData = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiffData),
  let pngData = bitmap.representation(using: .png, properties: [:])
else {
  fail("could not encode PNG")
}

do {
  try pngData.write(to: outputURL)
} catch {
  fail("could not write \(outputURL.path): \(error)")
}

print("✓ \(outputURL.path)")
