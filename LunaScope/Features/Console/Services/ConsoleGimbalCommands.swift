import Foundation
import LunaTransportApple
import LunaTransportProtocol

/// 定位到记忆点的结果。限位不是失败，调用方不再报「无法恢复」。
enum ConsoleGimbalRestoreResult: Equatable {
    /// 已在记忆角度，或已经转到。
    case arrived
    /// 翻转方向不一致，没有转动。
    case flipMismatch
    /// 没到记忆角度就在限位停下，定位结束。
    case axisLimit
}

/// 在同一空闲会话内回读角度并定位；翻转只比对、不自动执行。
/// 停稳和到位都按回读角度判断，不依赖 grf：目标够不着时相机会一直回 grf = 1，靠它等只会等到超时。
@MainActor
struct ConsoleGimbalCommands {
    let session: LunaCameraSession
    let checkIdle: () async throws -> Void
    let validate: () throws -> Void
    /// 当前是否顶在轴限位上。定位等待时用来立刻结束，而不是空等超时。
    var atAxisLimit: () -> Bool = { false }

    /// 等云台停稳后回读机柄坐标；翻转状态由控制台会话记录。
    func readPosition(cameraID: UUID) async throws -> ConsoleGimbalPosition {
        try await checkIdle()
        let angle = try await waitUntilStill()
        guard let position = ConsoleGimbalPosition(cameraID: cameraID, yaw: Double(angle.yaw),
                                                   pitch: Double(angle.pitch)) else {
            throw ControlError.gimbalPosition
        }
        return position
    }

    /// 翻转一致时转到记忆角度；不一致则不动，由调用方提示用户自行翻转。
    /// 追踪刚停时云台可能还在动，先等到停稳再转角，否则相机会拒绝。
    /// - Parameter currentFlip: 本会话确认过的朝向；nil 表示还没按过回中或翻转，不参与比对。
    /// - Returns: 到位、翻转不一致，或在限位停下。
    /// - Parameter travelLimit: 转到目标的最长等待。幅度大时调用方可以放宽，避免转到一半就超时。
    @discardableResult
    func restore(
        _ position: ConsoleGimbalPosition, currentFlip: Bool?, travelLimit: Duration = .seconds(10)
    ) async throws -> ConsoleGimbalRestoreResult {
        // 没在本会话确认朝向时不比，避免重连后的空记录误报。一旦确认翻转，记忆里没写翻转也视为正向。
        if let currentFlip, (position.isFlipped ?? false) != currentFlip {
            return .flipMismatch
        }
        try await checkIdle()
        let start = try await waitUntilStill()
        if position.matchesAngles(start) { return .arrived }

        let request = try LunaProtocol.gimbalSetAngle(pitch: Float(position.pitch), yaw: Float(position.yaw))
        let reply = try await control(request, timeout: .seconds(3))
        guard !reply.isEmpty else { throw ControlError.cameraRefused }
        let reached: Bool
        do {
            reached = try await waitForTravel(to: position, from: start, limit: travelLimit)
        } catch {
            await finishMove(reached: false)
            throw error
        }
        await finishMove(reached: reached)
        return reached ? .arrived : .axisLimit
    }

    private func readAngle() async throws -> LunaGimbalAngle {
        try await LunaGimbalAngle(response: control(LunaProtocol.gimbalGetAngleRequest()))
    }

    /// 两次回读之间几乎没动。
    private static func isStill(_ first: LunaGimbalAngle, _ second: LunaGimbalAngle) -> Bool {
        abs((Double(second.yaw) - Double(first.yaw)).remainder(dividingBy: 360)) <= 0.2
            && abs(Double(second.pitch) - Double(first.pitch)) <= 0.2
    }

    /// 连续两次回读几乎不变才算停稳，返回最后一次角度。追踪刚停、摇杆刚松时云台还会滑一小段。
    private func waitUntilStill() async throws -> LunaGimbalAngle {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var last = try await readAngle()
        repeat {
            try await Task.sleep(for: .milliseconds(150))
            let angle = try await readAngle()
            if Self.isStill(last, angle) { return angle }
            last = angle
        } while clock.now < deadline
        throw ControlError.gimbalPosition
    }

    /// 等云台转到记忆角度。限位标志一亮，或转到一半停住不再前进，都立刻结束，不空等超时。
    /// - Returns: `true` 已到位；`false` 没到位就在限位停下。
    private func waitForTravel(
        to position: ConsoleGimbalPosition, from start: LunaGimbalAngle, limit: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let began = clock.now
        var last = start
        var limited = atAxisLimit()
        var moved = false
        var stillReads = 0
        while clock.now - began < limit {
            try await Task.sleep(for: .milliseconds(100))
            let angle = try await readAngle()
            if position.matchesAngles(angle) { return true }
            // 限位标志从无到有，就是这次转动顶到了头。
            let nowLimited = atAxisLimit()
            if nowLimited, !limited { return false }
            limited = nowLimited
            if Self.isStill(last, angle) {
                stillReads += 1
            } else {
                moved = true
                stillReads = 0
            }
            last = angle
            // 发出转角后约 0.1 秒才起步，一直没动时多等一会儿再下结论。
            if stillReads >= 3, moved || clock.now - began > .milliseconds(800) {
                if moved || limited { return false }
                throw ControlError.gimbalPosition
            }
        }
        throw ControlError.gimbalPosition
    }

    /// 收尾：相机若还记着没完成的转角目标，就把目标改成云台当前所在的角度，再松开摇杆。
    /// 够不着的目标会一直挂着（GET 持续回 grf = 1），云台顶着限位，之后的摇杆和定位都受影响。
    /// 相机只认最新一次 SET_ANGLE，所以用当前角度覆盖它。失败不改变定位结果。
    private func finishMove(reached: Bool) async {
        // 收尾不走 validate：中途休眠或状态变化时也要把目标清掉。
        let read = {
            try? await LunaGimbalAngle(
                response: session.control(LunaProtocol.gimbalGetAngleRequest(), timeout: .seconds(2)))
        }
        var angle = await read()
        // 正常到位后相机很快会自己报完成，稍等即可，不必改目标。
        var waits = 0
        while reached, let current = angle, current.grf != 0, waits < 5 {
            try? await Task.sleep(for: .milliseconds(150))
            angle = await read()
            waits += 1
        }
        AppLog.event("gimbal.locate reached=\(reached) grf=\(angle?.grf ?? -1) "
            + "pitch=\(angle?.pitch ?? .nan) yaw=\(angle?.yaw ?? .nan) limit=\(atAxisLimit())")
        guard let angle, angle.grf != 0,
              let hold = try? LunaProtocol.gimbalSetAngle(pitch: angle.pitch, yaw: angle.yaw),
              let release = try? LunaProtocol.gimbalReleaseRequest() else { return }
        _ = try? await session.control(hold, timeout: .seconds(2))
        _ = try? await session.control(release, timeout: .seconds(2))
    }

    private func control(_ request: LunaRequest, timeout: Duration = .seconds(2)) async throws -> Data {
        try validate()
        let reply = try await session.control(request, timeout: timeout)
        try validate()
        return reply
    }
}
