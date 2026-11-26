import LunaTransportApple
import OpenCineCore
import SwiftUI
import UIKit

/// 独立显示发现、配对与重连，复用工作区的同一相机会话。
struct CameraConnectionView: View {
    let camera: CameraController
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Label {
                    Text(statusText)
                        .font(.headline)
                } icon: {
                    Image(systemName: camera.connected ? "link" : "camera")
                }
                .accessibilityIdentifier("connection.status")

                if let selected = camera.selectedCamera {
                    let name = camera.cameraProfile?.displayName ?? selected.name
                    Text(camera.firmware.map {
                        String(localized: "console.connection.firmware \(name) \($0)")
                    } ?? name)
                    .foregroundStyle(.secondary)
                }
                if let notice = camera.notice {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(notice.isError ? Color.red : Color.secondary)
                }
                connectionActions
            } footer: {
                if camera.selectedCamera == nil {
                    Text("console.connection.instructions")
                } else {
                    Text("connection.background.detail")
                }
            }
            if camera.selectedCamera == nil && !camera.cameras.isEmpty {
                Section("connection.devices.title") {
                    ForEach(camera.cameras) { device in
                        Button { camera.connect(device) } label: { Label(device.name, systemImage: "camera") }
                            .accessibilityHint("console.connection.selectHint")
                    }
                }
            }
        }
        .navigationTitle("feature.connection.title")
    }

    @ViewBuilder
    private var connectionActions: some View {
        if camera.connectionDropped {
            Button("console.action.retry", systemImage: "arrow.clockwise", action: camera.retryConnection)
                .accessibilityIdentifier("console.connection.retry")
        }
        if camera.selectedCamera != nil || camera.phase != .idle {
            Button(camera.connected ? LocalizedStringKey("console.connection.disconnect") : LocalizedStringKey("common.cancel"),
                   action: camera.disconnect)
                .accessibilityIdentifier("connection.disconnect")
        } else {
            Button("console.connection.scan", systemImage: "antenna.radiowaves.left.and.right", action: camera.scan)
                .accessibilityIdentifier("connection.scan")
        }
        if camera.localNetwork == .denied && !camera.connected {
            Button("permissions.action.settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }

    private var statusText: String {
        if camera.verifyingConnection { return String(localized: "connection.status.verifying") }
        if camera.reconnecting { return String(localized: "console.notice.reconnectingGeneric") }
        return camera.statusTitle
    }
}

#Preview { NavigationStack { CameraConnectionView(camera: CameraController()) } }
