import Foundation
import LunaTransportApple
import LunaTransportProtocol

/// 定位到记忆点的结果。限位不是失败，调用方不再报「无法移动」。
enum ConsoleGimbalRestoreResult: Equatable {
    /// 已在记忆角度，或已经转到。
    case arrived
    /// 翻转方向不一致，没有转动。
    case flipMismatch
    /// 转到轴限位后停下，定位结束。
    case axisLimit
}

/// 在同一空闲会话内回读角度并归位；翻转只比对、不自动执行。
@MainActor
struct ConsoleGimbalCommands {
    let session: LunaCameraSession
    let checkIdle: () async throws -> Void
    let validate: () throws -> Void
    /// 当前是否顶在轴限位上。定位等待时用来立刻结束，而不是空等超时。
    var atAxisLimit: () -> Bool = { false }

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
    /// 追踪刚停时云台可能还在动，先等到停稳再转角，否则相机会拒绝。
    /// - Parameter currentFlip: 本会话确认过的朝向；nil 表示还没按过回中或翻转，不参与比对。
    /// - Returns: 到位、翻转不一致，或已在限位停下。
    @discardableResult
    func restore(_ position: ConsoleGimbalPosition, currentFlip: Bool?) async throws -> ConsoleGimbalRestoreResult {
        try await checkIdle()
        let actual = try await waitForAngle(or: .gimbalPosition) { _ in true }

        // 没在本会话确认朝向时不比，避免重连后的空记录误报。一旦确认翻转，记忆里没写翻转也视为正向。
        if let currentFlip, (position.isFlipped ?? false) != currentFlip {
            return .flipMismatch
        }

        if !position.matchesAngles(actual) {
            try await checkIdle()
            let request = try LunaProtocol.gimbalSetAngle(pitch: Float(position.pitch), yaw: Float(position.yaw))
            let reply = try await control(request, timeout: .seconds(3))
            guard !reply.isEmpty else { throw ControlError.cameraRefused }
            // SET_ANGLE 会占住云台；边缘点顶死后摇杆无效，结束时必须松开。
            let arrived: Bool
            do {
                arrived = try await waitUntilArrived(position)
            } catch {
                await releaseAngleHold()
                throw error
            }
            await releaseAngleHold()
            if !arrived { return .axisLimit }
        }
        return .arrived
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

    /// 等到记忆角度，或一顶到限位就返回。起步时若本来就在限位上，允许先离开再判断。
    /// - Returns: `true` 已到位；`false` 停在限位。
    private func waitUntilArrived(_ position: ConsoleGimbalPosition) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        var leftTheStop = !atAxisLimit()
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            let angle = try await readAngle()
            if position.matchesAngles(angle) { return true }
            let limited = atAxisLimit()
            if !limited { leftTheStop = true }
            if limited, leftTheStop || angle.grf == 0 { return false }
        } while clock.now < deadline
        throw ControlError.gimbalPosition
    }

    /// 结束 SET_ANGLE 对云台的占用，摇杆才能再次推动。失败不改变定位结果。
    private func releaseAngleHold() async {
        guard let request = try? LunaProtocol.gimbalReleaseRequest() else { return }
        _ = try? await session.control(request, timeout: .seconds(2))
    }

    private func control(_ request: LunaRequest, timeout: Duration = .seconds(2)) async throws -> Data {
        try validate()
        let reply = try await session.control(request, timeout: timeout)
        try validate()
        return reply
    }
}
