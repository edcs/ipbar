import AppKit
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
}
