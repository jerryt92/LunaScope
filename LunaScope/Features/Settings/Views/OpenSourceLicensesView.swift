import SwiftUI

struct OpenSourceLicensesView: View {
    private let openCineURL = URL(string: "https://github.com/erik-sutton95/OpenCine")!
    private let kcpURL = URL(string: "https://github.com/skywind3000/kcp")!

    var body: some View {
        List {
            Section {
                Text("settings.licenses.usage.openCine")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                sourceLink("erik-sutton95/OpenCine", url: openCineURL)
                    .accessibilityIdentifier("settings.licenses.source.openCine")
                licenseLink("settings.licenses.apache", resource: "OpenCine-License")
                licenseLink("settings.licenses.notice", resource: "OpenCine-Notice")
                licenseLink("settings.licenses.thirdPartyNotices", resource: "OpenCine-Third-Party-Notices")
            } header: {
                Text(verbatim: "OpenCine / LunaScopeTransport")
            }

            Section {
                Text("settings.licenses.usage.kcp")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                sourceLink("skywind3000/kcp", url: kcpURL)
                    .accessibilityIdentifier("settings.licenses.source.kcp")
                licenseLink("settings.licenses.mit", resource: "KCP-License")
            } header: {
                Text(verbatim: "KCP")
            }
        }
        .navigationTitle("settings.about.licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sourceLink(_ repository: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(verbatim: repository)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote)
                    .accessibilityHidden(true)
            }
        }
    }

    private func licenseLink(_ title: LocalizedStringKey, resource: String) -> some View {
        NavigationLink {
            LicenseDocumentView(title: title, resource: resource)
        } label: {
            Text(title)
        }
        .accessibilityIdentifier("settings.license.\(resource)")
    }
}

private struct LicenseDocumentView: View {
    let title: LocalizedStringKey
    let resource: String

    private var contents: String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        ScrollView {
            if let contents {
                Text(verbatim: contents)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("settings.license.contents")
            } else {
                Text("settings.licenses.unavailable")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
