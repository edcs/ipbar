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
        StatusItemProbe.startIfRequested()
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: NetworkModel(preferences: preferences))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, preferences: preferences)
        } label: {
            // MenuBarExtra reduces this to a status item title plus a single
            // image, so the order written here is not the order drawn and any
            // padding is discarded. MenuBarLayout moves the image after the
            // title; the gap before the flag is baked into the image.
            MenuBarLabel(model: model, preferences: preferences)
            .task {
                model.start()
                MenuBarLayout.placeFlagAfterAddress()
            }
            // SwiftUI puts imagePosition back whenever the label changes.
            .onChange(of: model.menuBarText) { MenuBarLayout.placeFlagAfterAddress() }
            .onChange(of: model.menuBarQualifier) { MenuBarLayout.placeFlagAfterAddress() }
        }
        .menuBarExtraStyle(.window)

        Window("IPBar Settings", id: Self.settingsWindowID) {
            SettingsView(model: model, preferences: preferences)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The menu bar's own label.
///
/// A view of its own so it can read the colour scheme: text baked into the
/// trailing image carries the colour it was drawn with, and SwiftUI rebuilds
/// this when the system switches between light and dark.
private struct MenuBarLabel: View {
    @Bindable var model: NetworkModel
    @Bindable var preferences: Preferences
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            Text(model.menuBarText)
            if let glyph = MenuBarGlyph.image(qualifier: model.menuBarQualifier,
                                              vpnLabel: model.menuBarVPNLabel,
                                              muted: preferences.mutedFlag,
                                              dark: colorScheme == .dark) {
                Image(nsImage: glyph)
            }
        }
    }
}
