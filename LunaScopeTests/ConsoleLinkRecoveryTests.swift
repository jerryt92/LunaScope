import Foundation
import XCTest
@testable import LunaScope

final class ConsoleLinkRecoveryTests: XCTestCase {
    @MainActor
    func testReconnectStopsOnFirstSuccess() async {
        var attempts = 0
        let outcome = await runConsoleReconnect(budget: .seconds(1), pause: .milliseconds(10), isCurrent: { true }) {
            attempts += 1
        }
        XCTAssertEqual(outcome, .reconnected)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testReconnectRetriesUntilBudgetThenHandsBackToUser() async {
        var attempts = 0
        let outcome = await runConsoleReconnect(budget: .milliseconds(80), pause: .milliseconds(10), isCurrent: { true }) {
            attempts += 1
            throw ControlError.cameraBusy
        }
        XCTAssertEqual(outcome, .exhausted)
        XCTAssertGreaterThanOrEqual(attempts, 2)
    }

    @MainActor
    func testReconnectStopsWhenSessionRetiredOrCancelled() async {
        var current = true
        var attempts = 0
        let outcome = await runConsoleReconnect(budget: .seconds(2), pause: .milliseconds(10), isCurrent: { current }) {
            attempts += 1
            current = false
            throw ControlError.cameraBusy
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(attempts, 1)

        let cancelled = await runConsoleReconnect(budget: .seconds(1), pause: .milliseconds(10), isCurrent: { true }) {
            throw CancellationError()
        }
        XCTAssertEqual(cancelled, .cancelled)
    }

    @MainActor
    func testReconnectSucceedsAfterTransientFailures() async {
        var attempts = 0
        let outcome = await runConsoleReconnect(budget: .seconds(2), pause: .milliseconds(5), isCurrent: { true }) {
            attempts += 1
            if attempts < 3 { throw ControlError.cameraBusy }
        }
        XCTAssertEqual(outcome, .reconnected)
        XCTAssertEqual(attempts, 3)
    }
}