import SwiftUI

/// 装配跨页面共享的相机连接。
@main
struct LunaScopeApp: App {
    @StateObject private var connection = CameraConnectionLifetime()
    @Environment(\.scenePhase) private var scenePhase

    init() { AppLog.install() }

    var body: some Scene {
        WindowGroup {
            RootView(camera: connection.camera)
                .modifier(KeyboardDoneBar())
                .preferredColorScheme(.dark)
                // 直接观察相机关键态，确保录像 / 连拍能刷新实时活动。
                .onChange(of: activityInputs, initial: true) { _, _ in
                    connection.present(connection.presentation(in: scenePhase))
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            connection.sceneChanged(phase)
            connection.present(connection.presentation(in: phase))
        }
    }

    /// 汇总会驱动实时活动文案的输入，任一变化即重算展示。
    private var activityInputs: ActivityInputs {
        ActivityInputs(
            selected: connection.camera.selectedCamera != nil,
            connected: connection.camera.connected,
            dropped: connection.camera.connectionDropped,
            reconnecting: connection.camera.reconnecting,
            recording: connection.camera.recording,
            continuous: connection.camera.continuousShooting,
            continuousInterval: connection.camera.continuousShooting
                ? connection.camera.continuousInterval.seconds : nil,
            phase: scenePhase
        )
    }
}

/// 实时活动依赖的可比较快照。
private struct ActivityInputs: Equatable {
    let selected: Bool
    let connected: Bool
    let dropped: Bool
    let reconnecting: Bool
    let recording: Bool
    let continuous: Bool
    /// 连拍进行中的间隔秒数，改间隔时刷新实时活动。
    let continuousInterval: Double?
    let phase: ScenePhase
}
