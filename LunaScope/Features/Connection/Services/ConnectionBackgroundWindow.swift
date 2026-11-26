import UIKit

/// 连接离开前台时申请系统后台时间；录像 / 连拍期间到期会续约，尽量把拍摄跑完。
@MainActor
final class ConnectionBackgroundWindow {
    private var task = UIBackgroundTaskIdentifier.invalid
    /// 仍需后台保活（录像或连拍进行中）时，到期后立即再申请一段。
    private var keepAlive = false

    func begin(keepAlive: Bool = false) {
        if keepAlive { self.keepAlive = true }
        requestIfNeeded()
    }

    func end() {
        keepAlive = false
        finishCurrentTask()
    }

    private func requestIfNeeded() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "CameraConnection") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finishCurrentTask()
                // 拍摄仍在进行时续约；系统最终仍可能拒绝，但应尽量撑过连拍间隔。
                if self.keepAlive {
                    self.requestIfNeeded()
                }
            }
        }
        if task == .invalid {
            keepAlive = false
        }
    }

    private func finishCurrentTask() {
        guard task != .invalid else { return }
        let current = task
        task = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
