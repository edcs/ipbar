#!/usr/bin/env swift
//
// Renders Resources/AppIcon.iconset from vector drawing commands, so the icon
// is reviewable in diffs and editable without a design tool.
//
//   swift Tools/GenerateIcon.swift && make icon
//
// A globe seen from low orbit at sunrise, wrapped in a network mesh. The mesh
// is a real geodesic: points are distributed on a sphere, projected
// orthographically, and only the front-facing ones are drawn, so the density
// falls off toward the limb the way it actually would. One node is amber
// instead of cyan, which is the named address among all the rest.
//
// Everything is vector, so it stays crisp at 1024px and degrades deliberately
// at small sizes rather than turning to mush.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

enum Palette {
    static let spaceNear = srgb(0x0B1526)
    static let spaceFar = srgb(0x04060C)
    static let globeLit = srgb(0x2A7BA6)
    static let globeMid = srgb(0x0D3A5C)
    static let globeDark = srgb(0x030D17)
    static let atmosphere = srgb(0x74DFFF)
    static let mesh = srgb(0x5FD3FF)
    static let sunCore = srgb(0xFFF6E2)
    static let sunWarm = srgb(0xF7B04A)
    static let named = srgb(0xFFB43D)
    static let clear = srgb(0x000000, 0)
}

// MARK: - Geometry

/// Superellipse, the continuous-curvature rounded square macOS uses. Sampled
/// as a dense polygon: at these resolutions it is indistinguishable from the
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

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray,
               locations: locations ?? Array(stride(from: CGFloat(0), through: 1,
                                                    by: 1 / CGFloat(max(1, colors.count - 1)))))!
}

struct Vec3 {
    var x: CGFloat, y: CGFloat, z: CGFloat

    func rotated(pitch: CGFloat, yaw: CGFloat) -> Vec3 {
        let cp = cos(pitch), sp = sin(pitch)
        let y1 = y * cp - z * sp
        let z1 = y * sp + z * cp
        let cy = cos(yaw), sy = sin(yaw)
        return Vec3(x: x * cy + z1 * sy, y: y1, z: -x * sy + z1 * cy)
    }

    func distance(to other: Vec3) -> CGFloat {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}

/// Fibonacci lattice: the standard way to scatter points evenly over a sphere
/// without the pole crowding you get from a lat/long grid.
func spherePoints(_ count: Int, pitch: CGFloat, yaw: CGFloat) -> [Vec3] {
    let golden = CGFloat.pi * (3 - sqrt(5))
    return (0..<count).map { i in
        let y = 1 - (CGFloat(i) / CGFloat(count - 1)) * 2
        let ring = sqrt(max(0, 1 - y * y))
        let theta = golden * CGFloat(i)
        return Vec3(x: cos(theta) * ring, y: y, z: sin(theta) * ring)
            .rotated(pitch: pitch, yaw: yaw)
    }
}

// MARK: - Drawing

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    let showMesh = size >= 128
    let showRays = size >= 128

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let inset: CGFloat = 100 * s
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    ctx.saveGState()
    ctx.addPath(squircle(in: body))
    ctx.clip()

    // Space. Darkest top-left, faintly lit toward the globe.
    ctx.drawRadialGradient(gradient([Palette.spaceNear, Palette.spaceFar]),
                           startCenter: CGPoint(x: size * 0.78, y: size * 0.18), startRadius: 0,
                           endCenter: CGPoint(x: size * 0.78, y: size * 0.18), endRadius: size * 0.95,
                           options: [.drawsAfterEndLocation])

    // The globe sits mostly outside the frame, bottom-right, so only its limb
    // crosses the icon. The sun sits on that limb.
    let globe = CGPoint(x: size * 0.80, y: -size * 0.10)
    let radius = size * 0.72
    let sun = CGPoint(x: size * 0.635, y: size * 0.585)

