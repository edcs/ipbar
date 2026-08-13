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

    private static var cache: [String: NSImage] = [:]

    static func image(qualifier: Qualifier, vpnSymbol: String?, muted: Bool,
                      store: FlagStore = .shared) -> NSImage? {
        let key = "\(ObjectIdentifier(store))|\(qualifier)|\(vpnSymbol ?? "-")|\(muted)"
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
            if let glyph = symbolImage(symbol, height: height) { parts.append(glyph) }
        }

        if let vpnSymbol, let glyph = symbolImage(vpnSymbol, height: height) {
            parts.append(glyph)
        }

        guard !parts.isEmpty else { return nil }
        guard let composed = compose(parts, height: height, colour: hasColour) else { return nil }

        cache[key] = composed
        return composed
    }

    static func invalidate() { cache.removeAll() }

    private static func symbolImage(_ name: String, height: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: height, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private static func compose(_ parts: [NSImage], height: CGFloat, colour: Bool) -> NSImage? {
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
            // invisible on a dark menu bar. Symbols alongside a flag are tinted
            // to a mid blue that holds up against a light or a dark bar.
            if colour, part.isTemplate {
                NSColor(srgbRed: 0.36, green: 0.72, blue: 0.92, alpha: 1).set()
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

extension NetworkInterface.Kind {
    /// Stands in for the flag when a local address is on show.
    var menuBarSymbol: String {
        switch self {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .tunnel: return "lock.shield"
        case .loopback, .virtual, .other: return "network"
        }
    }
}
