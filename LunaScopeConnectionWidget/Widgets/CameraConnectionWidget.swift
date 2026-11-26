import ActivityKit
import SwiftUI
import WidgetKit

/// 展示实时连接与拍摄状态，点按由系统打开 App。
@main
struct CameraConnectionWidget: Widget {
    private let accent = Color("AccentColor")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CameraConnectionActivity.self) { context in
            lockScreen(context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 左右等重图标，文案放底部全宽，避免展开态左右不对称。
                DynamicIslandExpandedRegion(.leading) {
                    logoMark(size: 26)
                        .frame(width: 28, height: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusGlyph(context, size: 18)
                        .frame(width: 28, height: 28)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 3) {
                        Text("activity.camera.title")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                        Text(title(context))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
            } compactLeading: {
                logoMark(size: 18)
            } compactTrailing: {
                statusGlyph(context, size: 14)
                    .accessibilityLabel(Text(title(context)))
            } minimal: {
                statusGlyph(context, size: 14)
                    .accessibilityLabel(Text(title(context)))
            }
        }
    }

    /// 锁屏横幅：加高版，品牌与状态纵向排开，视觉更稳。
    private func lockScreen(_ context: ActivityViewContext<CameraConnectionActivity>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                logoMark(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("activity.camera.title")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(title(context))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                statusGlyph(context, size: 22)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.12, blue: 0.14),
                            Color(red: 0.04, green: 0.07, blue: 0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                }
        }
        .padding(4)
        .activityBackgroundTint(Color(red: 0.04, green: 0.07, blue: 0.08))
        .activitySystemActionForegroundColor(accent)
    }

    private func logoMark(size: CGFloat) -> some View {
        Image("ActivityLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func statusGlyph(
        _ context: ActivityViewContext<CameraConnectionActivity>, size: CGFloat
    ) -> some View {
        Image(systemName: symbol(context))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(glyphColor(context))
            .symbolEffect(.pulse, isActive: pulses(context))
    }

    private func title(_ context: ActivityViewContext<CameraConnectionActivity>) -> LocalizedStringKey {
        if context.isStale { return "activity.camera.stale" }
        return switch context.state.status {
        case .connecting: "activity.camera.connecting"
        case .connected: "activity.camera.connected"
        case .recording: "activity.camera.recording"
        case .continuous: "activity.camera.continuous"
        case .background: "activity.camera.background"
        case .verifying: "activity.camera.verifying"
        case .reconnecting: "activity.camera.reconnecting"
        case .disconnected: "activity.camera.disconnected"
        }
    }

    private func symbol(_ context: ActivityViewContext<CameraConnectionActivity>) -> String {
        if context.isStale { return "clock" }
        return switch context.state.status {
        case .recording: "record.circle"
        case .continuous: "timer"
        case .connected: "link"
        case .disconnected: "exclamationmark.circle"
        case .background: "clock"
        default: "arrow.clockwise"
        }
    }

    private func glyphColor(_ context: ActivityViewContext<CameraConnectionActivity>) -> Color {
        if context.isStale { return .secondary }
        return switch context.state.status {
        case .recording, .continuous: .red
        case .disconnected: Color(red: 1, green: 0.59, blue: 0.52)
        case .connected: accent
        default: accent.opacity(0.9)
        }
    }

    private func pulses(_ context: ActivityViewContext<CameraConnectionActivity>) -> Bool {
        guard !context.isStale else { return false }
        switch context.state.status {
        case .recording, .continuous, .connecting, .reconnecting, .verifying: return true
        default: return false
        }
    }
}
