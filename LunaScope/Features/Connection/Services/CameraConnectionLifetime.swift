import Combine
import SwiftUI

/// 各窗口共用相机会话，让实时活动和后台任务跟随整个 App 的前后台与拍摄状态。
@MainActor
final class CameraConnectionLifetime: ObservableObject {
    let camera = CameraController()
    private let activity = ConnectionActivityCoordinator()
    private let backgroundWindow = ConnectionBackgroundWindow()
    /// 连拍 / 录像真正保活：激活已声明的 audio 后台模式；实时活动本身不能保活。
    private let captureKeepAlive = CaptureBackgroundKeepAlive()
    private var leftForeground = false

    init() {
        // 画中画结束时会关掉音频会话，立刻按拍摄态抢回，避免连拍空窗。
        camera.pictureInPicture.onAudioSessionReleased = { [weak self] in
            self?.captureKeepAlive.reassertAfterAudioRelease()
        }
    }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // 前台不再需要 UIBackgroundTask；音频保活仍由拍摄态单独维持。
            backgroundWindow.end()
            camera.sceneBecameActive(verifyConnection: leftForeground && !camera.pictureInPicture.isActive)
            leftForeground = false
        case .inactive:
            extendBackgroundConnection()
        case .background:
            leftForeground = true
            camera.sceneEnteredBackground()
            extendBackgroundConnection()
        @unknown default:
            break
        }
        syncCaptureKeepAlive()
        AppLog.scene(active: phase == .active)
    }

    func presentation(in phase: ScenePhase) -> ConnectionActivityCoordinator.Presentation? {
        guard camera.selectedCamera != nil else { return nil }
        let capturing = camera.recording || camera.continuousShooting
        let status: CameraConnectionActivity.Status
        if camera.connectionDropped { status = .disconnected }
        else if camera.reconnecting { status = .reconnecting }
        // 录像 / 连拍优先。
        else if camera.connected, camera.recording { status = .recording }
        else if camera.connected, camera.continuousShooting { status = .continuous }
        // 已连通时保持 connected：后台/前台探活不再切到 background、verifying，避免「连接中/已连接」反复跳。
        else if camera.connected { status = .connected }
        else { status = .connecting }
        let keepFresh = phase == .active || capturing
        let interval = status == .continuous ? camera.continuousInterval.seconds : nil
        return .init(status: status, intervalSeconds: interval, canStart: keepFresh)
    }

    func present(_ presentation: ConnectionActivityCoordinator.Presentation?) {
        activity.submit(presentation)
        syncCaptureKeepAlive()
        let capturing = presentation?.status == .recording || presentation?.status == .continuous
        switch presentation?.status {
        case nil, .disconnected:
            backgroundWindow.end()
        case .recording, .continuous:
            // 辅助保活：音频会话才是主通道，后台任务作短时兜底。
            backgroundWindow.begin(keepAlive: true)
        case .connecting, .connected, .background, .verifying, .reconnecting:
            if leftForeground {
                backgroundWindow.begin(keepAlive: false)
            } else if !capturing {
                backgroundWindow.end()
            }
        }
    }

    private func extendBackgroundConnection() {
        guard camera.selectedCamera != nil, !camera.connectionDropped else { return }
        let capturing = camera.recording || camera.continuousShooting
        backgroundWindow.begin(keepAlive: capturing)
        syncCaptureKeepAlive()
    }

    private func syncCaptureKeepAlive() {
        captureKeepAlive.sync(
            captureActive: camera.recording || camera.continuousShooting,
            pipActive: camera.pictureInPicture.isActive
        )
    }
}
