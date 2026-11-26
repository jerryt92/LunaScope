import Darwin
import Foundation
import MetricKit
import OSLog

/// 按天保存精简诊断事件。日志字段仅接受类型、事件名和应用运行标识。
actor AppLogStore {
    static let shared = AppLogStore()
    private static let retentionDays = 7
    private static let markerFile = "run-state.txt"

    private var root: URL { DiagnosticPath.root }

    func begin() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let marker = root.appending(path: Self.markerFile)
            if let previous = try? String(contentsOf: marker, encoding: .utf8), previous == "active" {
                append("app.previousRunEndedInForeground")
            }
            for file in try logFiles() where file.deletingPathExtension().lastPathComponent < oldestDay {
                try FileManager.default.removeItem(at: file)
            }
        } catch { AppLog.systemError(error, context: "diagnostics.initialize") }
    }

    func mark(active: Bool) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (active ? "active" : "inactive").write(to: root.appending(path: Self.markerFile),
                                                      atomically: true, encoding: .utf8)
        } catch { AppLog.systemError(error, context: "diagnostics.marker") }
    }

    func append(_ name: String) {
        let stamp = Date.now.ISO8601Format()
        let line = name.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        DiagnosticPath.append("\(stamp) run=\(AppLog.run) \(line)\n", to: DiagnosticPath.today.path)
    }

    /// 诊断只包含日志及运行环境，不包含参考照、位置、配对资料。
    func archive(environment: String) throws -> URL {
        let fm = FileManager.default
        let date = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let temporary = fm.temporaryDirectory.appending(path: "LunaScope-Diagnostics", directoryHint: .isDirectory)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let expire = Date.now.addingTimeInterval(-24 * 3600)
        for file in try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.creationDateKey])
        where (try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) < expire {
            try fm.removeItem(at: file)
        }
        let files = try logFiles().filter { $0.deletingPathExtension().lastPathComponent >= oldestDay }
        var logs = Data()
        for file in files { logs.append(try Data(contentsOf: file)) }
        let days = files.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")
        let info = environment + "\nLog dates: " + days + "\n"
        let output = temporary.appending(path: "LunaScope-Diagnostics-\(date).zip")
        try DiagnosticArchive.zip([("logs.txt", logs), ("info.txt", Data(info.utf8))]).write(to: output, options: .atomic)
        return output
    }

    private var oldestDay: String {
        let today = Calendar.current.startOfDay(for: .now)
        return DiagnosticPath.day(Calendar.current.date(byAdding: .day, value: 1 - Self.retentionDays, to: today) ?? today)
    }

    private func logFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// 系统 Console 与本地诊断共用入口，保留 OSLog 作为本地写入失败时的去处。
nonisolated enum AppLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LunaScope", category: "app")
    static let run = UUID().uuidString

    @MainActor static func install() {
        do { try FileManager.default.createDirectory(at: DiagnosticPath.root, withIntermediateDirectories: true) }
        catch { systemError(error, context: "diagnostics.initialize") }
        _ = DiagnosticPath.exceptionPath
        NSSetUncaughtExceptionHandler { _ in
            DiagnosticPath.append("objc.uncaughtException\n", to: DiagnosticPath.exceptionPath)
        }
        MXMetricManager.shared.add(MetricsLogSubscriber.shared)
        Task {
            await AppLogStore.shared.begin()
            await AppLogStore.shared.append("app.start version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")")
        }
    }

    static func event(_ name: String) {
        logger.info("\(name, privacy: .public) run=\(run, privacy: .public)")
        Task { await AppLogStore.shared.append(name) }
    }

    static func scene(active: Bool) {
        let name = active ? "app.active" : "app.inactive"
        logger.info("\(name, privacy: .public)")
        Task {
            await AppLogStore.shared.mark(active: active)
            await AppLogStore.shared.append(name)
        }
    }

    static func error(_ error: Error, context: String) {
        systemError(error, context: context)
        let kind = String(reflecting: type(of: error))
        Task { await AppLogStore.shared.append("error context=\(context) type=\(kind)") }
    }

    static func systemError(_ error: Error, context: String) {
        let kind = String(reflecting: type(of: error))
        logger.error("\(context, privacy: .public) error=\(kind, privacy: .public) run=\(run, privacy: .public)")
    }
}

private nonisolated enum DiagnosticPath {
    static let root = URL.applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
    static var today: URL { root.appending(path: day(.now) + ".log") }
    static let exceptionPath = today.path

    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    static func append(_ line: String, to path: String) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = Data(line.utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}

private final class MetricsLogSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsLogSubscriber()

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        AppLog.event("diagnostics.metrics batches=\(payloads.count)")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        AppLog.event("diagnostics.reports batches=\(payloads.count)")
    }
}
