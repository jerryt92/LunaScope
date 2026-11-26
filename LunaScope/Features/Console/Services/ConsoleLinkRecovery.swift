import Foundation

enum ConsoleReconnectOutcome: Equatable {
    case reconnected, exhausted, cancelled
}

/// 断线后在预算内反复重连，与 OpenInstaCine 的恢复节奏一致：约 45 秒内重试，
/// 每次失败稍作暂停，超预算交给用户手动重试。取消或会话更换立即结束。
func runConsoleReconnect(
    budget: Duration = .seconds(45),
    pause: Duration = .seconds(3),
    clock: ContinuousClock = ContinuousClock(),
    isCurrent: @escaping @MainActor () -> Bool,
    attempt: @escaping @MainActor () async throws -> Void
) async -> ConsoleReconnectOutcome {
    let deadline = clock.now.advanced(by: budget)
    while !Task.isCancelled, isCurrent() {
        do {
            try await attempt()
            return .reconnected
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard !Task.isCancelled, isCurrent() else { return .cancelled }
            let remaining = deadline - clock.now
            guard remaining > .zero else { return .exhausted }
            do { try await Task.sleep(for: min(pause, remaining)) }
            catch { return .cancelled }
        }
    }
    return .cancelled
}