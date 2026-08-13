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
            HStack(spacing: 4) {
                if let symbol = model.menuBarSymbol {
                    Image(systemName: symbol)
                }
                if preferences.flagVisibility.showsInMenuBar,
                   let country = model.country,
                   let flag = FlagStore.shared.menuBarImage(for: country,
                                                            muted: preferences.mutedFlag) {
                    Image(nsImage: flag)
                }
                Text(model.menuBarText)
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
