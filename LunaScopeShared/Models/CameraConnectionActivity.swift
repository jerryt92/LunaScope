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
        /// 连续拍摄间隔（秒）。仅连拍进行中有值。
        let intervalSeconds: Double?

        private enum CodingKeys: String, CodingKey {
            case status, intervalSeconds
        }

        init(status: Status, intervalSeconds: Double? = nil) {
            self.status = status
            self.intervalSeconds = intervalSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            intervalSeconds = try container.decodeIfPresent(Double.self, forKey: .intervalSeconds)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(intervalSeconds, forKey: .intervalSeconds)
        }
    }
}
