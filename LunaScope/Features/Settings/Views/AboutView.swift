import SwiftUI

struct AboutView: View {
    private let appStoreURL = URL(string: "https://apps.apple.com/app/id6839451668")!
    private let privacyPolicyURL = URL(string: "https://jerryt92.github.io/apps/luna-scope/privacy/")!

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(.launchLogo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityLabel(Text(verbatim: "LunaScope"))

                    Text(verbatim: "© 2026 jerryt92.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: appStoreURL) {
                    HStack {
                        Text("settings.about.version")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(verbatim: appVersion)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(Text("settings.about.version"))
                .accessibilityValue(Text(verbatim: appVersion))
                .accessibilityIdentifier("settings.about.version")

                Link("settings.about.privacy", destination: privacyPolicyURL)

                NavigationLink("settings.about.licenses") { OpenSourceLicensesView() }
                    .accessibilityIdentifier("settings.about.licenses")
            }
        }
        .navigationTitle("settings.about.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}
