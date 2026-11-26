import Foundation

/// App 侧「连续拍摄」的间隔配置。相机仍走单张照片模式，间隔由控制台调度。
struct ConsoleShootInterval: Equatable, Codable, Hashable {
    /// 预设秒数：1、2、5、10、30、60、120、300。
    static let presets: [TimeInterval] = [1, 2, 5, 10, 30, 60, 120, 300]
    static let minimumCustomSeconds: TimeInterval = 1
    static let maximumCustomSeconds: TimeInterval = 60 * 60

    enum Selection: Equatable, Codable, Hashable {
        case preset(TimeInterval)
        case custom(TimeInterval)
    }

    var selection: Selection

    init(selection: Selection = .preset(5)) {
        self.selection = Self.normalized(selection)
    }

    /// 实际等待的秒数。
    var seconds: TimeInterval {
        switch selection {
        case .preset(let value), .custom(let value): value
        }
    }

    var isCustom: Bool {
        if case .custom = selection { return true }
        return false
    }

    /// 参数记忆摘要用的间隔文案。
    var summaryLabel: String {
        let value = seconds
        if value >= 60, value.truncatingRemainder(dividingBy: 60) == 0 {
            return String(localized: "console.interval.minutes \(Int(value / 60))")
        }
        if value == value.rounded() {
            return String(localized: "console.interval.seconds \(Int(value))")
        }
        let text = value.formatted(.number.precision(.fractionLength(0...2)))
        return String(localized: "console.interval.secondsText \(text)")
    }

    /// 解析自定义输入：数值加秒或分钟单位。
    static func custom(amount: Double, unit: Unit) -> Selection? {
        guard amount.isFinite, amount > 0 else { return nil }
        let seconds = amount * unit.seconds
        guard (minimumCustomSeconds...maximumCustomSeconds).contains(seconds) else { return nil }
        return .custom(seconds)
    }

    enum Unit: String, CaseIterable, Identifiable {
        case seconds, minutes
        var id: Self { self }
        var seconds: TimeInterval { self == .seconds ? 1 : 60 }
    }

    private static func normalized(_ selection: Selection) -> Selection {
        switch selection {
        case .preset(let value):
            let match = presets.first { abs($0 - value) < 0.001 } ?? presets[1]
            return .preset(match)
        case .custom(let value):
            let clamped = min(max(value, minimumCustomSeconds), maximumCustomSeconds)
            return .custom(clamped)
        }
    }
}

/// 连续拍摄调度：下一张只能在上一张完成后触发，并至少间隔指定秒数。
enum ConsoleContinuousCapture {
    /// 计算完成上一张后还需等待多久再开拍。长曝光超过间隔时返回 0。
    static func delayBeforeNextShot(interval: TimeInterval, started: Date, completed: Date,
                                    now: Date = Date()) -> TimeInterval {
        guard interval.isFinite, interval > 0, completed >= started else { return 0 }
        let earliest = started.addingTimeInterval(interval)
        let readyAt = max(completed, earliest)
        return max(0, readyAt.timeIntervalSince(now))
    }
}
