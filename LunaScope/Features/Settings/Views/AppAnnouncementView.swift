import SwiftUI

/// 启动时展示一次的使用声明，也可从设置中再次打开。
struct AppAnnouncementView: View {
    /// 发布新声明时更换。应用只把它和上次展示的标识比较。
    static let announcementID = "unofficial-sdk-1"
    static let lastShownDefaultsKey = "news.lastShownID"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    statementRow(
                        title: "news.sdk.title",
                        detail: "news.sdk.detail",
                        icon: "lock.open.fill",
                        tint: .orange
                    )
                    statementRow(
                        title: "news.stability.title",
                        detail: "news.stability.detail",
                        icon: "exclamationmark.triangle.fill",
                        tint: .yellow
                    )
                    statementRow(
                        title: "news.privacy.title",
                        detail: "news.privacy.detail",
                        icon: "lock.shield.fill",
                        tint: .green
                    )
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    dismiss()
                } label: {
                    Text("news.done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("news.done")
                .frame(maxWidth: 480)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// 声明标题区，使用和关于页相同的应用图标。
    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(.launchLogo)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityLabel(Text(verbatim: "LunaScope"))

            Text("news.title")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("news.title")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.16, blue: 0.28), Color(red: 0.16, green: 0.28, blue: 0.42)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
                Image(.launchLogo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .opacity(0.12)
                    .rotationEffect(.degrees(12))
                    .offset(x: 36, y: -28)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
    }

    /// 一条声明：图标、标题和说明。
    private func statementRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}
