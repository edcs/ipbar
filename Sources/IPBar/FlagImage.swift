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
    func menuBarImage(for country: String, muted: Bool, height: CGFloat = 12) -> NSImage? {
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

        let size = NSSize(width: (height * 4 / 3).rounded(), height: height)
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
        let bounds = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).addClip()
        base.draw(in: bounds)
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
