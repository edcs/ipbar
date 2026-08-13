import AppKit
import Foundation
import Testing
@testable import IPBar

@Suite("Flag lookup")
struct FlagStoreTests {
    /// Points at the vendored SVGs in the source tree, since the test bundle
    /// has no Resources/Flags of its own.
    private var store: FlagStore {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // IPBarTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        return FlagStore(directory: root.appendingPathComponent("Resources/Flags"))
    }

    @Test("known countries load", arguments: ["gb", "us", "de", "jp", "br", "za"])
    func loadsKnownCountries(_ code: String) {
        #expect(store.flag(for: code) != nil)
    }

    @Test("codes are case insensitive")
    func caseInsensitive() {
        #expect(store.flag(for: "GB") != nil)
        #expect(store.flag(for: "Gb") != nil)
    }

    @Test("the second lookup is served from cache")
    func caches() {
        let store = self.store
        let first = store.flag(for: "gb")
        let second = store.flag(for: "gb")
        #expect(first != nil)
        #expect(first === second)
    }

    @Test("unusable codes are rejected", arguments: [
        "", "g", "gbr", "g1", "12", "  ", "gb/x", "../../etc/passwd", "zz"
    ])
    func rejectsUnusable(_ code: String) {
        // zz is a well-formed code with no flag, the rest are malformed. Both
        // must come back nil rather than throwing or escaping the directory.
        #expect(store.flag(for: code) == nil)
    }

    @Test("a missing directory is survivable")
    func missingDirectory() {
        #expect(FlagStore(directory: nil).flag(for: "gb") == nil)
        #expect(FlagStore(directory: URL(fileURLWithPath: "/nope")).flag(for: "gb") == nil)
    }
}

@Suite("Menu bar flag rendering")
struct MenuBarFlagTests {
    private var store: FlagStore {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FlagStore(directory: root.appendingPathComponent("Resources/Flags"))
    }

    private func centrePixel(_ image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
    }

    @Test("the flag is 4:3 with the gap carried as margin")
    func size() throws {
        let image = try #require(store.menuBarImage(for: "gb", muted: false, height: 12))
        #expect(image.size.height == 12)
        // 12 * 4/3 for the flag, plus transparent margin standing in for the
        // spacing an NSStatusItem button will not provide.
        #expect(image.size.width == 16 + FlagStore.menuBarFlagGap)
    }

    @Test("the gap is transparent, not painted")
    func gapIsClear() throws {
        let image = try #require(store.menuBarImage(for: "gb", muted: false, height: 12))
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        // Sample inside the margin, which sits at the leading edge.
        let inGap = try #require(rep.colorAt(x: 1, y: rep.pixelsHigh / 2))
        #expect(inGap.alphaComponent == 0)

        let inFlag = try #require(rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh / 2))
        #expect(inFlag.alphaComponent > 0.5)
    }

    @Test("is not a template, so the colour survives the menu bar")
    func notTemplate() throws {
        let image = try #require(store.menuBarImage(for: "gb", muted: false))
        #expect(image.isTemplate == false)
    }

    @Test("muting actually changes the pixels")
    func mutingApplies() throws {
        // Baked into the bitmap rather than applied with SwiftUI modifiers, so
        // it has to be verified on the pixels rather than assumed.
        let plain = try #require(store.menuBarImage(for: "gb", muted: false))
        let faded = try #require(store.menuBarImage(for: "gb", muted: true))

        let plainPixel = try #require(centrePixel(plain))
        let fadedPixel = try #require(centrePixel(faded))

        #expect(fadedPixel.alphaComponent < plainPixel.alphaComponent)
        let plainSpread = plainPixel.redComponent - plainPixel.blueComponent
        let fadedSpread = fadedPixel.redComponent - fadedPixel.blueComponent
        #expect(abs(fadedSpread) < abs(plainSpread))
    }

    @Test("the default height is derived from the menu bar font")
    func tracksMenuBarFont() throws {
        // Slightly over cap height, since a wide low rectangle reads smaller
        // than type of the same height. Still derived from the font so it
        // follows a change to menu bar text size.
        let font = NSFont.menuBarFont(ofSize: 0)
        let capHeight = font.capHeight.rounded()
        #expect(FlagStore.menuBarFlagHeight == capHeight + 2)

        let image = try #require(store.menuBarImage(for: "gb", muted: false))
        #expect(image.size.height == FlagStore.menuBarFlagHeight)
        // It must still sit inside the line box, or it crowds the menu bar.
        #expect(image.size.height < NSLayoutManager().defaultLineHeight(for: font))
    }

    @Test("an unknown country renders nothing")
    func unknown() {
        #expect(store.menuBarImage(for: "zz", muted: false) == nil)
        #expect(store.menuBarImage(for: "!!", muted: false) == nil)
    }

    @Test("repeat renders come from cache")
    func cached() throws {
        let store = self.store
        let first = try #require(store.menuBarImage(for: "de", muted: false))
        let second = try #require(store.menuBarImage(for: "de", muted: false))
        #expect(first === second)
    }
}
