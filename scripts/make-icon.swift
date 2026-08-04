#!/usr/bin/env swift
// Draws the app icon and writes an .iconset, ready for `iconutil`.
//
// The mark is the product: a midnight tile with the notch cut out of its top
// edge, plus the panel hanging beneath it. Per the Xinori design system the app
// tile uses a 22% corner radius — "dat is het logo, geen UI" — so that is the
// one place the 4/8px radius scale does not apply.

import AppKit
import CoreGraphics
import Foundation

let midnight = CGColor(red: 0.059, green: 0.071, blue: 0.098, alpha: 1)   // #0F1219
let ink = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size / 1024
    guard let context = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons sit in a ~82% safe area; filling the full square makes the
    // app look oversized next to every system icon in the Dock.
    let inset = 92 * scale
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    // Light tile, dark mark — the inverse of the earlier drafts.
    //
    // On screen the notch is a *dark shape on a bright display*, and drawing it
    // that way is both truthful and legible: a dark subject on a light field
    // reads as the figure, where a light card on a midnight tile kept reading
    // as a box with ears.
    context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.22,
                           cornerHeight: tile.width * 0.22, transform: nil))
    context.setFillColor(ink)
    context.fillPath()

    context.setFillColor(midnight)

    // The mark is one silhouette in two parts: the notch flush with the top
    // edge, flaring into the panel it springs into. Drawn as two overlapping
    // rounded rects — their union is the shape, and it stays crisp at 16pt
    // where a hand-built path with fillets turns to mush.
    let notchWidth = tile.width * 0.26
    let notchBottom = tile.maxY - tile.height * 0.15
    let notch = CGRect(x: tile.midX - notchWidth / 2, y: notchBottom,
                       width: notchWidth, height: tile.maxY - notchBottom)
    context.addPath(CGPath(roundedRect: notch, cornerWidth: notchWidth * 0.22,
                           cornerHeight: notchWidth * 0.22, transform: nil))
    context.fillPath()

    let panelWidth = tile.width * 0.68
    let panelTop = tile.maxY - tile.height * 0.11       // overlaps the notch
    let panelHeight = tile.height * 0.56
    let panel = CGRect(x: tile.midX - panelWidth / 2, y: panelTop - panelHeight,
                       width: panelWidth, height: panelHeight)
    context.addPath(CGPath(roundedRect: panel, cornerWidth: panelWidth * 0.19,
                           cornerHeight: panelWidth * 0.19, transform: nil))
    context.fillPath()

    // Two light bars inside the panel: the answer coming back. They also stop
    // the panel from reading as a solid slab.
    let barHeight = panel.height * 0.135
    let barGap = panel.height * 0.16
    let left = panel.minX + panel.width * 0.18
    context.setFillColor(ink)
    for (index, factor) in [CGFloat(0.64), CGFloat(0.40)].enumerated() {
        let y = panel.minY + panel.height * 0.24 + CGFloat(1 - index) * (barHeight + barGap)
        let bar = CGRect(x: left, y: y, width: panel.width * factor, height: barHeight)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barHeight / 2,
                               cornerHeight: barHeight / 2, transform: nil))
        context.fillPath()
    }

    return context.makeImage()
}

// MARK: - Write the iconset

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/NotchAI.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = drawIcon(size: variant.size) else {
        FileHandle.standardError.write(Data("failed at \(variant.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(output)/\(variant.name).png")
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: variant.size, height: variant.size)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? data.write(to: url)
}

print("wrote \(variants.count) sizes to \(output)")
