import AppKit
import Foundation
import Testing
@testable import IPBar

@Suite("Menu bar glyph composition")
@MainActor
struct MenuBarGlyphTests {
    private var store: FlagStore {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FlagStore(directory: root.appendingPathComponent("Resources/Flags"))
    }

    @Test("a flag and the VPN label both survive")
    func flagAndVPNCoexist() throws {
        // The status item button holds one image, so handing it a flag and a
        // second mark separately meant the flag was dropped exactly when the
        // exit country mattered most. Composing them keeps both.
        let flagOnly = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: nil, muted: false, dark: false, store: store))
        let both = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: "(VPN)", muted: false, dark: false, store: store))

        #expect(both.size.width > flagOnly.size.width)
    }

    @Test("the canvas fits the tallest part rather than cropping it")
    func canvasFitsTallestPart() throws {
        // A canvas fixed at the flag's height silently cropped symbols, whose
        // boxes are taller than the flag at any comparable size.
        let withSymbol = try #require(MenuBarGlyph.image(
            qualifier: .interface(MenuBarGlyph.localNetworkSymbol), vpnLabel: nil, muted: false, dark: false, store: store))
        #expect(withSymbol.size.height >= MenuBarGlyph.symbolInkHeight)

        // But never so tall that it crowds the menu bar.
        let line = NSLayoutManager().defaultLineHeight(for: NSFont.menuBarFont(ofSize: 0))
        #expect(withSymbol.size.height <= line)
    }

    @Test("symbols land at the same ink height regardless of shape", arguments: [
        MenuBarGlyph.localNetworkSymbol, "cable.connector", "wifi", "lock.fill"
    ])
    func consistentInkHeight(_ symbol: String) throws {
        // At one point size these ink between 10pt and 13pt, which is why they
        // are scaled by measured ink instead.
        let image = try #require(MenuBarGlyph.image(
            qualifier: .interface(symbol), vpnLabel: nil, muted: false, dark: false, store: store))
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))

        var minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minY = min(minY, y); maxY = max(maxY, y); break
            }
        }
        let scale = CGFloat(rep.pixelsHigh) / image.size.height
        let ink = CGFloat(maxY - minY + 1) / scale
        #expect(abs(ink - MenuBarGlyph.symbolInkHeight) <= 1.0,
                "\(symbol) inked \(ink), wanted \(MenuBarGlyph.symbolInkHeight)")
    }

    @Test("a symbol is taller than the flag, since line art reads smaller")
    func symbolOutgrowsFlag() {
        #expect(MenuBarGlyph.symbolInkHeight > FlagStore.menuBarFlagHeight)
    }

    @Test("a flag makes the image colour, not a template")
    func flagKeepsColour() throws {
        let image = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: nil, muted: false, dark: false, store: store))
        #expect(image.isTemplate == false)
    }

    @Test("the VPN label is drawn, not dropped")
    func vpnLabelIsDrawn() throws {
        let plain = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: nil, muted: false, dark: false, store: store))
        let labelled = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: "(VPN)", muted: false, dark: false, store: store))
        // Text is wider than a padlock glyph was, and must actually take space.
        #expect(labelled.size.width > plain.size.width + 10)
    }

    @Test("the VPN label alone still shows without a flag")
    func vpnLabelWithoutFlag() throws {
        let image = try #require(MenuBarGlyph.image(
            qualifier: .none, vpnLabel: "(VPN)", muted: false, dark: false, store: store))
        #expect(image.size.width > 0)
        // No flag means nothing forces colour, so the system can tint it.
        #expect(image.isTemplate)
    }

    @Test("symbols alone stay a template so the system tints them")
    func symbolsStayTemplate() throws {
        let interface = try #require(MenuBarGlyph.image(
            qualifier: .interface(MenuBarGlyph.localNetworkSymbol), vpnLabel: nil, muted: false, dark: false, store: store))
        #expect(interface.isTemplate)

        let vpnOnly = try #require(MenuBarGlyph.image(
            qualifier: .none, vpnLabel: "(VPN)", muted: false, dark: false, store: store))
        #expect(vpnOnly.isTemplate)
    }

    @Test("nothing to show means no image at all")
    func nothingToShow() {
        #expect(MenuBarGlyph.image(qualifier: .none, vpnLabel: nil,
                                   muted: false, dark: false, store: store) == nil)
    }

    @Test("an unknown country falls back to nothing rather than a blank gap")
    func unknownCountry() {
        #expect(MenuBarGlyph.image(qualifier: .country("zz"), vpnLabel: nil,
                                   muted: false, dark: false, store: store) == nil)
    }

    @Test("the leading gap is included once, not per part")
    func gapCountedOnce() throws {
        let image = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: nil, muted: false, dark: false, store: store))
        let flag = try #require(store.badge(for: "gb", muted: false,
                                            height: FlagStore.menuBarFlagHeight))
        #expect(image.size.width == (flag.size.width + FlagStore.menuBarFlagGap).rounded())
    }

    @Test("the leading edge is transparent so the gap really is a gap")
    func leadingEdgeIsClear() throws {
        let image = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: nil, muted: false, dark: false, store: store))
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let inGap = try #require(rep.colorAt(x: 1, y: rep.pixelsHigh / 2))
        #expect(inGap.alphaComponent == 0)
    }
}

@Suite("Local network symbol")
struct LocalSymbolTests {
    @Test("the local symbol is a real SF Symbol")
    func symbolExists() {
        #expect(NSImage(systemSymbolName: MenuBarGlyph.localNetworkSymbol,
                        accessibilityDescription: nil) != nil)
    }

    @Test("it is not the system's own Wi-Fi glyph")
    func notWiFi() {
        // macOS already shows wifi in the menu bar; reusing it made this read
        // as a duplicate indicator rather than a fact about the address.
        #expect(MenuBarGlyph.localNetworkSymbol != "wifi")
        #expect(!MenuBarGlyph.localNetworkSymbol.hasPrefix("wifi"))
    }
}

@Suite("Menu bar ink follows the appearance")
@MainActor
struct MenuBarInkTests {
    private var store: FlagStore {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FlagStore(directory: root.appendingPathComponent("Resources/Flags"))
    }

    private func inkPixel(_ image: NSImage) -> NSColor? {
        // Sample the trailing end, past the flag, where the label is drawn.
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        for x in stride(from: rep.pixelsWide - 2, through: rep.pixelsWide / 2, by: -1) {
            for y in 0..<rep.pixelsHigh {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.6 {
                    return colour
                }
            }
        }
        return nil
    }

    @Test("the VPN label is dark on a light menu bar and light on a dark one")
    func inkFlips() throws {
        // A flag forces the composite to colour, so the label cannot be a
        // template and the system will not tint it. It is drawn to match.
        let light = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: "(VPN)", muted: false, dark: false, store: store))
        let dark = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: "(VPN)", muted: false, dark: true, store: store))

        let onLight = try #require(inkPixel(light))
        let onDark = try #require(inkPixel(dark))

        #expect(onLight.brightnessComponent < 0.4, "dark ink for a light menu bar")
        #expect(onDark.brightnessComponent > 0.6, "light ink for a dark menu bar")
    }

    @Test("light and dark are cached separately")
    func cachedPerAppearance() throws {
        let light = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: "(VPN)", muted: false, dark: false, store: store))
        let dark = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnLabel: "(VPN)", muted: false, dark: true, store: store))
        #expect(light !== dark, "one cache entry for both would freeze the first appearance in")
    }
}
