import Foundation
import LunaTransportApple
import LunaTransportProtocol
import OpenCineMotion

struct ConsoleMemory: Codable {
    struct Preset: Codable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let savedAt: Date
        let parameters: ConsoleParameters
        var profileID: String? = nil
    }

    var lastPosition: ConsoleGimbalPosition?
    var presets: [Preset] = []
}

/// 只保存一处云台姿态，绑定到实际回读它的相机。角度相对于机柄。
struct ConsoleGimbalPosition: Codable, Equatable {
    let cameraID: UUID
    let yaw: Double
    let pitch: Double
    let isFlipped: Bool?

    init?(cameraID: UUID, yaw: Double, pitch: Double, isFlipped: Bool? = nil) {
        guard yaw.isFinite, pitch.isFinite else { return nil }
        let limits = LunaCameraSession.motion.bounds
        let unwrapped = GimbalWaypoint.unwrapYaw(yaw, in: limits)
        guard limits.pan.contains(unwrapped), limits.tilt.contains(pitch) else { return nil }
        self.cameraID = cameraID
        self.yaw = yaw.remainder(dividingBy: 360)
        self.pitch = pitch
        self.isFlipped = isFlipped
    }

    func matchesAngles(_ angle: LunaGimbalAngle) -> Bool {
        let tolerance = LunaCameraSession.motion.arrivalToleranceDeg
        return angle.grf == 0 && abs((Double(angle.yaw) - yaw).remainder(dividingBy: 360)) <= tolerance
            && abs(Double(angle.pitch) - pitch) <= tolerance
    }
}

/// 将控制台的记忆保存在同一命名空间，方便隔离测试和一次写入更新。
struct ConsoleMemoryStore {
    private enum Key { static let memory = "feature.console.memory" }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> ConsoleMemory {
        guard let data = defaults.data(forKey: Key.memory) else { return ConsoleMemory() }
        return try JSONDecoder().decode(ConsoleMemory.self, from: data)
    }

    func save(_ memory: ConsoleMemory) throws {
        defaults.set(try JSONEncoder().encode(memory), forKey: Key.memory)
    }
}
