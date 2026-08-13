import AppKit
import Foundation

/// Dumps what the menu bar item actually ended up containing.
///
/// `MenuBarExtra` renders its label through an `NSStatusItem`, and there is no
/// way to see the result from outside the process without screen recording.
/// Run with `IPBAR_PROBE=1` to have the app report its own status item.
enum StatusItemProbe {
    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["IPBAR_PROBE"] == "1" else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            var found = 0
            for window in NSApplication.shared.windows {
                guard let root = window.contentView else { continue }
                for button in statusButtons(in: root) {
                    found += 1
                    report(button)
                }
            }
            if found == 0 { emit("no NSStatusBarButton found in \(NSApplication.shared.windows.count) windows") }
            exit(0)
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
