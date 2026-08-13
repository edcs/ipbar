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
        var parts: [Part] = []
        var hasColour = false

        switch qualifier {
        case .none:
            break
        case .country(let code):
            if let flag = store.badge(for: code, muted: muted, height: height) {
                parts.append(Part(image: flag, baseline: nil))
                hasColour = true
            }
        case .interface(let symbol):
            if let glyph = symbolImage(symbol, inkHeight: symbolInkHeight) {
                parts.append(Part(image: glyph, baseline: nil))
            }
        }

        if let vpnLabel, let badge = badgeImage(vpnLabel, height: height) {
            parts.append(badge)
        }

        guard !parts.isEmpty else { return nil }
        // Tall enough for the tallest part, plus slack so a baseline-aligned
        // label is not clipped. Growing it symmetrically leaves the centre
        // where it was, and the button centres the whole image anyway.
        let canvas = max(height, parts.map(\.image.size.height).max() ?? height) + 2
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

    /// An outlined badge, after the one iOS puts in its status bar.
    ///
    /// Sized to the flag beside it and centred like one. It is a mark rather
    /// than a word set on the line, so unlike the bracketed text it replaces it
    /// does not take the address's baseline: boxes centre, words sit on the
    /// baseline, and mixing the two is what looked crooked.
    private static func badgeImage(_ text: String, height: CGFloat) -> Part? {
        let stroke: CGFloat = 1
        let radius = height * 0.3
        let font = NSFont.systemFont(ofSize: (height * 0.72).rounded(), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.black]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        // Measured off the iOS badge: it sets the word in about half a badge
        // height of space either side, which is what stops it looking cramped.
        let padding = (height * 0.45).rounded()
        let width = (textSize.width + padding * 2).rounded()
        guard width > 0, height > 0 else { return nil }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true

        // Inset by half the stroke so the line sits inside the bounds rather
        // than straddling them and clipping.
        let outline = NSBezierPath(
            roundedRect: NSRect(x: stroke / 2, y: stroke / 2,
                                width: width - stroke, height: height - stroke),
            xRadius: radius, yRadius: radius)
        outline.lineWidth = stroke
        NSColor.black.setStroke()
        outline.stroke()

        // Centre the capitals rather than the line box: the font carries
        // descender space no capital uses, which would sit the word high.
        let baseline = (height - font.capHeight) / 2
        string.draw(at: NSPoint(x: ((width - textSize.width) / 2).rounded(),
                                y: baseline - abs(font.descender)),
                    withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        return Part(image: image, baseline: nil)
    }

    /// One element of the composite.
    ///
    /// `baseline` is the distance from the image's bottom edge to the text
    /// baseline, for parts that are words set on the line. Marks have none and
    /// are centred instead.
    private struct Part {
        let image: NSImage
        let baseline: CGFloat?
    }

    private static func compose(_ parts: [Part], height: CGFloat,
                                colour: Bool, dark: Bool) -> NSImage? {
        let inner: CGFloat = 4
        let lead = FlagStore.menuBarFlagGap
        let width = lead + parts.map(\.image.size.width).reduce(0, +) + inner * CGFloat(parts.count - 1)

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

        // The button centres both the title and the image, so the address's
        // cap centre lands on the canvas centre. Its baseline therefore sits
        // half a cap height below that, and text here has to meet it: two sizes
        // of type on one line share a baseline, they do not share a centre.
        let capHeight = NSFont.menuBarFont(ofSize: 0).capHeight
        let addressBaseline = height / 2 - capHeight / 2

        var x = lead
        for part in parts {
            let y: CGFloat
            if let baseline = part.baseline {
                // Rounded to half a point, not a whole one: the menu bar is
                // Retina, so half points are addressable and whole-point
                // rounding was leaving the baseline a pixel out.
                y = ((addressBaseline - baseline) * 2).rounded() / 2
            } else {
                y = ((height - part.image.size.height)).rounded() / 2
            }
            let box = NSRect(x: x, y: y,
                             width: part.image.size.width, height: part.image.size.height)
            part.image.draw(in: box)

            // A template drawn into a colour composite arrives black, which is
            // invisible on a dark menu bar. A flag forces the composite to
            // colour, so anything template beside it is tinted to whatever the
            // menu bar is currently using for its own text.
            if colour, part.image.isTemplate {
                (dark ? NSColor.white : NSColor.black).set()
                box.fill(using: .sourceAtop)
            }
            x += part.image.size.width + inner
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

