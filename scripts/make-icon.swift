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

/// The notch silhouette: flat against the top, rounded below, with the two
/// concave shoulders that make it read as a notch rather than a tab.
func notchPath(in rect: CGRect, shoulder: CGFloat, bottom: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let top = rect.maxY

    path.move(to: CGPoint(x: rect.minX - shoulder, y: top))
    path.addQuadCurve(to: CGPoint(x: rect.minX, y: top - shoulder),
                      control: CGPoint(x: rect.minX, y: top))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bottom))
    path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.minY),
                      control: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + bottom),
                      control: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: top - shoulder))
    path.addQuadCurve(to: CGPoint(x: rect.maxX + shoulder, y: top),
                      control: CGPoint(x: rect.maxX, y: top))
    path.closeSubpath()
    return path
}

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
    let tileRadius = tile.width * 0.22

    context.addPath(CGPath(roundedRect: tile, cornerWidth: tileRadius,
                           cornerHeight: tileRadius, transform: nil))
    context.setFillColor(midnight)
    context.fillPath()

    // Two elements: the notch itself flush against the top edge, and the
    // panel it springs into, floating below it.
    //
    // The panel must NOT touch the top edge. A light shape flush with the edge
    // of a dark tile inverts figure and ground — you start reading the leftover
    // midnight as two ears and the whole mark becomes a box. A clear band of
    // midnight above the panel keeps the light shape as the subject.
    let nubWidth = tile.width * 0.26
    let nubHeight = tile.height * 0.055
    let nub = CGRect(x: tile.midX - nubWidth / 2,
                     y: tile.maxY - nubHeight,
                     width: nubWidth, height: nubHeight)
    context.addPath(CGPath(roundedRect: nub,
                           cornerWidth: nubHeight * 0.55,
                           cornerHeight: nubHeight * 0.55, transform: nil))
    context.setFillColor(ink)
    context.setAlpha(0.32)
    context.fillPath()
    context.setAlpha(1)

    let panelWidth = tile.width * 0.60
    let panelHeight = tile.height * 0.36
    let panel = CGRect(x: tile.midX - panelWidth / 2,
                       y: tile.maxY - nubHeight - tile.height * 0.07 - panelHeight,
                       width: panelWidth, height: panelHeight)
    context.addPath(CGPath(roundedRect: panel,
                           cornerWidth: panelWidth * 0.17,
                           cornerHeight: panelWidth * 0.17, transform: nil))
    context.setFillColor(ink)
    context.fillPath()

    // Two bars in midnight — never `.clear`, which would punch through the
    // tile as well and leave the bars invisible against a light background.
    let barHeight = panel.height * 0.135
    let barGap = panel.height * 0.165
    let left = panel.minX + panel.width * 0.17
    context.setFillColor(midnight)
    for (index, factor) in [CGFloat(0.66), CGFloat(0.40)].enumerated() {
        let y = panel.minY + panel.height * 0.26 + CGFloat(1 - index) * (barHeight + barGap)
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
