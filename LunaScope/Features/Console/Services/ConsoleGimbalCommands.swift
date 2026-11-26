import Foundation
import LunaTransportApple
import LunaTransportProtocol

/// 在同一空闲会话内回读角度并归位；翻转只比对、不自动执行。
@MainActor
struct ConsoleGimbalCommands {
    let session: LunaCameraSession
    let checkIdle: () async throws -> Void
    let validate: () throws -> Void

    /// 只回读机柄坐标；翻转状态由控制台会话记录。
    func readPosition(cameraID: UUID) async throws -> ConsoleGimbalPosition {
        try await checkIdle()
        for _ in 0..<4 {
            let first = try await readAngle()
            guard first.grf == 0 else {
                try await Task.sleep(for: .milliseconds(180))
                continue
            }
            try await Task.sleep(for: .milliseconds(180))
            let second = try await readAngle()
            if let position = ConsoleGimbalPosition(cameraID: cameraID, yaw: Double(first.yaw),
                                                    pitch: Double(first.pitch)),
               position.matchesAngles(second) {
                return position
            }
        }
        throw ControlError.gimbalPosition
    }

    /// 翻转一致时只归位；不一致则不动，由调用方提示用户自行翻转。
    /// - Parameter currentFlip: 当前会话翻转，用于与记忆比对。
    /// - Returns: `true` 表示翻转方向不一致（未归位）。
    @discardableResult
    func restore(_ position: ConsoleGimbalPosition, currentFlip: Bool) async throws -> Bool {
        try await checkIdle()
        let actual = try await readAngle()
        guard actual.grf == 0 else { throw ControlError.gimbalPosition }

        if let desired = position.isFlipped, desired != currentFlip {
            return true
        }

        if !position.matchesAngles(actual) {
            try await checkIdle()
            let request = try LunaProtocol.gimbalSetAngle(pitch: Float(position.pitch), yaw: Float(position.yaw))
            let reply = try await control(request, timeout: .seconds(3))
            guard !reply.isEmpty else { throw ControlError.cameraRefused }
            _ = try await waitForAngle(or: .gimbalPosition) { position.matchesAngles($0) }
        }
        return false
    }

    private func readAngle() async throws -> LunaGimbalAngle {
        try await LunaGimbalAngle(response: control(LunaProtocol.gimbalGetAngleRequest()))
    }

    private func waitForAngle(or error: ControlError,
                              confirms: (LunaGimbalAngle) async throws -> Bool) async throws -> LunaGimbalAngle {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            let angle = try await readAngle()
            if angle.grf == 0, try await confirms(angle) { return angle }
        } while clock.now < deadline
        throw error
    }

    private func control(_ request: LunaRequest, timeout: Duration = .seconds(2)) async throws -> Data {
        try validate()
        let reply = try await session.control(request, timeout: timeout)
        try validate()
        return reply
    }
}
