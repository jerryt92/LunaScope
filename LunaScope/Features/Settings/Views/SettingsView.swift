import SwiftUI

/// 设置页：权限检查、高级设置、使用声明和关于。
struct SettingsView: View {
    let onShowAnnouncement: () -> Void

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    PermissionCheckView()
                } label: {
                    Label("permissions.check.title", systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("settings.permissions")

                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("settings.advanced.title", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("settings.advanced")

                Button(action: onShowAnnouncement) {
                    Label {
                        Text("settings.news.title")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.tint)
                    }
                    // 纯文本按钮默认只包住文字；拉满行宽后，点这一行的空白也会打开声明。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.news.button")

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

#Preview { SettingsView {} }
