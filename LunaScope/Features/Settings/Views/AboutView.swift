import SwiftUI

struct AboutView: View {
    private let developerEmail = "jerrytian92@outlook.com"
    private let appStoreURL = URL(string: "https://apps.apple.com/app/id6839451668")!
    private let supportURL = URL(string: "https://jerryt92.github.io/apps/luna-scope/support/")!
    private let privacyPolicyURL = URL(string: "https://jerryt92.github.io/apps/luna-scope/privacy/")!
    private let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

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
                externalLink("settings.about.version", destination: appStoreURL, value: appVersion)
                    .accessibilityLabel(Text("settings.about.version"))
                    .accessibilityValue(Text(verbatim: appVersion))
                    .accessibilityIdentifier("settings.about.version")

                externalLink("settings.about.support", destination: supportURL)
                externalLink(
                    "settings.about.developerEmail",
                    destination: URL(string: "mailto:\(developerEmail)")!,
                    value: developerEmail
                )
            }

            Section {
                externalLink("settings.about.privacy", destination: privacyPolicyURL)
                externalLink("settings.about.termsOfUse", destination: termsOfUseURL)

                NavigationLink("settings.about.licenses") { OpenSourceLicensesView() }
                    .accessibilityIdentifier("settings.about.licenses")
            }
        }
        .navigationTitle("settings.about.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func externalLink(_ title: LocalizedStringKey, destination: URL, value: String? = nil) -> some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if let value {
                    Text(verbatim: value)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Image(systemName: "arrow.up.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
