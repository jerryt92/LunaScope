import SwiftUI

/// 覆盖在界面前方的轻提示：样式接近 alert，但整层不拦截点击。
/// 展示时长由 `CameraController.showNotice` 统一调度，默认两秒后关闭。
struct ConsoleNoticeOverlay: View {
    let camera: CameraController

    private var banner: Banner? {
        if let notice = camera.notice {
            return Banner(text: notice.text, isError: notice.isError)
        }
        if let error = camera.settingsError {
            return Banner(text: error, isError: true)
        }
        return nil
    }

    var body: some View {
        ZStack {
            if let banner {
                VStack(spacing: 10) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(banner.isError ? Palette.error : Palette.accent)
                    Text(banner.text)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 320)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Palette.border.opacity(0.9))
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                .padding(.horizontal, 28)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityIdentifier("console.notice.overlay")
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.22), value: banner)
        // 整层穿透，不挡住预览、快门、菜单等操作。
        .allowsHitTesting(false)
    }

    private struct Banner: Equatable {
        let text: String
        let isError: Bool
    }
}
