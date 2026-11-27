import Combine
import CoreBluetooth
import CoreLocation
import CoreTelephony
import OpenCineApple
import OpenCineCore
import Photos
import SwiftUI

/// 权限检查页：展示连接相机和保存照片所需的系统权限，并可就地申请或前往系统设置。
struct PermissionCheckView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var cellular = CTCellularDataRestrictedState.restrictedStateUnknown
    @State private var loading = false
    @StateObject private var bluetooth = BluetoothPermissionStatus()
    @StateObject private var location = LocationPermissionStatus()
    @StateObject private var localNetwork = LocalNetworkPermissionStatus()
    private let cellularData = CTCellularData()

    var body: some View {
        List {
            Section("permissions.section.title") {
                row("permissions.bluetooth.title", "permissions.bluetooth.detail", "dot.radiowaves.left.and.right",
                    bluetoothText, bluetoothAction, requestBluetooth, statusColor: bluetoothStatusColor)
                    .accessibilityIdentifier("permissions.bluetooth")
                row("permissions.localNetwork.title", "permissions.localNetwork.detail", "network",
                    localNetworkText, localNetworkAction, requestLocalNetwork, statusColor: localNetworkStatusColor)
                    .accessibilityIdentifier("permissions.localNetwork")
                row("permissions.location.title", "permissions.location.detail", "location",
                    locationText, locationAction, requestLocation, statusColor: locationStatusColor)
                    .accessibilityIdentifier("permissions.location")
                row("permissions.photos.title", "permissions.photos.detail", "photo.on.rectangle.angled",
                    photoText, photoAction, requestPhoto, statusColor: photoStatusColor)
                    .accessibilityIdentifier("permissions.photos")
            }
            if !ProcessInfo.processInfo.isiOSAppOnMac {
                Section {
                    row("permissions.wirelessData.title", "permissions.wirelessData.detail", "wifi",
                        cellularText, cellularAction, openSettings, statusColor: cellularStatusColor)
                        .accessibilityIdentifier("permissions.wirelessData")
                } header: {
                    Text("permissions.networkAccess.title")
                } footer: {
                    Text("permissions.networkAccess.footer")
                }
            }
        }
        .navigationTitle("permissions.check.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onDisappear { localNetwork.stop() }
    }

    /// 一行权限：说明、当前状态，以及允许或打开系统设置。
    private func row(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        _ icon: String,
        _ status: LocalizedStringKey,
        _ action: LocalizedStringKey?,
        _ handler: @escaping () -> Void,
        statusColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Text(status)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(statusColor)
                Spacer()
                if let action {
                    Button(action, action: handler)
                        .disabled(loading)
                }
                if loading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, 3)
    }

    private var bluetoothText: LocalizedStringKey {
        switch bluetooth.authorization {
        case .allowedAlways: "permissions.status.allowed"
        case .notDetermined: "permissions.status.notDetermined"
        case .restricted: "permissions.status.restricted"
        case .denied: "permissions.status.denied"
        @unknown default: "permissions.status.unchecked"
        }
    }

    private var bluetoothAction: LocalizedStringKey? {
        switch bluetooth.authorization {
        case .allowedAlways: nil
        case .notDetermined: "permissions.action.allow"
        default: "permissions.action.settings"
        }
    }

    private var bluetoothStatusColor: Color {
        bluetooth.authorization == .denied || bluetooth.authorization == .restricted ? .red : .secondary
    }

    /// 尚未决定时创建蓝牙管理器以弹出系统询问，否则前往系统设置。
    private func requestBluetooth() {
        if bluetooth.authorization == .notDetermined { bluetooth.requestAuthorization() }
        else { openSettings() }
    }

    private var localNetworkText: LocalizedStringKey {
        switch localNetwork.state {
        case .allowed: "permissions.status.allowed"
        case .denied: "permissions.status.denied"
        case .requested: "permissions.localNetwork.waiting"
        case .unknown: "permissions.status.unchecked"
        }
    }

    private var localNetworkAction: LocalizedStringKey? {
        switch localNetwork.state {
        case .allowed: nil
        case .denied: "permissions.action.settings"
        case .unknown, .requested: localNetwork.isProbing ? nil : "permissions.action.allow"
        }
    }

    private var localNetworkStatusColor: Color { localNetwork.state == .denied ? .red : .secondary }

    /// 本地网络没有现成的授权查询，点按后用本 App 的 Bonjour 服务唤起系统询问。
    private func requestLocalNetwork() {
        if localNetwork.state == .denied { openSettings() }
        else { localNetwork.request() }
    }

    private var locationText: LocalizedStringKey {
        switch location.authorization {
        case .authorizedAlways, .authorizedWhenInUse: "permissions.status.allowed"
        case .notDetermined: "permissions.status.notDetermined"
        case .restricted: "permissions.status.restricted"
        case .denied: "permissions.status.denied"
        @unknown default: "permissions.status.unchecked"
        }
    }

    private var locationAction: LocalizedStringKey? {
        switch location.authorization {
        case .authorizedAlways, .authorizedWhenInUse: nil
        case .notDetermined: "permissions.action.allow"
        default: "permissions.action.settings"
        }
    }

    private var locationStatusColor: Color {
        location.authorization == .denied || location.authorization == .restricted ? .red : .secondary
    }

    /// 只申请使用期间的位置权限，不启动定位。
    private func requestLocation() {
        if location.authorization == .notDetermined { location.requestAuthorization() }
        else { openSettings() }
    }

    private var photoAllowed: Bool {
        photo == .authorized || photo == .limited
            || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    private var photoText: LocalizedStringKey {
        if photoAllowed { "permissions.status.allowed" }
        else if photo == .notDetermined { "permissions.status.notDetermined" }
        else if photo == .restricted { "permissions.status.restricted" }
        else { "permissions.status.denied" }
    }

    private var photoAction: LocalizedStringKey? {
        if photoAllowed { nil }
        else if photo == .notDetermined { "permissions.action.allow" }
        else { "permissions.action.settings" }
    }

    private var photoStatusColor: Color {
        photo == .denied || photo == .restricted ? .red : .secondary
    }

    /// 与保存照片时相同，申请读写权限以便创建 LunaScope 相册。
    private func requestPhoto() {
        guard photo == .notDetermined else { openSettings(); return }
        loading = true
        Task {
            photo = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            loading = false
        }
    }

    private var cellularText: LocalizedStringKey {
        switch cellular {
        case .restricted: "permissions.status.restricted"
        case .notRestricted: "permissions.status.allowed"
        default: "permissions.status.unchecked"
        }
    }

    private var cellularAction: LocalizedStringKey? { cellular == .restricted ? "permissions.action.settings" : nil }
    private var cellularStatusColor: Color { cellular == .restricted ? .red : .secondary }

    /// 回到前台或页面出现时重读各项状态。本地网络只能反映已经做过的检查。
    private func refresh() async {
        bluetooth.refresh()
        location.refresh()
        localNetwork.refresh()
        photo = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        cellular = cellularData.restrictedState
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// 只读取蓝牙授权。尚未决定时才创建管理器，从而弹出系统询问，不开始扫描。
@MainActor
private final class BluetoothPermissionStatus: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var authorization = CBManager.authorization
    private var manager: CBCentralManager?

    func refresh() { authorization = CBManager.authorization }

    func requestAuthorization() {
        guard authorization == .notDetermined, manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    nonisolated func centralManagerDidUpdateState(_: CBCentralManager) {
        // 实例属性 authorization 在 iOS 13.1 起弃用，改读类属性。
        let authorization = CBManager.authorization
        Task { @MainActor in self.authorization = authorization }
    }
}

/// 只检查和申请使用期间的位置权限，不启动定位。
@MainActor
private final class LocationPermissionStatus: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    private let manager: CLLocationManager

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func refresh() { authorization = manager.authorizationStatus }

    func requestAuthorization() { manager.requestWhenInUseAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        Task { @MainActor in self.authorization = authorization }
    }
}

/// 用本 App 已声明的 Bonjour 服务触发本地网络询问，并记住这次检查的结果。
@MainActor
private final class LocalNetworkPermissionStatus: ObservableObject {
    @Published private(set) var state: CameraNetworkPermissionState = .unknown
    @Published private(set) var isProbing = false
    private var privacy: LocalNetworkPrivacy?

    func refresh() {
        guard let privacy else { return }
        state = privacy.state
        isProbing = privacy.isProbing
    }

    func request() {
        if privacy == nil {
            privacy = LocalNetworkPrivacy { [weak self] state, _ in
                self?.state = state
                self?.isProbing = self?.privacy?.isProbing ?? false
            }
        }
        privacy?.requestBeforeCameraJoin(serviceType: "_lunascope._tcp")
        refresh()
    }

    func stop() { privacy?.stop() }
}

#Preview { NavigationStack { PermissionCheckView() } }
