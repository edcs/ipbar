import SwiftUI

@main
struct IPBarApp: App {
    /// Settings lives in a plain `Window` rather than the `Settings` scene.
    /// `SettingsLink` opens that scene behind every other app when the host is
    /// an accessory (`LSUIElement`) app, so the button appears to do nothing.
    /// An explicit window can be opened and activated, which works.
    static let settingsWindowID = "settings"

    @State private var preferences: Preferences
    @State private var model: NetworkModel

    init() {
        Diagnostics.runIfRequested()
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: NetworkModel(preferences: preferences))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, preferences: preferences)
        } label: {
            // Status, then content, then qualifier: the VPN symbol prefixes as
            // a status conventionally does, while the flag follows the address
            // it qualifies rather than preceding it.
            HStack(spacing: 4) {
                if let symbol = model.menuBarSymbol {
                    Image(systemName: symbol)
                }
                Text(model.menuBarText)
                if preferences.flagVisibility.showsInMenuBar,
                   let country = model.country,
                   let flag = FlagStore.shared.menuBarImage(for: country,
                                                            muted: preferences.mutedFlag) {
                    Image(nsImage: flag)
                        // Wider than the gap between the status symbol and the
                        // address: that pair reads as one unit, whereas the
                        // flag is a separate qualifier and wants to sit apart.
                        .padding(.leading, 6)
                        // Centring on the line box sits the flag optically low,
                        // because the box carries descender space the caps do
                        // not. The extra bottom padding lifts it back.
                        .padding(.bottom, 1)
                }
            }
            .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Window("IPBar Settings", id: Self.settingsWindowID) {
            SettingsView(model: model, preferences: preferences)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
