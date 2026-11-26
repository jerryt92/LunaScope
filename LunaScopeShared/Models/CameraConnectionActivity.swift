import ActivityKit

/// 主应用和小组件共享相机会话状态。锁屏不显示配对信息；
/// 录像 / 连拍也会反映在此，便于后台时保持可见并降低被系统挂起的体感。
nonisolated struct CameraConnectionActivity: ActivityAttributes {
    enum Status: String, Codable, Hashable, Sendable {
        case connecting, connected, recording, continuous
        case background, verifying, reconnecting, disconnected
    }

    struct ContentState: Codable, Hashable, Sendable {
        let status: Status
    }
}
