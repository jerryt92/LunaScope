import ActivityKit
import Foundation

/// 一次相机会话对应一个实时活动。系统设置或用户手动关闭活动时，连接照常运行。
@MainActor
final class ConnectionActivityCoordinator {
    struct Presentation: Equatable {
        let status: CameraConnectionActivity.Status
        let canStart: Bool
    }

    private typealias ConnectionActivity = Activity<CameraConnectionActivity>
    private var activity: ConnectionActivity?
    private var presentation: Presentation?
    private var lastPresented: Presentation?
    private var worker: Task<Void, Never>?
    private var didCleanUp = false

    func submit(_ presentation: Presentation?) {
        self.presentation = presentation
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { worker = nil }
            if !didCleanUp {
                didCleanUp = true
                for existing in ConnectionActivity.activities {
                    await existing.end(nil, dismissalPolicy: .immediate)
                }
            }
            repeat {
                let requested = self.presentation
                await synchronize(requested)
                if requested == self.presentation { return }
            } while !Task.isCancelled
        }
    }

    private func synchronize(_ requested: Presentation?) async {
        guard let requested else {
            let previous = activity
            activity = nil
            lastPresented = nil
            await previous?.end(nil, dismissalPolicy: .immediate)
            return
        }
        guard requested != lastPresented else { return }
        let state = CameraConnectionActivity.ContentState(status: requested.status)
        let content = ActivityContent(state: state, staleDate: requested.canStart ? nil : .now.addingTimeInterval(30))
        if let activity {
            if activity.activityState == .active || activity.activityState == .stale {
                await activity.update(content)
            }
        } else if requested.canStart && ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try ConnectionActivity.request(attributes: .init(), content: content, pushType: nil)
            } catch { AppLog.error(error, context: "connection.activity.start") }
        }
        lastPresented = requested
    }
}
