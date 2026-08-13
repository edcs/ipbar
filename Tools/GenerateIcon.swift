#!/usr/bin/env swift
//
// Renders Resources/AppIcon.iconset from vector drawing commands, so the icon
// is reviewable in diffs and editable without a design tool.
//
//   swift Tools/GenerateIcon.swift && make icon
//
// Concept: an amber label tag lying over a dotted-quad address. The address is
// segmented (four bars, three dots); the name on the tag is one continuous bar,
// because a name is one word. The tag covers the number — which is the app.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette
// Drawn from patch-panel and label-tape hardware rather than the blue-globe
// convention every other IP utility uses.

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

enum Palette {
    static let chassisTop = srgb(0x2A2D34)
    static let chassisBottom = srgb(0x15171B)
    static let amber = srgb(0xF2B02E)
    static let amberLight = srgb(0xFFD066)
    static let ink = srgb(0x141519)
    static let ghost = srgb(0x8B93A3, 0.34)
}

// MARK: - Geometry

/// Superellipse, the continuous-curvature rounded square macOS uses. Sampled
/// as a dense polygon — at these resolutions it is indistinguishable from the
/// analytic curve and avoids hand-tuned bezier control points.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let e = 2 / n
        let x = rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), e)
        let y = rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), e)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// A luggage/cable tag: rounded rectangle with the left end drawn to a point,
/// and an eyelet punched near the tip.
func tagPath(width w: CGFloat, height h: CGFloat, tip: CGFloat,
             radius r: CGFloat, eyelet: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let top = h / 2, bottom = -h / 2

    path.move(to: CGPoint(x: tip, y: top))
    path.addArc(tangent1End: CGPoint(x: w, y: top), tangent2End: CGPoint(x: w, y: bottom), radius: r)
    path.addArc(tangent1End: CGPoint(x: w, y: bottom), tangent2End: CGPoint(x: tip, y: bottom), radius: r)
    path.addLine(to: CGPoint(x: tip, y: bottom))
    path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: tip, y: top), radius: r * 0.55)
    path.closeSubpath()

    // Even-odd fill turns this subpath into a hole, so the chassis shows through.
    path.addEllipse(in: CGRect(x: tip * 0.52 - eyelet, y: -eyelet, width: eyelet * 2, height: eyelet * 2))
    return path
}

func roundedBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y - height / 2, width: width, height: height),
           cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray, locations: [0, 1])!
}

// MARK: - Drawing

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024                      // all geometry authored at 1024
    let showAddress = size >= 64             // vanishes into noise below this
    let showDepth = size >= 128

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Chassis
    let inset: CGFloat = 100 * s
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    ctx.saveGState()
    ctx.addPath(squircle(in: body))
    ctx.clip()
    ctx.drawLinearGradient(gradient([Palette.chassisTop, Palette.chassisBottom]),
                           start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // The address being replaced: four octets, three separators.
    if showAddress {
        let octets: [CGFloat] = [112, 84, 52, 112]
        let dot: CGFloat = 18 * s
        let gap: CGFloat = 21 * s
        let barHeight: CGFloat = 30 * s
        let total = octets.reduce(0) { $0 + $1 * s } + 3 * (dot + gap * 2)
        var x = size / 2 - total / 2
        let y = size * 0.618

        ctx.setFillColor(Palette.ghost)
        for (index, octet) in octets.enumerated() {
            ctx.addPath(roundedBar(x: x, y: y, width: octet * s, height: barHeight))
            ctx.fillPath()
            x += octet * s
            if index < octets.count - 1 {
                x += gap
                ctx.addPath(CGPath(ellipseIn: CGRect(x: x, y: y - dot / 2, width: dot, height: dot),
                                   transform: nil))
                ctx.fillPath()
                x += dot + gap
            }
        }
    }

    // The tag, tilted as though pinned at the eyelet.
    ctx.saveGState()
    // Without the address row above it, the tag alone reads bottom-heavy.
    ctx.translateBy(x: size * 0.232, y: size * (showAddress ? 0.428 : 0.5))
    ctx.rotate(by: -6 * .pi / 180)

    let tagWidth = 545 * s, tagHeight = 210 * s
    let tip = 108 * s
    let tag = tagPath(width: tagWidth, height: tagHeight, tip: tip,
                      radius: 40 * s, eyelet: 26 * s)

    if showDepth {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 34 * s,
                      color: srgb(0x000000, 0.45))
        ctx.setFillColor(Palette.amber)
        ctx.addPath(tag)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(tag)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([Palette.amberLight, Palette.amber]),
                           start: CGPoint(x: 0, y: tagHeight / 2),
                           end: CGPoint(x: 0, y: -tagHeight / 2), options: [])
    ctx.restoreGState()

    // The name: one continuous mark, against the segmented address behind it.
    ctx.setFillColor(Palette.ink)
    ctx.addPath(roundedBar(x: tip + 92 * s, y: 0, width: 300 * s, height: 40 * s))
    ctx.fillPath()

    ctx.restoreGState()
}

// MARK: - Output

let iconset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let ctx = CGContext(data: nil, width: variant.pixels, height: variant.pixels,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create \(variant.pixels)px context")
    }
    drawIcon(into: ctx, size: CGFloat(variant.pixels))

    guard let image = ctx.makeImage() else { fatalError("render failed at \(variant.pixels)px") }

    // ImageIO rather than NSBitmapImageRep: this runs in CI, and a build-time
    // image tool should not drag in AppKit.
    let url = iconset.appendingPathComponent("\(variant.name).png") as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not open \(variant.name).png for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not encode \(variant.name).png")
    }
}

print("wrote \(variants.count) images to Resources/AppIcon.iconset")
