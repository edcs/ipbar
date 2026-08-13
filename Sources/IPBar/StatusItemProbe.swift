import AppKit
import Foundation
import SwiftUI

/// Dumps what the menu bar item actually ended up containing.
///
/// `MenuBarExtra` renders its label through an `NSStatusItem`, and there is no
/// way to see the result from outside the process without screen recording.
/// Run with `IPBAR_PROBE=1` to have the app report its own status item.
enum StatusItemProbe {
    static func startIfRequested() {
        let mode = ProcessInfo.processInfo.environment["IPBAR_PROBE"]
        if mode == "panel" { renderPanel(); return }
        guard mode == "1" || mode == "item" else { return }
        let snapshotting = mode == "item"

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            var found = 0
            for window in NSApplication.shared.windows {
                guard let root = window.contentView else { continue }
                for button in statusButtons(in: root) {
                    found += 1
                    report(button)
                    if snapshotting { snapshot(button) }
                }
            }
            if found == 0 { emit("no NSStatusBarButton found in \(NSApplication.shared.windows.count) windows") }
            exit(0)
        }
    }

    /// Renders the panel to a PNG so its layout can actually be looked at.
    /// `IPBAR_PROBE=panel IPBAR_PANEL_OUT=/tmp/panel.png IPBar`
    private static func renderPanel() {
        Task { @MainActor in
            let preferences = Preferences()
            let model = NetworkModel(preferences: preferences)

            // Screenshots run on made-up addresses. A README is public, and the
            // person generating one should not have to publish where they live.
            if ProcessInfo.processInfo.environment["IPBAR_PANEL_SAMPLE"] == "1" {
                model.loadSampleData()
                preferences.labels = [AddressLabel(pattern: "203.0.113.42", name: "Home",
                                                   scope: .publicAddress)]
                preferences.nameDisplay = .name
            } else {
                model.start()
                try? await Task.sleep(for: .seconds(6))   // let the lookups land
            }

            // IPBAR_PANEL_SCHEME=dark|light renders the panel as it looks in
            // that appearance, whatever the machine is currently set to, so
            // both can be captured in one go.
            let scheme: ColorScheme? = switch ProcessInfo.processInfo.environment["IPBAR_PANEL_SCHEME"] {
            case "dark": .dark
            case "light": .light
            default: nil
            }
            let backdrop: Color = switch scheme {
            case .dark: Color(nsColor: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1))
            case .light: Color(nsColor: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
            default: Color(nsColor: .windowBackgroundColor)
            }

            let renderer = ImageRenderer(content:
                MenuContent(model: model, preferences: preferences)
                    .background(backdrop)
                    .environment(\.colorScheme, scheme ?? .light)
            )
            renderer.scale = 2

            if let stripPath = ProcessInfo.processInfo.environment["IPBAR_STRIP_OUT"] {
                writeMenuBarStrip(model: model, preferences: preferences,
                                  dark: scheme == .dark, to: stripPath)
            }

            let path = ProcessInfo.processInfo.environment["IPBAR_PANEL_OUT"] ?? "/tmp/ipbar-panel.png"
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                emit("could not render the panel")
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: path))
            emit("wrote \(path) (\(Int(image.size.width))x\(Int(image.size.height)))")
            exit(0)
        }
    }

    /// Snapshots the real status item button, which is the only honest way to
    /// judge how the address, the flag and the label line up: everything else
    /// is a reconstruction of what the button is presumed to do.
    @MainActor
    private static func snapshot(_ button: NSStatusBarButton) {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = button.bitmapImageRepForCachingDisplay(in: bounds) else {
            emit("could not snapshot the button")
            return
        }
        button.cacheDisplay(in: bounds, to: rep)

        // Composited onto a backdrop, since the button itself is transparent
        // and the menu bar behind it is not.
        let backdrop = NSImage(size: bounds.size)
        backdrop.lockFocus()
        (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.86, blue: 0.97, alpha: 1)).setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        backdrop.unlockFocus()

        let path = ProcessInfo.processInfo.environment["IPBAR_ITEM_OUT"] ?? "/tmp/ipbar-item.png"
        guard let tiff = backdrop.tiffRepresentation,
              let flattened = NSBitmapImageRep(data: tiff),
              let png = flattened.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        emit("wrote \(path) (\(Int(bounds.width))x\(Int(bounds.height)))")
    }

    /// Draws the menu bar item as the bar itself would: the title, then the
    /// trailing image, both centred in a 22pt bar.
    @MainActor
    private static func writeMenuBarStrip(model: NetworkModel, preferences: Preferences,
                                          dark: Bool, to path: String) {
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = model.menuBarText as NSString
        let glyph = MenuBarGlyph.image(qualifier: model.menuBarQualifier,
                                       vpnLabel: model.menuBarVPNLabel,
                                       muted: preferences.mutedFlag, dark: dark)

        let ink = dark ? NSColor.white : NSColor.black
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let titleSize = title.size(withAttributes: attributes)

        let padding: CGFloat = 14
        let height: CGFloat = 24
        let width = (padding * 2 + titleSize.width + (glyph?.size.width ?? 0)).rounded(.up)

        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
              : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        title.draw(at: NSPoint(x: padding, y: (height - titleSize.height) / 2),
                   withAttributes: attributes)
        if let glyph {
            glyph.draw(in: NSRect(x: padding + titleSize.width,
                                  y: ((height - glyph.size.height) / 2).rounded(),
                                  width: glyph.size.width, height: glyph.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            emit("wrote \(path)")
        }
    }

    @MainActor
    private static func statusButtons(in view: NSView) -> [NSStatusBarButton] {
        var result: [NSStatusBarButton] = []
        if let button = view as? NSStatusBarButton { result.append(button) }
        for subview in view.subviews { result.append(contentsOf: statusButtons(in: subview)) }
        return result
    }

    @MainActor
    private static func report(_ button: NSStatusBarButton) {
        let position: String
        switch button.imagePosition {
        case .imageLeading: position = "imageLeading"
        case .imageTrailing: position = "imageTrailing"
        case .imageLeft: position = "imageLeft"
        case .imageRight: position = "imageRight"
        case .imageOnly: position = "imageOnly"
        case .noImage: position = "noImage"
        case .imageOverlaps: position = "imageOverlaps"
        case .imageAbove: position = "imageAbove"
        case .imageBelow: position = "imageBelow"
        @unknown default: position = "unknown(\(button.imagePosition.rawValue))"
        }

        var attachments = 0
        let attributed = button.attributedTitle
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }

        emit("""
        status item:
          title          "\(button.title)"
          attributed     "\(attributed.string)" (len \(attributed.length), attachments \(attachments))
          image          \(button.image.map { "\($0.size), template=\($0.isTemplate)" } ?? "nil")
          imagePosition  \(position)
          frame          \(button.frame.width) x \(button.frame.height)
        """)
    }

    private static func emit(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
