import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("settings.advanced.title", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("settings.advanced")

                NavigationLink {
                    AboutView()
                } label: {
                    Label("settings.about.title", systemImage: "info.circle.fill")
                }
                .accessibilityIdentifier("settings.about")
            }
            .navigationTitle("tab.settings")
        }
    }
}

#Preview { SettingsView() }