    // Rays first: the globe is painted over them, so they only survive in space.
    if showRays {
        ctx.saveGState()
        ctx.translateBy(x: sun.x, y: sun.y)
        let rays = 26
        for i in 0..<rays {
            let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi
            let length = size * (i % 3 == 0 ? 0.40 : (i % 3 == 1 ? 0.26 : 0.17))
            let width = size * (i % 3 == 0 ? 0.009 : 0.005)
            ctx.saveGState()
            ctx.rotate(by: angle)
            let ray = CGMutablePath()
            ray.move(to: CGPoint(x: 0, y: -width))
            ray.addLine(to: CGPoint(x: length, y: 0))
            ray.addLine(to: CGPoint(x: 0, y: width))
            ray.closeSubpath()
            ctx.addPath(ray)
            ctx.setFillColor(srgb(0xFFD9A0, 0.085))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // Sun bloom, also behind the globe.
    ctx.drawRadialGradient(gradient([Palette.sunCore, Palette.sunWarm, Palette.clear],
                                    [0, 0.10, 1]),
                           startCenter: sun, startRadius: 0,
                           endCenter: sun, endRadius: size * 0.52,
                           options: [])

    // Atmospheric halo hugging the limb, drawn before the body so it reads as
    // light scattering outward into space.
    ctx.drawRadialGradient(gradient([Palette.clear, srgb(0x4FC9F5, 0.55), Palette.clear],
                                    [0.86, 0.945, 1]),
                           startCenter: globe, startRadius: 0,
                           endCenter: globe, endRadius: radius * 1.10,
                           options: [])

    // Globe body, lit from the sun side.
    let toSun = CGPoint(x: sun.x - globe.x, y: sun.y - globe.y)
    let toSunLength = max(0.0001, sqrt(toSun.x * toSun.x + toSun.y * toSun.y))
    let unit = CGPoint(x: toSun.x / toSunLength, y: toSun.y / toSunLength)

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: globe.x - radius, y: globe.y - radius,
                              width: radius * 2, height: radius * 2))
    ctx.clip()
    ctx.drawLinearGradient(gradient([Palette.globeLit, Palette.globeMid, Palette.globeDark],
                                    [0, 0.30, 0.80]),
                           start: CGPoint(x: globe.x + unit.x * radius, y: globe.y + unit.y * radius),
                           end: CGPoint(x: globe.x - unit.x * radius * 1.1,
                                        y: globe.y - unit.y * radius * 1.1),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Sunlight spilling onto the surface nearest the terminator, which is what
    // keeps the lit edge warm rather than uniformly blue.
    ctx.drawRadialGradient(gradient([srgb(0xFFCE8C, 0.50), srgb(0xE08A46, 0.18), Palette.clear],
                                    [0, 0.35, 1]),
                           startCenter: sun, startRadius: 0,
                           endCenter: sun, endRadius: size * 0.46,
                           options: [])

    // Network mesh, clipped to the globe by the same path.
    if showMesh {
        // Each point owns 4pi/N of surface. In a hexagonal packing that area is
        // 0.866*d^2, so nearest-neighbour distance d = sqrt(4pi / 0.866N). The
        // threshold has to track N: too low and nothing connects, too high and
        // it reaches the second ring and degenerates into large quads.
        let count = 190
        let spacing = sqrt(4 * .pi / (0.866 * CGFloat(count)))
        let threshold = spacing * 1.24
        let points = spherePoints(count, pitch: -0.38, yaw: 0.55)
        let project: (Vec3) -> CGPoint = { v in
            CGPoint(x: globe.x + v.x * radius, y: globe.y + v.y * radius)
        }

        ctx.setLineCap(.round)
        for i in 0..<points.count {
            guard points[i].z > 0 else { continue }
            for j in (i + 1)..<points.count {
                guard points[j].z > 0 else { continue }
                guard points[i].distance(to: points[j]) < threshold else { continue }
                // Fade toward the limb, where a real mesh foreshortens away.
                let depth = min(points[i].z, points[j].z)
                ctx.setStrokeColor(Palette.mesh.copy(alpha: 0.13 + depth * 0.47)!)
                ctx.setLineWidth(max(0.5, 1.5 * s))
                ctx.move(to: project(points[i]))
                ctx.addLine(to: project(points[j]))
                ctx.strokePath()
            }
        }

        // Nodes, and the one that carries a name.
        let target = CGPoint(x: size * 0.60, y: size * 0.22)
        var namedIndex = -1
        var best = CGFloat.greatestFiniteMagnitude
        for (i, v) in points.enumerated() where v.z > 0.55 {
            let p = project(v)
            let d = hypot(p.x - target.x, p.y - target.y)
            if d < best { best = d; namedIndex = i }
        }

        for (i, v) in points.enumerated() where v.z > 0 {
            let p = project(v)
            let r = (i == namedIndex ? 9.5 : 3.0) * s
            ctx.setFillColor(i == namedIndex
                             ? Palette.named
                             : Palette.mesh.copy(alpha: 0.40 + v.z * 0.55)!)
            if i == namedIndex {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 26 * s, color: srgb(0xFFB43D, 0.95))
            }
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if i == namedIndex { ctx.restoreGState() }
        }
    }
    ctx.restoreGState()

    // Bright rim on the lit edge, brightest nearest the sun.
    ctx.saveGState()
    ctx.setLineWidth(max(1, 5 * s))
    ctx.setStrokeColor(Palette.atmosphere.copy(alpha: 0.9)!)
    ctx.setShadow(offset: .zero, blur: 22 * s, color: srgb(0x8CE6FF, 0.85))
    let sunAngle = atan2(unit.y, unit.x)
    let arc = CGMutablePath()
    arc.addArc(center: globe, radius: radius,
               startAngle: sunAngle - 1.15, endAngle: sunAngle + 1.15, clockwise: false)
    ctx.addPath(arc)
    ctx.strokePath()
    ctx.restoreGState()

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
