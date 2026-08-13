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

    @Test("a flag and a VPN symbol both survive")
    func flagAndVPNCoexist() throws {
        // The status item button holds one image, so handing it a flag and a
        // symbol separately meant the flag was dropped exactly when the exit
        // country mattered most. Composing them keeps both.
        let flagOnly = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnSymbol: nil, muted: false, store: store))
        let both = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnSymbol: "lock.fill", muted: false, store: store))

        #expect(both.size.width > flagOnly.size.width)
        #expect(both.size.height == flagOnly.size.height)
    }

    @Test("a flag makes the image colour, not a template")
    func flagKeepsColour() throws {
        let image = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnSymbol: nil, muted: false, store: store))
        #expect(image.isTemplate == false)
    }

    @Test("symbols alone stay a template so the system tints them")
    func symbolsStayTemplate() throws {
        let interface = try #require(MenuBarGlyph.image(
            qualifier: .interface("wifi"), vpnSymbol: nil, muted: false, store: store))
        #expect(interface.isTemplate)

        let vpnOnly = try #require(MenuBarGlyph.image(
            qualifier: .none, vpnSymbol: "lock.fill", muted: false, store: store))
        #expect(vpnOnly.isTemplate)
    }

    @Test("nothing to show means no image at all")
    func nothingToShow() {
        #expect(MenuBarGlyph.image(qualifier: .none, vpnSymbol: nil,
                                   muted: false, store: store) == nil)
    }

    @Test("an unknown country falls back to nothing rather than a blank gap")
    func unknownCountry() {
        #expect(MenuBarGlyph.image(qualifier: .country("zz"), vpnSymbol: nil,
                                   muted: false, store: store) == nil)
    }

    @Test("the leading gap is included once, not per part")
    func gapCountedOnce() throws {
        let image = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnSymbol: nil, muted: false, store: store))
        let flag = try #require(store.badge(for: "gb", muted: false,
                                            height: FlagStore.menuBarFlagHeight))
        #expect(image.size.width == (flag.size.width + FlagStore.menuBarFlagGap).rounded())
    }

    @Test("the leading edge is transparent so the gap really is a gap")
    func leadingEdgeIsClear() throws {
        let image = try #require(MenuBarGlyph.image(
            qualifier: .country("gb"), vpnSymbol: nil, muted: false, store: store))
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let inGap = try #require(rep.colorAt(x: 1, y: rep.pixelsHigh / 2))
        #expect(inGap.alphaComponent == 0)
    }
}

@Suite("Interface symbols")
struct InterfaceSymbolTests {
    @Test("every interface kind maps to a real SF Symbol")
    func symbolsExist() {
        let kinds: [NetworkInterface.Kind] = [
            .wifi, .ethernet, .cellular, .tunnel, .loopback, .virtual, .other
        ]
        for kind in kinds {
            let name = kind.menuBarSymbol
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(name) is not a valid SF Symbol")
        }
    }
}
