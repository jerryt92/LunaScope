import SwiftUI
import UIKit

/// 从键盘结束帧和第一响应者推断是否需要完成条。页面切换和回后台时清理旧帧。
struct KeyboardDoneBar: ViewModifier {
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if visible {
                    HStack {
                        Spacer()
                        Button("common.done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                            to: nil, from: nil, for: nil)
                            visible = false
                        }
                        .accessibilityIdentifier("common.keyboard.done")
                        .padding(.horizontal)
                        .frame(minHeight: 44)
                    }
                    .background(.bar)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                let frame = ($0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first(where: \.isKeyWindow)
                if let frame, let window {
                    let keyboardInWindow = window.convert(frame, from: window.screen.coordinateSpace)
                    let covered = window.bounds.intersection(keyboardInWindow)
                    visible = scenePhase == .active && covered.height > window.safeAreaInsets.bottom + 44
                } else { visible = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                visible = false
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { visible = false } }
            .onChange(of: verticalSizeClass) { _, _ in visible = false }
    }
}
