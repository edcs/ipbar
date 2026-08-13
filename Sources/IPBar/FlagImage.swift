import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A flat country flag, loaded from the SVGs vendored in `Resources/Flags/`.
///
/// macOS renders SVG natively through `NSImage`, so these stay vector and
/// crisp at any size with no conversion step and no third-party Swift package.
/// Artwork is flag-icons by Panayiotis Lipiridis, MIT, see Resources/Flags/LICENSE.
struct FlagImage: View {
    let country: String
    var height: CGFloat = 11
    var muted: Bool = false

    var body: some View {
        if let image = FlagStore.shared.flag(for: country) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(height: height)
                // Muted keeps the flag legible as an identifier while stopping
                // it from being the loudest thing in a quiet panel.
                .saturation(muted ? 0.25 : 1)
                .opacity(muted ? 0.55 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                )
                .accessibilityLabel(Locale.current.localizedString(forRegionCode: country) ?? country)
        }
    }
}

/// Flags are read from disk once and kept, since the country changes rarely
/// but the panel redraws constantly.
final class FlagStore: @unchecked Sendable {
    static let shared = FlagStore(
        directory: Bundle.main.resourceURL?.appendingPathComponent("Flags")
    )

    private let directory: URL?
    private var cache: [String: NSImage?] = [:]
    private var rendered: [String: NSImage?] = [:]
    private let lock = NSLock()

    init(directory: URL?) {
        self.directory = directory
    }

    func flag(for country: String) -> NSImage? {
        // The code becomes a filename, so it is checked rather than trusted:
        // exactly two ASCII letters, which cannot escape the directory.
        let code = country.lowercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }),
              let directory else { return nil }

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[code] { return cached }

        let image = NSImage(contentsOf: directory.appendingPathComponent("\(code).svg"))
        cache[code] = image
        return image
    }

    /// A flag sized and rasterised for the menu bar.
    ///
    /// The muting is baked into the bitmap rather than applied with SwiftUI
    /// modifiers, because a `MenuBarExtra` label is rendered by the system and
    /// does not reliably honour effects like `.saturation`. `isTemplate` stays
    /// false so the colour survives the menu bar's usual monochrome treatment.
    /// Cap height of the menu bar font, which for an address of digits is also
    /// the digit height. Sizing the flag to it aligns its top and bottom edges
    /// with the numerals beside it, and it follows the font if the menu bar
    /// text size changes.
    static var menuBarFlagHeight: CGFloat {
        NSFont.menuBarFont(ofSize: 0).capHeight.rounded()
    }

    /// Space between the address and the flag, carried as transparent margin
    /// inside the image: an `NSStatusItem` button puts no gap between its title
    /// and its image, and SwiftUI discards padding applied to the view.
    static let menuBarFlagGap: CGFloat = 5

    /// A flag as tall as the full line box reads as a block beside the type
    /// rather than a companion mark, so the default is cap height instead.
    func menuBarImage(for country: String, muted: Bool,
                      height: CGFloat = FlagStore.menuBarFlagHeight) -> NSImage? {
        let key = "\(country.lowercased())|\(muted)|\(Int(height))"

        lock.lock()
        if let cached = rendered[key] { lock.unlock(); return cached }
        lock.unlock()

        let image = renderForMenuBar(country: country, muted: muted, height: height)

        lock.lock()
        rendered[key] = image
        lock.unlock()
        return image
    }

    private func renderForMenuBar(country: String, muted: Bool, height: CGFloat) -> NSImage? {
        guard let base = flag(for: country) else { return nil }

        let flag = NSSize(width: (height * 4 / 3).rounded(), height: height)

        let gap = Self.menuBarFlagGap
        let size = NSSize(width: flag.width + gap, height: flag.height)

        let scale: CGFloat = 2   // menu bars are Retina; draw at 2x and let AppKit pick
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(x: gap, y: 0, width: flag.width, height: flag.height)
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).addClip()
        base.draw(in: bounds)

        // A hairline so flags with white in them, like GB or JP, keep an edge
        // against a light menu bar. It disappears against a dark one.
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                xRadius: 1.5, yRadius: 1.5)
        edge.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.22).setStroke()
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false

        guard muted else { return image }
        return Self.muted(image, size: size) ?? image
    }

    private static func muted(_ image: NSImage, size: NSSize) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return nil }

        let desaturate = CIFilter.colorControls()
        desaturate.inputImage = input
        desaturate.saturation = 0.25
        guard let desaturated = desaturate.outputImage else { return nil }

        let fade = CIFilter.colorMatrix()
        fade.inputImage = desaturated
        fade.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.55)
        guard let output = fade.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }

        let result = NSImage(cgImage: cgImage, size: size)
        result.isTemplate = false
        return result
    }
}
