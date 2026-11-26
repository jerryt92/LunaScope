import Foundation

/// 参数下发重试与确认超时，持久化到 UserDefaults，供高级设置与命令队列共用。
/// UserDefaults 读写本身可跨线程；标 nonisolated，以便作默认参数（默认实参在非隔离上下文求值）。
enum ConsoleCommandPreferences: Sendable {
    nonisolated static let retryLimitKey = "settings.command.retryLimit"
    nonisolated static let confirmTimeoutKey = "settings.command.confirmTimeoutSeconds"

    nonisolated static let defaultRetryLimit = 1
    nonisolated static let defaultConfirmTimeoutSeconds = 5
    nonisolated static let retryLimitRange = 0...5
    nonisolated static let confirmTimeoutRange = 2...20

    /// 瞬时失败自动重试次数（不含首次尝试）。
    nonisolated static var retryLimit: Int {
        get { clamped(UserDefaults.standard.object(forKey: retryLimitKey) as? Int ?? defaultRetryLimit,
                      in: retryLimitRange) }
        set { UserDefaults.standard.set(clamped(newValue, in: retryLimitRange), forKey: retryLimitKey) }
    }

    /// 等待相机回读确认的秒数。
    nonisolated static var confirmTimeoutSeconds: Int {
        get { clamped(UserDefaults.standard.object(forKey: confirmTimeoutKey) as? Int ?? defaultConfirmTimeoutSeconds,
                      in: confirmTimeoutRange) }
        set { UserDefaults.standard.set(clamped(newValue, in: confirmTimeoutRange), forKey: confirmTimeoutKey) }
    }

    nonisolated static var confirmSettle: Duration { .seconds(confirmTimeoutSeconds) }

    nonisolated static func clampedRetryLimit(_ value: Int) -> Int {
        clamped(value, in: retryLimitRange)
    }

    nonisolated static func clampedConfirmTimeout(_ value: Int) -> Int {
        clamped(value, in: confirmTimeoutRange)
    }

    nonisolated private static func clamped(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
