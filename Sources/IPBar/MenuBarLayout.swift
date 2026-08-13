import AppKit

/// Puts the flag after the address in the menu bar.
///
/// `MenuBarExtra` does not lay its label out as written. It reduces the label
/// to an `NSStatusItem` button title plus a button image and leaves
/// `imagePosition` at `.imageLeading`, so ordering the views has no effect and
/// padding between them is discarded. The position has to be set on the button
/// itself, and re-set afterwards because SwiftUI restores it whenever the
/// label changes.
///
/// Run the app with `IPBAR_PROBE=1` to have it report what its status item
/// actually contains.
@MainActor
enum MenuBarLayout {
    static func placeFlagAfterAddress(retries: Int = 12) {
        if apply() { return }
        guard retries > 0 else { return }

        // The button does not exist for the first frames after launch.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            placeFlagAfterAddress(retries: retries - 1)
        }
    }

    @discardableResult
    private static func apply() -> Bool {
        var found = false
        for window in NSApplication.shared.windows {
            guard let root = window.contentView else { continue }
            found = apply(in: root) || found
        }
        return found
    }

    private static func apply(in view: NSView) -> Bool {
        var found = false
        if let button = view as? NSStatusBarButton {
            // .imageTrailing rather than .imageRight so it still follows the
            // text in a right-to-left layout.
            button.imagePosition = .imageTrailing
            found = true
        }
        for subview in view.subviews {
            found = apply(in: subview) || found
        }
        return found
    }
}
