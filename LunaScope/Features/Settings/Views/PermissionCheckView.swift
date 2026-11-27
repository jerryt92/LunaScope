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
    @State private var cellularData = CTCellularData()

    var body: some View {
        List {
            row("permissions.bluetooth.title", "permissions.bluetooth.detail", "dot.radiowaves.left.and.right",
                bluetoothText, bluetoothAction, requestBluetooth, statusColor: bluetoothStatusColor)
                .accessibilityIdentifier("permissions.bluetooth")
            row("permissions.localNetwork.title", "permissions.localNetwork.detail", "network",
                localNetworkText, localNetworkAction, requestLocalNetwork, statusColor: localNetworkStatusColor,
                busy: localNetwork.isChecking)
                .accessibilityIdentifier("permissions.localNetwork")
            row("permissions.location.title", "permissions.location.detail", "location",
                locationText, locationAction, requestLocation, statusColor: locationStatusColor)
                .accessibilityIdentifier("permissions.location")
            row("permissions.photos.title", "permissions.photos.detail", "photo.on.rectangle.angled",
                photoText, photoAction, requestPhoto, statusColor: photoStatusColor, busy: loading)
                .accessibilityIdentifier("permissions.photos")
            if !ProcessInfo.processInfo.isiOSAppOnMac {
                row("permissions.wirelessData.title", "permissions.wirelessData.detail", "wifi",
                    cellularText, cellularAction, openSettings, statusColor: cellularStatusColor)
                    .accessibilityIdentifier("permissions.wirelessData")
            }
        }
        .navigationTitle("permissions.check.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 无线数据的受限状态由系统异步给出，创建后立刻读取通常还是未知。
            cellularData.cellularDataRestrictionDidUpdateNotifier = { state in
                Task { @MainActor in cellular = state }
            }
            refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .onDisappear { localNetwork.stop() }
    }

    /// 一行权限：说明、当前状态，以及允许或打开系统设置。`busy` 只影响这一行。
    private func row(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        _ icon: String,
        _ status: LocalizedStringKey,
        _ action: LocalizedStringKey?,
        _ handler: @escaping () -> Void,
        statusColor: Color,
        busy: Bool = false
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
                        .buttonStyle(.borderless)
                        .disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
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
        case .unknown, .requested:
            localNetwork.isChecking ? "permissions.localNetwork.waiting" : "permissions.status.unchecked"
        }
    }

    private var localNetworkAction: LocalizedStringKey? {
        switch localNetwork.state {
        case .allowed: nil
        case .denied: "permissions.action.settings"
        case .unknown, .requested: localNetwork.isChecking ? nil : "permissions.action.allow"
        }
    }

    private var localNetworkStatusColor: Color { localNetwork.state == .denied ? .red : .secondary }

    /// 本地网络没有现成的授权查询，点按后用本 App 的 Bonjour 服务唤起系统询问并核实结果。
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
        default: "permissions.status.unknown"
        }
    }

    private var cellularAction: LocalizedStringKey? { cellular == .restricted ? "permissions.action.settings" : nil }
    private var cellularStatusColor: Color { cellular == .restricted ? .red : .secondary }

    /// 页面出现或回到前台时重读各项状态。系统询问过本地网络后，这里会重新核实一次。
    private func refresh() {
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

/// 本地网络没有系统查询接口：发布并浏览本 App 声明的 Bonjour 服务，发布成功或浏览到结果即已允许，系统明确拒绝即已拒绝。
@MainActor
private final class LocalNetworkPermissionStatus: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private static let serviceType = "_lunascope._tcp"

    /// 初值取上次核实的结论，再次进入页面时不会退回「尚未检查」。
    @Published private(set) var state = LocalNetworkPermissionRecord.state ?? .unknown
    @Published private(set) var isChecking = false
    private var privacy: LocalNetworkPrivacy?
    private var browser: NetServiceBrowser?
    private var publisher: NetService?
    private var timeout: Task<Void, Never>?

    /// 系统询问过才重新核实，避免一进页面就弹窗。从系统设置改完回来也走这里。
    func refresh() {
        guard LocalNetworkPermissionRecord.state != nil else { return }
        check()
    }

    /// 用户点「允许」：触发系统询问并等待结论。
    func request() {
        LocalNetworkPermissionRecord.noteRequested()
        check()
    }

    private func check() {
        stop()
        isChecking = true
        let privacy = LocalNetworkPrivacy { [weak self] state, _ in self?.adopt(state) }
        self.privacy = privacy
        privacy.start(.init(browseType: Self.serviceType, includePeerToPeer: false, resultsGrant: true))

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType + ".", inDomain: "local.")
        self.browser = browser

        let service = NetService(domain: "local.", type: Self.serviceType + ".", name: "LunaScope", port: 1100)
        service.delegate = self
        service.publish()
        publisher = service

        // 用户一直不回答系统询问时结束这次检查，让「允许」按钮重新出现。
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.stop()
        }
    }

    /// 只接受明确结论，并记下来供下次进入页面使用。
    private func adopt(_ next: CameraNetworkPermissionState) {
        guard next == .allowed || next == .denied else { return }
        state = next
        LocalNetworkPermissionRecord.state = next
        stop()
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        privacy?.stop()
        privacy = nil
        browser?.stop()
        browser = nil
        publisher?.stop()
        publisher = nil
        isChecking = false
    }

    /// 被拒绝时系统不会让服务发布成功，所以发布成功即已允许。回调在主线程的 run loop 上。
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard sender === publisher else { return }
            adopt(.allowed)
        }
    }
}

#Preview { NavigationStack { PermissionCheckView() } }
