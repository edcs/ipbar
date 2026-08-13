import AppKit

/// Builds the single image that trails the address in the menu bar.
///
/// An `NSStatusItem` button holds exactly one image, so a VPN symbol and a flag
/// cannot both be handed to it: the first one wins and the other silently
/// disappears. Everything that trails the address is therefore composed here
/// into one image.
///
/// What appears depends on what the address actually is. A country flag
/// describes the public address, so it would be a lie beside a local one; a
/// local address gets its interface instead.
@MainActor
enum MenuBarGlyph {
    /// What qualifies the address currently on show.
    enum Qualifier: Equatable {
        case none
        case country(String)
        /// SF Symbol for the interface the local address belongs to.
        case interface(String)
    }

    /// Marks a local address as being on your own network.
    ///
    /// Not `wifi`: macOS already shows that in the menu bar, so it read as a
    /// second Wi-Fi indicator rather than a fact about the address. Not
    /// `network` either, which is a globe and means the opposite of local. A
    /// device attached to a network line says it without borrowing either, and
    /// it holds up whether you are on Wi-Fi or Ethernet.
    nonisolated static let localNetworkSymbol = "rectangle.connected.to.line.below"

    private static var cache: [String: NSImage] = [:]

    static func image(qualifier: Qualifier, vpnLabel: String?, muted: Bool,
                      dark: Bool, store: FlagStore = .shared) -> NSImage? {
        let key = "\(ObjectIdentifier(store))|\(qualifier)|\(vpnLabel ?? "-")|\(muted)|\(dark)"
        if let cached = cache[key] { return cached }

        let height = FlagStore.menuBarFlagHeight
        var parts: [NSImage] = []
        var hasColour = false

        switch qualifier {
        case .none:
            break
        case .country(let code):
            if let flag = store.badge(for: code, muted: muted, height: height) {
                parts.append(flag)
                hasColour = true
            }
        case .interface(let symbol):
            if let glyph = symbolImage(symbol, inkHeight: symbolInkHeight) { parts.append(glyph) }
        }

        if let vpnLabel, let text = textImage(vpnLabel) {
            parts.append(text)
        }

        guard !parts.isEmpty else { return nil }
        // Tall enough for the tallest part: a canvas fixed at the flag's height
        // silently cropped the symbols.
        let canvas = max(height, parts.map(\.size.height).max() ?? height)
        guard let composed = compose(parts, height: canvas, colour: hasColour, dark: dark) else { return nil }

        cache[key] = composed
        return composed
    }

    static func invalidate() { cache.removeAll() }

    /// Ink height for symbols: one point above the flag, on purpose.
    ///
    /// A flag is a solid rectangle that fills its box, a symbol is line art
    /// covering a fraction of its own, so matched by box they look mismatched
    /// and a symbol needs slightly more height to carry the same weight. Only
    /// slightly, though: matching the neighbouring system icons instead made it
    /// tower over the address. Derived from the flag so the two stay in step
    /// when the menu bar text size changes.
    nonisolated static var symbolInkHeight: CGFloat { FlagStore.menuBarFlagHeight + 1 }

    /// Scales a symbol so the mark it actually draws is `inkHeight` tall.
    ///
    /// Asking for a point size is not enough: at the same point size `wifi`
    /// inks 10pt while `cable.connector` inks 13pt, and their boxes carry
    /// different amounts of empty space. Measuring the ink and cropping to it
    /// makes every symbol land at the same visual weight, and stops the box
    /// padding from distorting the spacing between parts.
    private static func symbolImage(_ name: String, inkHeight: CGFloat) -> NSImage? {
        let reference: CGFloat = 48   // render large, measure, then scale down
        guard let source = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: reference, weight: .medium)),
            let tiff = source.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff) else { return nil }

        guard let ink = inkBounds(rep, pointSize: source.size) else { return nil }

        let scale = inkHeight / ink.height
        let size = NSSize(width: (ink.width * scale).rounded(), height: inkHeight)

        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // Shift the ink to the origin, then scale it to the target height.
        source.draw(in: NSRect(x: -ink.minX * scale, y: -ink.minY * scale,
                               width: source.size.width * scale,
                               height: source.size.height * scale))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// The rectangle a symbol actually marks, in points, ignoring the empty
    /// padding its box carries.
    private static func inkBounds(_ rep: NSBitmapImageRep, pointSize: NSSize) -> NSRect? {
        var minX = rep.pixelsWide, maxX = -1
        var minY = rep.pixelsHigh, maxY = -1

        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let sx = pointSize.width / CGFloat(rep.pixelsWide)
        let sy = pointSize.height / CGFloat(rep.pixelsHigh)
        // Bitmap rows run top-down while the drawing space runs bottom-up.
        return NSRect(x: CGFloat(minX) * sx,
                      y: CGFloat(rep.pixelsHigh - 1 - maxY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx,
                      height: CGFloat(maxY - minY + 1) * sy)
    }

    /// Renders text as an alpha mask, matching the menu bar font so it reads as
    /// part of the same line as the address.
    ///
    /// Drawn in black with no colour of its own. Without a flag the whole
    /// composite stays a template and the system tints it. With one, the
    /// composite has to be colour, so `compose` tints this to match the menu
    /// bar's own text for the current appearance.
    private static func textImage(_ text: String) -> NSImage? {
        let font = NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        guard size.width > 0, size.height > 0 else { return nil }

        let image = NSImage(size: NSSize(width: size.width.rounded(.up),
                                         height: size.height.rounded(.up)))
        image.lockFocus()
        string.draw(at: .zero, withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func compose(_ parts: [NSImage], height: CGFloat,
                                colour: Bool, dark: Bool) -> NSImage? {
        let inner: CGFloat = 4
        let lead = FlagStore.menuBarFlagGap
        let width = lead + parts.map(\.size.width).reduce(0, +) + inner * CGFloat(parts.count - 1)

        let size = NSSize(width: width.rounded(), height: height)
        let scale: CGFloat = 2
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

        var x = lead
        for part in parts {
            let box = NSRect(x: x, y: ((height - part.size.height) / 2).rounded(),
                             width: part.size.width, height: part.size.height)
            part.draw(in: box)

            // A template drawn into a colour composite arrives black, which is
            // invisible on a dark menu bar. A flag forces the composite to
            // colour, so anything template beside it is tinted to whatever the
            // menu bar is currently using for its own text.
            if colour, part.isTemplate {
                (dark ? NSColor.white : NSColor.black).set()
                box.fill(using: .sourceAtop)
            }
            x += part.size.width + inner
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        // Without a flag every part is a symbol, so the whole thing can stay a
        // template and the system tints it for the menu bar as it sees fit.
        image.isTemplate = !colour
        return image
    }
}

