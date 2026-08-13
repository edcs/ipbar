import SwiftUI

@main
struct IPBarApp: App {
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
            HStack(spacing: 3) {
                if let symbol = model.menuBarSymbol {
                    Image(systemName: symbol)
                }
                Text(model.menuBarText)
            }
            .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, preferences: preferences)
        }
    }
}
