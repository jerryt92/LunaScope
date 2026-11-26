import SwiftUI
import UIKit

struct AdvancedSettingsView: View {
    @AppStorage(ConsoleCommandPreferences.retryLimitKey) private var retryLimit =
        ConsoleCommandPreferences.defaultRetryLimit
    @AppStorage(ConsoleCommandPreferences.confirmTimeoutKey) private var confirmTimeoutSeconds =
        ConsoleCommandPreferences.defaultConfirmTimeoutSeconds
    @State private var archive: URL?
    @State private var preparing = false
    @State private var error: String?
    @State private var showsRestoreConfirmation = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $retryLimit,
                        in: ConsoleCommandPreferences.retryLimitRange) {
                    LabeledContent("settings.command.retryLimit") {
                        Text("\(retryLimit)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.command.retryLimit")

                Stepper(value: $confirmTimeoutSeconds,
                        in: ConsoleCommandPreferences.confirmTimeoutRange) {
                    LabeledContent("settings.command.confirmTimeout") {
                        Text("settings.command.confirmTimeoutValue \(confirmTimeoutSeconds)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.command.confirmTimeout")
            } header: {
                Text("settings.command.title")
            } footer: {
                Text("settings.command.detail")
            }

            Section {
                Button("settings.restoreDefaults", role: .destructive) {
                    showsRestoreConfirmation = true
                }
                .accessibilityIdentifier("settings.restoreDefaults")
            } footer: {
                Text("settings.restoreDefaults.detail")
            }

            Section {
                if preparing { ProgressView("settings.diagnostics.preparing") }
                else if let archive {
                    ShareLink(item: archive) { Label("settings.diagnostics.share", systemImage: "square.and.arrow.up") }
                }
                Button("settings.diagnostics.create", action: prepare).disabled(preparing)
            } header: {
                Text("settings.diagnostics.title")
            } footer: {
                Text("settings.diagnostics.detail")
            }
        }
        .navigationTitle("settings.advanced.title")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: retryLimit) { _, value in
            retryLimit = ConsoleCommandPreferences.clampedRetryLimit(value)
        }
        .onChange(of: confirmTimeoutSeconds) { _, value in
            confirmTimeoutSeconds = ConsoleCommandPreferences.clampedConfirmTimeout(value)
        }
        .alert(
            "settings.restoreDefaults",
            isPresented: $showsRestoreConfirmation
        ) {
            Button("settings.restoreDefaults.confirm", role: .destructive, action: restoreDefaults)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.restoreDefaults.message")
        }
        .alert("settings.diagnostics.error", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("common.done") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// 恢复参数下发偏好，并同步本页 @AppStorage 回显。
    private func restoreDefaults() {
        ConsoleCommandPreferences.restoreDefaults()
        retryLimit = ConsoleCommandPreferences.defaultRetryLimit
        confirmTimeoutSeconds = ConsoleCommandPreferences.defaultConfirmTimeoutSeconds
    }

    /// 仅由用户请求时生成临时归档，交给系统分享面板选择目的地。
    private func prepare() {
        preparing = true
        Task {
            defer { preparing = false }
            let bundle = Bundle.main
            let process = ProcessInfo.processInfo
            let hardware = hardwareModel()
            let disk = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                .volumeAvailableCapacity
            let environment = [
                "Version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")",
                "Build: \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "")",
                "Bundle: \(bundle.bundleIdentifier ?? "")",
                "Hardware: \(hardware)",
                "OS: \(process.operatingSystemVersionString)",
                "Locale: \(Locale.current.identifier)",
                "Time zone: \(TimeZone.current.identifier)",
                "Memory bytes: \(process.physicalMemory)",
                "Active cores: \(process.activeProcessorCount)",
                "Available storage bytes: \(disk.map(String.init) ?? "unknown")"
            ].joined(separator: "\n")
            do { archive = try await AppLogStore.shared.archive(environment: environment) }
            catch {
                AppLog.error(error, context: "diagnostics.export")
                self.error = error.localizedDescription
            }
        }
    }

    private func hardwareModel() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return UIDevice.current.model }
        return withUnsafeBytes(of: info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
