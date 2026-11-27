import CoreGraphics
import Foundation
import LunaTransportApple
import LunaTransportProtocol
import Observation
import OpenCineApple
import OpenCineCore

/// 持有共享相机连接，协调拍摄和相册操作。
@MainActor
@Observable
final class CameraController {
    let preview = MonitorLiveVideoDecoder()
    private(set) var previewSize: CGSize = .zero
    /// 8234 图传宽高；横竖拍切换时往往先于解码器 pictureSize 到达。
    private(set) var streamPreviewSize: CGSize = .zero
    /// 设备 option 93 `CAMERA_POSTURE`（与摄影 AF option 93 不同命名空间）。
    private(set) var cameraPosture: UInt64?
    /// 预览旋转角：竖立横平，左右侧倾各 ±90° 竖平。
    var previewRotationDegrees: Int {
        LunaCameraPosture(wire: cameraPosture)?.rotationDegrees ?? 0
    }
    /// 左右侧倾竖平时 letterbox 对调宽高。
    var previewRotationSwapsAspect: Bool {
        LunaCameraPosture(wire: cameraPosture)?.swapsAspect ?? false
    }
    private(set) var previewRestoreRequest: UUID?
    private(set) var tracking = LunaSubjectTracking.Snapshot()
    @ObservationIgnored private var previewCommandID: UUID?
    @ObservationIgnored private lazy var subjectTracking = LunaSubjectTracking(
        session: { [weak self] in self?.session },
        changed: { [weak self] next in
            if let self, tracking != next { tracking = next }
        }
    )
    @ObservationIgnored private(set) lazy var pictureInPicture: ConsolePictureInPicture = {
        let pip = ConsolePictureInPicture(layer: preview.displayLayer)
        pip.onRestore = { [weak self] in self?.previewRestoreRequest = UUID() }
        pip.onResume = { [weak self] in self?.resumePictureInPictureFeed() }
        pip.onStartRequested = { [weak self] in self?.requestKeyframe(minimumInterval: 0) }
        return pip
    }()
    private(set) var phase: CameraConnectionPhase = .idle
    private(set) var cameras: [MonitorCamera] = []
    private(set) var selectedCamera: MonitorCamera?
    private(set) var cameraProfile: ConsoleCameraProfile?
    private(set) var snapshot: CameraSnapshot?
    private var recordingZoomAnchor: Double?
    private var reportedMode: LunaShootingMode?
    private var reportedBanks: [ConsoleCaptureMode: ConsoleParameters] = [:]
    private var professionalPresetBanks: [ConsoleCaptureMode: ConsoleParameters] = [:]
    private var reportedParameters: ConsoleParameters? {
        reportedMode.flatMap { reportedBanks[ConsoleCaptureMode($0)] }
    }
    private var selectedMode: LunaShootingMode?
    private var selectedParameters: [ConsoleCaptureMode: ConsoleParameters] = [:]
    var shootingMode: LunaShootingMode? { selectedMode ?? reportedMode }
    var exposureControlMode: LunaIQ3AMode? {
        guard let mode = shootingMode else { return nil }
        let bank = ConsoleCaptureMode(mode)
        let isApplyingMode = settingWrites.contains {
            $0.coalesceKey == "apply.\(bank)" || (mode == reportedMode && $0.coalesceKey == "exposureControlMode")
        }
        if isApplyingMode, let requested = selectedParameters[bank]?.exposureControlMode {
            return requested
        }
        if mode == reportedMode, settingWrites.contains(where: { $0.coalesceKey == "preset.readProfessional" }) {
            return .basic
        }
        return mode == reportedMode ? reportedParameters?.exposureControlMode : nil
    }
    var parameters: ConsoleParameters? {
        guard let mode = shootingMode else { return nil }
        var displayed = reportedBanks[ConsoleCaptureMode(mode)] ?? ConsoleParameters(mode: mode)
        if let selection = selectedParameters[displayed.mode] { displayed.merge(selection) }
        return displayed.hasValues ? displayed : nil
    }
    private(set) var readingPhotoFormat = false
    private(set) var verifyingConnection = false
    @ObservationIgnored private var foregroundProbe: Task<Void, Never>?
    @ObservationIgnored private var foregroundProbeID: UUID?
    private(set) var memory: ConsoleMemory
    private(set) var capture: LunaCaptureStatus?
    private(set) var firmware: String?
    private(set) var screenBattery: Double?
    /// 可拆卸屏幕是否在充电（powerType ≠ 0）。
    private(set) var screenCharging = false
    private var streamFormat: LunaLiveStreamParameters?
    private var reportedGimbalMode: LunaGimbalMode?
    private var selectedGimbalMode: LunaGimbalMode?
    var gimbalMode: LunaGimbalMode? { selectedGimbalMode ?? reportedGimbalMode }
    private(set) var gimbalSleeping = false
    private(set) var pictureReady = false
    private(set) var pictureStalled = false
    private(set) var busy = false
    private(set) var syncingSettings = false
    private(set) var settingsError: String?
    private(set) var restartingPreview = false
    private(set) var reconnecting = false
    private(set) var connectionDropped = false
    private(set) var notice: Notice?
    private(set) var albumControlOwner: UUID?
    private(set) var localNetwork: CameraNetworkPermissionState = .unknown
    @ObservationIgnored private var noticeClearTask: Task<Void, Never>?
    @ObservationIgnored private var noticeClearID = UUID()
    /// 上一帧是否已在限位，用于上升沿提示、避免顶住时刷屏。
    @ObservationIgnored private var gimbalWasAtLimit = false
    /// 本会话确认过的云台朝向。未按过回中/翻转时为 nil，不能拿它和记忆里的翻转比。
    @ObservationIgnored private var gimbalIsFlipped: Bool?

    struct AlbumLink {
        let generation: UUID
        let host: String
        let session: LunaCameraSession
    }

    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    /// 轻提示默认展示时长（秒）；nonisolated 以便作默认参数。
    nonisolated static let defaultNoticeSeconds: TimeInterval = 2

    /// 弹出覆盖式轻提示；默认两秒后关闭，可传入自定义秒数。
    func showNotice(_ text: String, isError: Bool = false, seconds: TimeInterval = CameraController.defaultNoticeSeconds) {
        settingsError = nil
        notice = Notice(text: text, isError: isError)
        scheduleNoticeDismiss(after: max(0.5, seconds))
    }

    /// 立刻清掉覆盖式轻提示与参数同步错误文案。
    func dismissTransientFeedback() {
        noticeClearTask?.cancel()
        noticeClearTask = nil
        notice = nil
        settingsError = nil
    }

    /// 到期后关掉当前轻提示；新提示会取消上一次计时。
    private func scheduleNoticeDismiss(after seconds: TimeInterval) {
        noticeClearTask?.cancel()
        let id = UUID()
        noticeClearID = id
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, noticeClearID == id else { return }
            if notice != nil { notice = nil }
        }
    }

    private struct SettingWrite {
        let id: UUID
        let title: String
        let requiresIdle: Bool
        let zoomMode: LunaShootingMode?
        let isZoomPreview: Bool
        /// 相同 key 只保留最新意图；在飞项用 generation 判定是否已被覆盖。
        let coalesceKey: String?
        let generation: Int
        var attempts: Int
        let apply: @MainActor (CameraController, LunaCameraSession, _ isCurrent: @escaping () -> Bool) async throws -> Void
    }

    @ObservationIgnored private let memoryStore: ConsoleMemoryStore
    @ObservationIgnored private let backend: LunaCameraBackend
    @ObservationIgnored private var session: LunaCameraSession?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var scanDeadline: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var previewWatch: Task<Void, Never>?
    @ObservationIgnored private var attempt = UUID()
    @ObservationIgnored private var previewDeadline = Date.distantPast
    @ObservationIgnored private var previewStallBegan: Date?
    @ObservationIgnored private var previewStableSince: Date?
    @ObservationIgnored private var nextPreviewQualityTrial = Date.distantPast
    @ObservationIgnored private var reducedPreviewResolution: UInt64?
    @ObservationIgnored private var lastKeyframeRequest = Date.distantPast
    @ObservationIgnored private var lastCaptureReportAt = Date.distantPast
    @ObservationIgnored private var pendingPhoto: UUID?
    @ObservationIgnored private var photoCompletion: Bool?
    /// 单张拍照的命令还在执行。连拍的间隔等待不靠它转圈。
    @ObservationIgnored private var shutterCommand = false
    /// 上一张还在处理时又按下的快门次数，当前命令结束后继续拍。
    @ObservationIgnored private var queuedShutterPresses = 0
    private(set) var deletingMedia = false
    private(set) var photoAddDenied = false
    /// App 侧连续拍摄：底层仍用单张照片模式。
    private(set) var continuousPhoto = false
    private(set) var continuousShooting = false
    var continuousInterval = ConsoleShootInterval()
    /// 连续拍摄时每张之前先回到开拍角度。默认打开，只记开关，不记角度。
    private(set) var continuousGimbalReturn = true
    /// 这次连拍按下时的云台角度。只活在这一轮里，不写入手动记忆的位置。
    @ObservationIgnored private var continuousReturnPosition: ConsoleGimbalPosition?
    @ObservationIgnored private var continuousGeneration = UUID()
    @ObservationIgnored private var gimbalNudge: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var autoWakeTask: Task<Void, Never>?
    @ObservationIgnored private var parameterReadID: UUID?
    @ObservationIgnored private var parameterReadTask: Task<Void, Never>?
    private var settingWrites: [SettingWrite] = []
    /// 每个 coalesceKey 的最新世代；入队时递增，用于取消在飞的过时确认。
    private var settingEpoch: [String: Int] = [:]
    @ObservationIgnored private var settingTask: Task<Void, Never>?
    @ObservationIgnored private var screenDisconnected = false
    @ObservationIgnored private lazy var motion = LunaMotionService(session: { [weak self] in self?.session })
    @ObservationIgnored private lazy var privacy = LocalNetworkPrivacy { [weak self] state, _ in
        self?.localNetwork = state
        // 连接过程中得到的结论同步给权限检查页。
        if state == .allowed || state == .denied { LocalNetworkPermissionRecord.state = state }
    }

    init(memoryStore: ConsoleMemoryStore? = nil) {
        let memoryStore = memoryStore ?? ConsoleMemoryStore()
        self.memoryStore = memoryStore
        let loaded: ConsoleMemory
        do { loaded = try memoryStore.load() }
        catch {
            loaded = ConsoleMemory()
            AppLog.error(error, context: "console.memory.load")
        }
        memory = loaded
        if let interval = loaded.continuousInterval {
            continuousInterval = interval
        }
        continuousGimbalReturn = loaded.continuousGimbalReturn
        let profiles = ConsoleCameraProfile.bundled
        let advertisedModels = profiles.flatMap { profile in
            profile.bluetoothPrefixes.map { ($0, profile.deviceModels[0]) }
        }
        let config = LunaIntegrationConfiguration(
            keychainService: "io.github.jerryt92.LunaScope.camera",
            appName: "LunaScope", logPrefix: "LunaScope",
            supportedModels: Set(profiles.flatMap(\.deviceModels)),
            advertisedModels: Dictionary(advertisedModels, uniquingKeysWith: { first, _ in first })
        )
        backend = LunaCameraBackend(
            configuration: config,
            hotspot: CameraHotspotSystem(cancellation: .awaitNativeCompletion).host
        )
        backend.eventHandler = { [weak self] in self?.receive($0) }
        backend.onDeviceStatus = { [weak self] status in
            guard let self else { return }
            if let mode = status.shootingMode { adoptMode(mode) }
            if let posture = status.cameraPosture, cameraPosture != posture {
                cameraPosture = posture
            }
            guard selectedCamera != nil else { return }
            if let state = status.screenConnection { updateScreenConnection(state) }
            if let battery = status.screenBattery {
                updateScreenBattery(battery)
            } else if status.battery != nil {
                // 电量轮询同时请求机身和屏幕。单独读取拍摄模式时不清除屏幕电量。
                screenBattery = nil
                screenCharging = false
            }
        }
        backend.onSettings = { [weak self] settings in
            guard let self, self.selectedCamera != nil,
                  settings.functionMode == nil || settings.functionMode == self.backend.functionMode else { return }
            if let mode = settings.gimbal?.gimbalMode, self.reportedGimbalMode != mode { self.reportedGimbalMode = mode }
            if let status = settings.gimbalStatus {
                self.adoptGimbalSleep(status.sleep)
                self.presentGimbalLimitIfNeeded(status)
            }
            if let mode = reportedMode {
                var next = ConsoleParameters(mode: mode)
                next.ingest(settings)
                if next.hasValues { acceptReported(next) }
            }
        }
        backend.onCapture = { [weak self] status in
            guard let self else { return }
            // 拍摄状态轮询很频繁，内容没变就不要通知界面，否则打开的菜单会跟着重绘闪烁。
            if capture != status { capture = status }
            lastCaptureReportAt = .now
            startSettingWrites()
        }
        backend.onNotification = { [weak self] in self?.receive($0) }
        backend.onTrackFrame = { [weak self] in self?.subjectTracking.ingest($0) }
        backend.onLocalNetworkEvidence = { [weak self] evidence in
            self?.privacy.note(evidence, source: "Insta360 Luna")
        }
        preview.onHandoffNeedsIDR = { [weak self] in self?.requestKeyframe() }
        preview.onParameterSetsChanged = { [weak self] in self?.requestKeyframe() }
        preview.onPictureSizeChanged = { [weak self] in
            if let self, previewSize != preview.pictureSize { previewSize = preview.pictureSize }
        }
    }

    var connected: Bool { phase == .streaming }
    private var canWriteSettings: Bool {
        connected && cameraProfile != nil && snapshot?.connection == .ready && !reconnecting && !busy
            && !restartingPreview && !verifyingConnection && albumControlOwner == nil
    }
    var hasPendingSettings: Bool { !settingWrites.isEmpty }
    /// 命令进行时的统一提示。拍照不使用文案。
    enum CommandPrompt: Equatable {
        case processing
        case deletingMedia

        var title: LocalizedStringResource {
            switch self {
            case .processing: "console.capture.working"
            case .deletingMedia: "album.deleting.media"
            }
        }
    }

    /// perform 的提示方式。拍照只让快门转圈。
    private enum CommandPresentation {
        case processing
        case shutter
    }

    /// 仅变焦同步时不打「正在处理」，避免拖动刻度时右下角闪提示。
    var showsParameterWorkingIndicator: Bool {
        guard syncingSettings else { return false }
        return settingWrites.contains { $0.zoomMode == nil }
    }
    /// 命令进行中的统一文案。拍照不走这里，由快门按钮自己转圈。
    var commandPrompt: CommandPrompt? {
        if deletingMedia { return .deletingMedia }
        if showsShutterActivity { return nil }
        if busy || showsParameterWorkingIndicator || processingCapture { return .processing }
        return nil
    }
    /// 快门转圈只表示这张照片正在拍。连拍的间隔等待、以及拍完后的写卡状态，都不再转。
    var showsShutterActivity: Bool {
        if continuousShooting { return pendingPhoto != nil }
        if shutterCommand || pendingPhoto != nil { return true }
        guard shootingMode == .photo || shootingMode == .pano else { return false }
        guard !recording, snapshot?.recording.value != .transitioning else { return false }
        return capture?.isProcessingCapture == true
    }
    var canControl: Bool { canWriteSettings && !syncingSettings }
    var recording: Bool { snapshot?.recording.value == .recording }
    var processingCapture: Bool {
        pendingPhoto != nil || capture?.isProcessingCapture == true || snapshot?.recording.value == .transitioning
    }

    var canEditShootingSettings: Bool { canWriteSettings && capture?.isIdle == true && !processingCapture && !recording }
    var canChangeMode: Bool { canEditShootingSettings && !hasPendingSettings && !syncingSettings }
    private var supportsGimbal: Bool { cameraProfile?.gimbalChoices.isEmpty == false }
    var canEditGimbalMode: Bool { supportsGimbal && canWriteSettings && !gimbalSleeping && shootingMode != nil }
    var canRetrySettings: Bool { canEditShootingSettings && !syncingSettings }
    var canUseCameraSettings: Bool { canWriteSettings && !syncingSettings }

    var canAdjustExposure: Bool { canEditShootingSettings && shootingMode != .pano && parameters?.exposure != nil }
    var canSwitchExposureControlMode: Bool {
        canEditShootingSettings && shootingMode != nil && shootingMode == reportedMode && shootingMode != .pano
    }
    var canRememberGimbal: Bool { supportsGimbal && canChangeMode && !gimbalSleeping }
    var canTakePhoto: Bool {
        guard canChangeMode, let shootingMode, shootingMode.isPhoto else { return false }
        return cameraProfile?.captureModes.contains(ConsoleCaptureMode(shootingMode)) == true
    }

    var modeLabel: String {
        if continuousPhoto { return String(localized: "console.mode.continuousPhoto") }
        return shootingMode?.label ?? "—"
    }

    var canUsePreviewGestures: Bool {
        canControl && pictureReady && !pictureStalled && !restartingPreview && !processingCapture
            && !pictureInPicture.isActive && shootingMode == reportedMode && shootingMode != nil
    }

    var canTrackSubject: Bool {
        guard canUsePreviewGestures, !gimbalSleeping, let shootingMode else { return false }
        return cameraProfile?.supportsTracking(in: shootingMode) == true
    }

    var savedGimbalForCamera: ConsoleGimbalPosition? {
        guard let position = memory.lastPosition, position.cameraID == selectedCamera?.id else { return nil }
        return position
    }

    var statusTitle: String {
        switch phase {
        case .idle: String(localized: "console.state.idle")
        case .scanning: String(localized: "console.state.scanning")
        case .connecting: String(localized: "console.state.connecting")
        case .negotiating: String(localized: "console.state.negotiating")
        case .awaitingApproval: String(localized: "console.state.awaitingApproval")
        case .readingWiFi: String(localized: "console.state.readingWiFi")
        case .joiningWiFi: String(localized: "console.state.joiningWiFi")
        case .openingVideo: String(localized: "console.state.openingVideo")
        case .streaming: String(localized: "console.state.streaming")
        }
    }

    func scan() {
        disconnect()
        #if targetEnvironment(simulator)
        showNotice(String(localized: "console.notice.simulator"))
        #else
        LocalNetworkPermissionRecord.noteRequested()
        privacy.requestBeforeCameraJoin(serviceType: "_lunascope._tcp")
        phase = .scanning
        let token = attempt
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.startScan()
            } catch {
                guard attempt == token, !Task.isCancelled else { return }
                disconnect()
                report(String(localized: "console.error.scan"), error: error)
            }
        }
        scanDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, attempt == token, phase == .scanning else { return }
            backend.stopScan()
            phase = .idle
            if cameras.isEmpty {
                showNotice(String(localized: "console.notice.noCamera"))
            }
        }
        #endif
    }

    func connect(_ camera: MonitorCamera) {
        disconnect()
        LocalNetworkPermissionRecord.noteRequested()
        privacy.requestBeforeCameraJoin(serviceType: "_lunascope._tcp")
        selectedCamera = camera
        phase = .connecting
        let token = attempt
        let target = backend.openSession()
        target.configureLens(zoomDomain: nil)
        session = target
        let snapshots = target.snapshots()
        snapshotTask = Task { [weak self] in
            for await value in snapshots {
                guard let self, attempt == token else { return }
                adoptSnapshot(value)
                startSettingWrites()
            }
        }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.connect(to: camera)
                guard attempt == token, !Task.isCancelled else { return }
                watchPreview(token)
                scheduleParameterRead()
            } catch {
                guard attempt == token, !Task.isCancelled else { return }
                disconnect()
                if localNetwork == .denied {
                    showNotice(String(localized: "console.notice.network"), isError: true)
                } else {
                    report(String(localized: "console.error.connection"), error: error)
                }
            }
        }
    }

    func disconnect() {
        pictureInPicture.stop()
        cancelReconnect()
        teardown()
        clearSettingSelections()
        reportedBanks.removeAll()
        professionalPresetBanks.removeAll()
        backend.leaveCameraNetwork()
        selectedCamera = nil
        cameraProfile = nil
        dismissTransientFeedback()
        photoAddDenied = false
    }

    /// 清理连接但保留已选相机与记忆，供断线重连复用。不离开相机网络。
    /// `preserveContinuous` 为真时保留连续拍摄，等重连后继续按间隔触发。
    private func teardown(preserveContinuous: Bool = false) {
        attempt = UUID()
        cancelForegroundProbe()
        connectionTask?.cancel()
        scanDeadline?.cancel()
        snapshotTask?.cancel()
        previewWatch?.cancel()
        previewCommandID = nil
        subjectTracking.clear()
        gimbalNudge?.cancel()
        gimbalNudge = nil
        autoWakeTask?.cancel()
        autoWakeTask = nil
        cancelParameterRead()
        motion.endHold()
        backend.stopScan()
        backend.disconnect()
        session?.close(.requested)
        session = nil
        privacy.stop()
        phase = .idle
        cameras = []
        snapshot = nil
        recordingZoomAnchor = nil
        reportedMode = nil
        capture = nil
        firmware = nil
        screenBattery = nil
        screenCharging = false
        screenDisconnected = false
        streamFormat = nil
        streamPreviewSize = .zero
        cameraPosture = nil
        reducedPreviewResolution = nil
        previewStallBegan = nil
        previewStableSince = nil
        nextPreviewQualityTrial = .distantPast
        reportedGimbalMode = nil
        gimbalSleeping = false
        gimbalWasAtLimit = false
        gimbalIsFlipped = nil
        pictureReady = false
        pictureStalled = false
        lastKeyframeRequest = .distantPast
        lastCaptureReportAt = .distantPast
        busy = false
        shutterCommand = false
        queuedShutterPresses = 0
        deletingMedia = false
        settingTask?.cancel()
        settingTask = nil
        syncingSettings = false
        restartingPreview = false
        pendingPhoto = nil
        photoCompletion = nil
        if !preserveContinuous {
            stopContinuousCapture()
            continuousPhoto = false
        }
        albumControlOwner = nil
        preview.reset()
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        connectionDropped = false
    }

    // MARK: - 断线自动重连

    /// 手动重试或回到前台时恢复连接，沿用上次连接的路由（BLE 唤醒相机 Wi-Fi）。
    func retryConnection() {
        guard !reconnecting, let camera = selectedCamera else { return }
        startReconnect(to: camera, reason: nil)
    }

    func sceneEnteredBackground() {
        cancelForegroundProbe()
    }

    private func cancelForegroundProbe() {
        foregroundProbe?.cancel()
        foregroundProbe = nil
        foregroundProbeID = nil
        verifyingConnection = false
    }

    /// 回到前台时用只读命令检查空闲会话，拍摄和写卡期间由连接层监听实际断开。
    func sceneBecameActive(verifyConnection: Bool = false) {
        if connectionDropped, selectedCamera != nil {
            retryConnection()
        } else if verifyConnection, connected, !reconnecting, foregroundProbe == nil,
                  !busy, !syncingSettings, !processingCapture, !recording, !continuousShooting,
                  albumControlOwner == nil,
                  let target = session, let camera = selectedCamera {
            let id = UUID()
            foregroundProbeID = id
            verifyingConnection = true
            foregroundProbe = Task { [weak self] in
                guard let self else { return }
                defer {
                    if foregroundProbeID == id {
                        foregroundProbe = nil
                        foregroundProbeID = nil
                        verifyingConnection = false
                    }
                }
                let probeStartedAt = Date.now
                for retry in 0..<3 {
                    guard !Task.isCancelled, foregroundProbeID == id, session === target,
                          !busy, !syncingSettings, !processingCapture, !recording else { return }
                    do {
                        _ = try await target.control(LunaProtocol.captureStatusRequest, timeout: .seconds(3))
                        guard !Task.isCancelled, foregroundProbeID == id, session === target else { return }
                        if gimbalSleeping { scheduleAutoWake() }
                        return
                    } catch {
                        guard !Task.isCancelled, foregroundProbeID == id, session === target else { return }
                        if busy || syncingSettings || processingCapture || recording || lastCaptureReportAt >= probeStartedAt
                            || (preview.lastSourceFrameAt ?? .distantPast) >= probeStartedAt { return }
                        if retry == 2 {
                            AppLog.error(error, context: "connection.foregroundProbe")
                            teardown(preserveContinuous: true)
                            startReconnect(to: camera, reason: nil)
                            return
                        }
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
            }
        } else if gimbalSleeping {
            scheduleAutoWake()
        }
    }

    private func startReconnect(to camera: MonitorCamera, reason _: String?) {
        reconnectTask?.cancel()
        reconnecting = true
        connectionDropped = false
        // 重连过程态不弹轻提示，只在成功/失败终态提示。
        let token = attempt
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await runConsoleReconnect(isCurrent: { [weak self] in
                self?.attempt == token
            }) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.attemptRejoin(token)
            }
            guard self.attempt == token, !Task.isCancelled else { return }
            self.reconnecting = false
            switch outcome {
            case .reconnected:
                self.showNotice(String(localized: "console.notice.reconnected"))
                self.resyncSelectedSettings()
            case .exhausted:
                self.pictureInPicture.stop()
                self.connectionDropped = true
                self.showNotice(String(localized: "console.notice.dropped"), isError: true)
            case .cancelled:
                break
            }
        }
    }

    private func attemptRejoin(_ token: UUID) async throws {
        guard attempt == token else { throw CancellationError() }
        let target = backend.openSession()
        target.configureLens(zoomDomain: cameraProfile?.zoomDomain)
        target.configureWhiteBalance(range: cameraProfile?.whiteBalance.range)
        session = target
        let snapshots = target.snapshots()
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            for await value in snapshots {
                guard let self, attempt == token else { return }
                adoptSnapshot(value)
                startSettingWrites()
            }
        }
        try await backend.rejoinCameraNetwork()
        guard attempt == token, !Task.isCancelled else { throw CancellationError() }
        watchPreview(token)
    }

    func restartPreview() { restartPreview(resolution: nil, automatic: false) }

    private func restartPreview(resolution: UInt64?, automatic: Bool) {
        guard connected, !restartingPreview, !busy, !syncingSettings, !hasPendingSettings, !processingCapture,
              !recording, !pictureInPicture.isPaused, albumControlOwner == nil else { return }
        let token = attempt
        restartingPreview = true
        pictureReady = false
        pictureStalled = false
        previewStallBegan = nil
        previewStableSince = nil
        nextPreviewQualityTrial = .now.addingTimeInterval(45)
        preview.reset()
        previewDeadline = .now.addingTimeInterval(10)
        Task { [weak self] in
            guard let self, attempt == token else { return }
            defer { if attempt == token { restartingPreview = false } }
            do {
                let accepted = try await backend.restartLive(previewResolution: resolution)
                guard attempt == token else { return }
                reducedPreviewResolution = accepted
                requestKeyframe(minimumInterval: 0)
            } catch {
                guard attempt == token else { return }
                pictureStalled = true
                if automatic { AppLog.error(error, context: "console.preview.quality") }
                else { report(String(localized: "console.error.preview"), error: error) }
            }
        }
    }

    func descriptor(_ key: SettingKey) -> SettingDescriptor? { snapshot?.capabilities[key] }
    func value(_ key: SettingKey) -> SettingValue? {
        switch key {
        case .zoom: if let zoom = parameters?.zoom { return .zoom(zoom) }
        case .whiteBalance:
            if let kelvin = parameters?.whiteBalance {
                return .whiteBalance(kelvin == 0 ? .auto : .kelvin(Int(clamping: kelvin)))
            }
        default: break
        }
        guard shootingMode == reportedMode else { return nil }
        return snapshot?.settings[key]?.value
    }

    var zoomValue: Double? {
        guard case .zoom(let factor) = value(.zoom) else { return nil }
        return factor
    }

    private func adoptSnapshot(_ value: CameraSnapshot) {
        if value.recording.value == .recording {
            if recordingZoomAnchor == nil {
                recordingZoomAnchor = value.settings[.zoom]?.value?.numericValue ?? reportedParameters?.zoom
            }
        } else if value.recording.value == .idle {
            recordingZoomAnchor = nil
        }
        if snapshot != value { snapshot = value }
    }

    var zoomLimits: ConsoleZoom? {
        guard let cameraProfile, let shootingMode, let domain = descriptor(.zoom)?.domain else { return nil }
        return ConsoleZoom(profile: cameraProfile, mode: shootingMode, format: parameters?.format, domain: domain,
                           recording: recording, reportedZoom: recordingZoomAnchor)
    }

    func setZoom(_ factor: Double, duringDrag: Bool = false) {
        guard canSet(.zoom), !processingCapture, let mode = shootingMode,
              zoomLimits?.allows(factor) == true else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.zoom = factor
        select(changes)
        enqueueSetting(String(localized: "console.error.setting"), requiresIdle: false,
                       zoomMode: mode, isZoomPreview: duringDrag, coalesceKey: "zoom.\(mode)") { controller, target, isCurrent in
            try await controller.applyMode(mode, through: target)
            guard isCurrent() else { throw CancellationError() }
            guard controller.zoomLimits?.allows(factor) == true else { throw ControlError.settingUnavailable }
            try await controller.submit(.set(.zoom(factor)), through: target, waitForObservation: !duringDrag)
            guard isCurrent() else { throw CancellationError() }
        }
    }

    func canSet(_ key: SettingKey) -> Bool {
        let available = key == .recording ? (canControl && (!hasPendingSettings || recording)) : canWriteSettings
        guard available, let setting = descriptor(key) else { return false }
        return setting.access == .readWrite && setting.availability == .available
    }

    func set(_ setting: SettingValue) {
        guard canSet(setting.key), let mode = shootingMode, let cameraProfile else { return }
        var changes = ConsoleParameters(mode: mode)
        switch setting {
        case .whiteBalance(.auto): changes.whiteBalance = 0
        case .whiteBalance(.kelvin(let kelvin)):
            guard let value = UInt64(exactly: kelvin), value > 0, cameraProfile.whiteBalance.allows(value) else { return }
            changes.whiteBalance = value
        default: return
        }
        enqueueParameters(changes, title: String(localized: "console.error.setting"),
                          coalesceKey: "whiteBalance") { commands, isCurrent in
            let bank = mode.functionMode.rawValue
            let kelvin = changes.whiteBalance ?? 0
            let request = try kelvin == 0
                ? LunaProtocol.setWhiteBalanceAuto(functionMode: bank)
                : LunaProtocol.setWhiteBalanceKelvin(kelvin, functionMode: bank)
            return try await commands.write(request, in: mode, options: [39],
                                            isCurrent: isCurrent) { $0.whiteBalance == kelvin }
        }
    }

    func setMode(_ mode: LunaShootingMode) {
        guard canEditShootingSettings,
              cameraProfile?.captureModes.contains(ConsoleCaptureMode(mode)) == true else { return }
        let switchingContinuousOff = continuousPhoto && mode == .photo
        guard shootingMode != mode || continuousPhoto else { return }
        stopContinuousCapture()
        continuousPhoto = false
        // 只有明确选回单张照片才关掉连拍偏好；切到视频仍记住上次连拍。
        if mode == .photo { rememberContinuousPreference() }
        if shootingMode == mode, switchingContinuousOff { return }
        let settings = selectedParameters[ConsoleCaptureMode(mode)]
        selectedMode = mode
        enqueueSetting(String(localized: "console.error.mode"), coalesceKey: "mode") { controller, target, isCurrent in
            try await controller.applyMode(mode, through: target)
            guard isCurrent() else { throw CancellationError() }
            controller.scheduleParameterRead()
        }
        // 切模式后按手动同链路快速补回该模式记忆参数，不再走整组 restore。
        if let settings, settings.hasValues {
            enqueueManualParameterWrites(settings, title: String(localized: "console.error.setting"))
        }
    }

    /// 进入 App 侧连续拍摄；相机会切到单张照片模式。
    func setContinuousPhotoMode() {
        guard canEditShootingSettings,
              cameraProfile?.captureModes.contains(.photo) == true else { return }
        if continuousPhoto, shootingMode == .photo { return }
        stopContinuousCapture()
        continuousPhoto = true
        rememberContinuousPreference()
        if shootingMode == .photo { return }
        let settings = selectedParameters[.photo]
        selectedMode = .photo
        enqueueSetting(String(localized: "console.error.mode"), coalesceKey: "mode") { controller, target, isCurrent in
            try await controller.applyMode(.photo, through: target)
            guard isCurrent() else { throw CancellationError() }
            controller.scheduleParameterRead()
        }
        if let settings, settings.hasValues {
            enqueueManualParameterWrites(settings, title: String(localized: "console.error.setting"))
        }
    }

    func setContinuousInterval(_ interval: ConsoleShootInterval) {
        guard continuousPhoto else { return }
        continuousInterval = interval
        rememberContinuousPreference()
    }

    /// 打开或关闭连续拍摄时的自动归位。只改开关，不动手动记忆的角度。
    func setContinuousGimbalReturn(_ enabled: Bool) {
        guard continuousGimbalReturn != enabled else { return }
        continuousGimbalReturn = enabled
        if !enabled { continuousReturnPosition = nil }
        rememberContinuousPreference()
        guard enabled, continuousShooting, continuousReturnPosition == nil else { return }
        let generation = continuousGeneration
        Task { @MainActor [weak self] in
            await self?.rememberContinuousReturnPosition(generation: generation)
        }
    }

    func toggleContinuousCapture() {
        if continuousShooting {
            stopContinuousCapture()
            return
        }
        startContinuousCapture()
    }

    func stopContinuousCapture() {
        continuousGeneration = UUID()
        continuousShooting = false
        continuousReturnPosition = nil
    }

    /// 拍照按钮可以按：没有在转圈，也没有被禁用。连拍间隔从这一刻起算。
    private var continuousShutterReady: Bool {
        canTakePhoto && !showsShutterActivity
    }

    /// 开始按间隔拍照。第一张在按钮可用时立刻拍，之后每次都等按钮可用再计满间隔。单张失败不结束，只有彻底断联才停。
    private func startContinuousCapture() {
        guard !continuousShooting, continuousPhoto, shootingMode == .photo else { return }
        let generation = UUID()
        continuousGeneration = generation
        continuousShooting = true
        continuousReturnPosition = nil
        releaseGimbal()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 本段连拍再挂一份后台任务，与 Lifetime 的音频保活叠加，降低刷新时序空窗。
            let localBackground = ConnectionBackgroundWindow()
            localBackground.begin(keepAlive: true)
            defer {
                localBackground.end()
                if self.continuousGeneration == generation {
                    self.continuousShooting = false
                    self.continuousReturnPosition = nil
                }
            }
            if self.continuousGimbalReturn {
                await self.rememberContinuousReturnPosition(generation: generation)
            }
            var afterShot = false
            while self.continuousGeneration == generation, self.continuousShooting {
                if self.continuousLinkLost { break }
                while self.continuousGeneration == generation, self.continuousShooting,
                      !self.continuousLinkLost, !self.continuousShutterReady {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard self.continuousGeneration == generation, self.continuousShooting,
                      !self.continuousLinkLost else { break }
                if afterShot {
                    let readyAt = Date()
                    let next = ConsoleContinuousCapture.nextTrigger(
                        firedAt: readyAt, interval: self.continuousInterval.seconds)
                    var stayedReady = true
                    while Date() < next {
                        if self.continuousGeneration != generation || !self.continuousShooting || self.continuousLinkLost {
                            stayedReady = false
                            break
                        }
                        // 按钮中途又不可用时，这段作废，等它再次可用后重新计满间隔。
                        if !self.continuousShutterReady {
                            stayedReady = false
                            break
                        }
                        let slice = min(0.25, next.timeIntervalSinceNow)
                        if slice <= 0 { break }
                        try? await Task.sleep(for: .seconds(slice))
                    }
                    guard stayedReady, self.continuousGeneration == generation, self.continuousShooting,
                          !self.continuousLinkLost else { continue }
                }
                await self.fireContinuousStill()
                afterShot = true
            }
        }
    }

    /// 记下按下连拍时的云台角度。写到单独的字段，不覆盖手动记忆。
    private func rememberContinuousReturnPosition(generation: UUID) async {
        guard continuousGeneration == generation, continuousGimbalReturn, supportsGimbal,
              let cameraID = selectedCamera?.id, let target = session else { return }
        do {
            let angles = try await gimbalCommands(through: target).readPosition(cameraID: cameraID)
            guard continuousGeneration == generation, continuousGimbalReturn,
                  let position = ConsoleGimbalPosition(cameraID: cameraID, yaw: angles.yaw, pitch: angles.pitch,
                                                       isFlipped: gimbalIsFlipped) else { return }
            continuousReturnPosition = position
        } catch {
            AppLog.error(error, context: "console.continuous.gimbal")
        }
    }

    /// 先等归位结束，再拍这一张。归位失败就跳过这一张，避免转到一半就曝光。
    private func fireContinuousStill() async {
        guard canControl, let target = session else { return }
        releaseGimbal()
        busy = true
        defer {
            if session === target {
                busy = false
                shutterCommand = false
                if queuedShutterPresses > 0 {
                    queuedShutterPresses -= 1
                    takePhoto()
                }
                if !busy { startSettingWrites() }
            }
        }
        do {
            if continuousGimbalReturn, let position = continuousReturnPosition {
                try await returnContinuousGimbal(position, through: target)
            }
            try await captureStill(through: target)
        } catch is CancellationError {
            return
        } catch {
            guard session === target else { return }
            AppLog.error(error, context: "console.continuous")
        }
    }

    /// 转到这一轮连拍记下的角度，并等到转动结束。不弹手动定位的提示。
    private func returnContinuousGimbal(
        _ position: ConsoleGimbalPosition, through target: LunaCameraSession
    ) async throws {
        try await stopSubjectTracking(through: target)
        var commands = gimbalCommands(through: target)
        commands.atAxisLimit = { self.gimbalWasAtLimit }
        _ = try await commands.restore(position, currentFlip: gimbalIsFlipped, travelLimit: .seconds(60))
        if gimbalSleeping { try? await wakeGimbalSequence(target) }
    }

    /// 重连耗尽或用户断开才算彻底断联；重连过程中连拍继续等。
    private var continuousLinkLost: Bool {
        selectedCamera == nil || connectionDropped
    }

    func takePhoto() {
        guard let mode = shootingMode, mode.isPhoto else { return }
        guard cameraProfile?.captureModes.contains(ConsoleCaptureMode(mode)) == true else { return }
        guard connected, albumControlOwner == nil, !reconnecting, !restartingPreview else { return }
        // 处理中仍接受按下；命令通道忙就排队，空闲后马上拍下一张。
        if busy {
            queuedShutterPresses += 1
            return
        }
        guard canControl else { return }
        perform(String(localized: "console.error.photo"), presentation: .shutter) { target in
            try await self.captureStill(through: target)
        }
    }

    /// 拍照各段等待的上限。先等满这次曝光，再留 65 秒给写卡和命令回读。自动快门没有选定值，按当前模式最长的一档算。
    private func photoCaptureTimeout() -> Duration {
        let selected = parameters?.exposure?.shutter
        let exposure: Double
        if let selected, selected.isFinite, selected > 0 {
            exposure = selected
        } else if let mode = shootingMode {
            let choices = cameraProfile?.shutterChoices(mode: mode, format: parameters?.format, firmware: firmware) ?? []
            exposure = choices.max() ?? 0
        } else {
            exposure = 0
        }
        return .seconds(exposure + 65)
    }

    /// 拍一张并等到完成。进度只反映在快门转圈上，不再弹出拍摄结果提示。
    private func captureStill(through target: LunaCameraSession) async throws {
        let photoMode = shootingMode ?? .photo
        try await applyMode(photoMode, through: target)
        try await ensureSelectedParameters(in: photoMode, through: target)
        try validate(target)
        let timeout = photoCaptureTimeout()
        let clock = ContinuousClock()
        // 上一张仍在曝光或写卡时等它结束，不把这次快门当成失败。
        if capture?.isSettledIdle != true {
            let deadline = clock.now.advanced(by: timeout)
            while capture?.isSettledIdle != true, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
                try validate(target)
            }
        }
        guard capture?.isSettledIdle == true else { throw ControlError.cameraBusy }
        let photo = UUID()
        pendingPhoto = photo
        photoCompletion = nil
        defer {
            if pendingPhoto == photo {
                pendingPhoto = nil
                photoCompletion = nil
            }
        }
        let request = try LunaProtocol.takePicture(mode: photoMode == .pano ? .gimbalPano : .normal)
        _ = try await target.control(request, timeout: timeout)
        try validate(target)
        let deadline = clock.now.advanced(by: timeout)
        let idleAfter = clock.now.advanced(by: .seconds(3))
        var sawCapture = false
        while clock.now < deadline {
            if capture?.isSettledIdle == false { sawCapture = true }
            if photoCompletion == true || (clock.now >= idleAfter && capture?.isSettledIdle == true) { break }
            try await Task.sleep(for: .milliseconds(250))
            try validate(target)
        }
        // 8201 的非零码在长曝光结束时也会出现，但片子已经写上。只有相机根本没开拍才算失败。
        if photoCompletion == false, !sawCapture { throw ControlError.captureFailed }
    }

    func toggleRecording() {
        guard canSet(.recording), let state = snapshot?.recording.value,
              state == .idle || state == .recording else { return }
        let mode = shootingMode
        perform(state == .idle ? String(localized: "console.error.recordStart") : String(localized: "console.error.recordStop")) { target in
            if state == .idle, let mode {
                try await self.applyMode(mode, through: target)
                try await self.ensureSelectedParameters(in: mode, through: target)
            }
            try await self.submit(state == .idle ? .startRecording : .stopRecording, through: target)
        }
    }

    func focusPreview(at point: CGPoint, aspect: Double) -> Bool {
        guard canUsePreviewGestures, let shootingMode, cameraProfile?.focusChoices(for: shootingMode).isEmpty == false else { return false }
        return sendPreviewCommand(title: "console.preview.focusFailed") { completion in
            try subjectTracking.focus(x: Double(point.x), y: Double(point.y), aspectRatio: aspect, finished: completion)
        }
    }

    func trackPreview(_ box: LunaSubjectTracking.Box) {
        guard canTrackSubject else { return }
        _ = sendPreviewCommand(title: "console.preview.trackingFailed") { completion in
            try subjectTracking.start(box, finished: completion)
        }
    }

    func cancelPreviewTracking() {
        guard canUsePreviewGestures, tracking.active else { return }
        _ = sendPreviewCommand(title: "console.preview.trackingFailed") { completion in
            subjectTracking.cancel(finished: completion)
        }
    }

    private func sendPreviewCommand(
        title: String.LocalizationValue,
        send: (@escaping @MainActor (Error?) -> Void) throws -> Void
    ) -> Bool {
        guard previewCommandID == nil, subjectTracking.admitsControl else { return false }
        let id = UUID()
        previewCommandID = id
        do {
            try send { [weak self] error in
                guard let self, previewCommandID == id else { return }
                previewCommandID = nil
                if let error, !(error is CancellationError) { report(String(localized: title), error: error) }
            }
            return true
        } catch {
            previewCommandID = nil
            report(String(localized: title), error: error)
            return false
        }
    }

    func setGimbalMode(_ mode: LunaGimbalMode) {
        guard canEditGimbalMode, gimbalMode != mode, cameraProfile?.gimbalChoices.contains(mode) == true else { return }
        selectedGimbalMode = mode
        enqueueSetting(String(localized: "console.error.gimbalMode"), requiresIdle: false,
                       coalesceKey: "gimbalMode") { controller, target, isCurrent in
            guard isCurrent() else { throw CancellationError() }
            try await controller.writeGimbalMode(mode, through: target)
            guard isCurrent() else { throw CancellationError() }
        }
    }

    private func writeGimbalMode(_ mode: LunaGimbalMode, through target: LunaCameraSession) async throws {
        guard !gimbalSleeping else { throw ControlError.gimbalAsleep }
        let request = try LunaProtocol.setGimbalMode(mode, functionMode: backend.functionMode)
        _ = try await target.control(request)
        try validate(target)
        await backend.refreshSettings()
        try validate(target)
        guard reportedGimbalMode == mode else { throw ControlError.readbackMismatch }
    }

    func moveGimbal(pan: Double, tilt: Double) {
        gimbalNudge?.cancel()
        gimbalNudge = nil
        // 连续拍摄期间拨杆不能再带动云台。
        guard supportsGimbal, canControl, !gimbalSleeping, !continuousShooting, pan != 0 || tilt != 0 else {
            releaseGimbal()
            return
        }
        motion.hold(pan: pan, tilt: tilt)
    }

    func nudgeGimbal(pan: Double, tilt: Double) {
        moveGimbal(pan: pan, tilt: tilt)
        guard motion.isHeld else { return }
        gimbalNudge = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(240)) } catch { return }
            self?.releaseGimbal()
        }
    }

    func releaseGimbal() {
        gimbalNudge?.cancel()
        gimbalNudge = nil
        guard motion.isHeld else { return }
        motion.endHold()
        guard let target = session, connected else { return }
        Task { [weak self] in
            guard let self, session === target, !motion.isHeld,
                  let request = try? LunaProtocol.gimbalReleaseRequest() else { return }
            _ = try? await target.control(request, timeout: .seconds(2))
        }
    }

    func aimGimbal(recenter: Bool) {
        guard supportsGimbal, canControl, !gimbalSleeping, !continuousShooting else { return }
        perform(recenter ? String(localized: "console.error.recenter") : String(localized: "console.error.flip")) { target in
            let request = try recenter ? LunaProtocol.gimbalRecenterRequest() : LunaProtocol.gimbalFlipRequest()
            _ = try await target.control(request)
            // 连接后先当正向。回中回到正向；翻转相对这个正向切换。没按过这两键时不和记忆比。
            if recenter {
                self.gimbalIsFlipped = false
            } else {
                self.gimbalIsFlipped = !(self.gimbalIsFlipped ?? false)
            }
        }
    }

    // MARK: - 原生拍摄参数与记忆

    /// 在当前模式的相机格式菜单内选择组合规格。
    /// 照片下若当前开着实况且目标规格不支持，先关实况再写入规格。
    func setFormat(_ code: UInt64) {
        guard canEditShootingSettings, let mode = shootingMode, let cameraProfile, parameters?.format != code,
              cameraProfile.supports(code, in: mode) else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.format = code
        let forcedColor = mode.isPhoto ? nil : cameraProfile.requiredColor(for: code)
        changes.color = forcedColor?.rawValue
        let disableLive = mode == .photo
            && parameters?.livePhoto == true
            && !cameraProfile.allowsLivePhoto(format: code)
        if disableLive {
            changes.livePhoto = false
            showNotice(String(localized: "console.livePhoto.turnedOffForFormat"))
        }
        if var pending = selectedParameters[changes.mode] {
            pending.format = code
            if disableLive { pending.livePhoto = false }
            selectedParameters[changes.mode] = pending.restorable(for: cameraProfile, firmware: firmware)
        }
        enqueueParameters(changes, title: String(localized: "console.error.format"),
                          coalesceKey: "format") { commands, isCurrent in
            var current = try await commands.read(mode)
            if disableLive {
                if current.livePhoto == nil { current.livePhoto = try? await commands.readLivePhoto() }
                if current.livePhoto == true {
                    current = try await commands.writeLivePhoto(false, isCurrent: isCurrent)
                }
            }
            let request = try commands.formatRequest(code, in: mode)
            let options: [UInt32] = mode.isPhoto ? [40] : [31, 35]
            current = try await commands.write(request, in: mode, options: options,
                                               isCurrent: isCurrent) {
                $0.format == code && (forcedColor == nil || $0.color == forcedColor?.rawValue)
            }
            // 规格回读不含实况选项，避免 lastReported 把刚关掉的实况又填回来。
            if disableLive { current.livePhoto = false }
            return current
        }
    }

    /// 照片格式在 JPG 与 JPG+RAW 间切换，以相机回读确认。
    func setPhotoRAW(_ enabled: Bool) {
        guard canEditShootingSettings, shootingMode == .photo, cameraProfile?.rawPhoto == true,
              let current = parameters?.rawCapture, current != enabled else { return }
        var changes = ConsoleParameters(mode: .photo)
        changes.rawCapture = enabled
        enqueueParameters(changes, title: String(localized: "console.error.raw"),
                          coalesceKey: "raw") { commands, isCurrent in
            try await commands.write(ConsoleCaptureFormats.rawRequest(enabled), in: .photo, options: [25],
                                     isCurrent: isCurrent) {
                ($0.rawCapture ?? false) == enabled
            }
        }
    }

    /// 实况照片使用标准清晰度；超清下开启时先切到同比例标准规格，并给出轻提示。
    func setLivePhoto(_ enabled: Bool) {
        guard canEditShootingSettings, shootingMode == .photo, !continuousShooting, let cameraProfile,
              !cameraProfile.livePhotoFormatIDs.isEmpty, parameters?.livePhoto != enabled else { return }
        var changes = ConsoleParameters(mode: .photo)
        changes.livePhoto = enabled
        if enabled, !cameraProfile.allowsLivePhoto(format: parameters?.format) {
            guard let standard = standardPhotoFormat(matching: parameters?.format, in: cameraProfile) else { return }
            changes.format = standard.id
            showNotice(String(localized: "console.livePhoto.switchToStandard"))
        }
        enqueueParameters(changes, title: String(localized: "console.error.livePhoto"),
                          coalesceKey: "livePhoto") { commands, isCurrent in
            var current = try await commands.read(.photo)
            if enabled, let format = changes.format, current.format != format {
                let request = try commands.formatRequest(format, in: .photo)
                current = try await commands.write(request, in: .photo, options: [40],
                                                   isCurrent: isCurrent) { $0.format == format }
            }
            if current.livePhoto != enabled {
                current = try await commands.writeLivePhoto(enabled, isCurrent: isCurrent)
            }
            return current
        }
    }

    /// 为实况照片挑选同比例标准规格；没有同比例时取第一个标准规格。
    private func standardPhotoFormat(
        matching formatID: UInt64?, in profile: ConsoleCameraProfile
    ) -> ConsoleCaptureFormats.Photo? {
        let standards = profile.photoFormats.filter {
            $0.quality == .standard && profile.allowsLivePhoto(format: $0.id)
        }
        let ratio = formatID.flatMap { id in profile.photoFormats.first { $0.id == id }?.ratio }
        return standards.first { $0.ratio == ratio } ?? standards.first
    }

    func setExposureControlMode(_ exposureMode: LunaIQ3AMode) {
        guard canSwitchExposureControlMode, let mode = shootingMode,
              exposureMode != exposureControlMode else { return }
        let bank = ConsoleCaptureMode(mode)
        if exposureMode == .basic, reportedParameters?.exposureControlMode == .professional,
           self.exposureControlMode == .professional, let parameters {
            professionalPresetBanks[bank] = parameters
        }
        var selection = selectedParameters[bank] ?? ConsoleParameters(mode: mode)
        selection.exposureControlMode = exposureMode
        if exposureMode == .basic {
            selection.clearProfessionalOverrides()
            // 保留已在下发的指令，跳过队列里尚未发送的专业参数。
            let inFlightCount = settingTask == nil ? 0 : 1
            let pending = settingWrites.dropFirst(inFlightCount).filter {
                $0.coalesceKey != "exposure" && $0.coalesceKey != "whiteBalance" && $0.coalesceKey != "metering"
            }
            settingWrites = Array(settingWrites.prefix(inFlightCount)) + pending
        }
        selectedParameters[bank] = selection
        enqueueSetting(String(localized: "console.error.exposure"), coalesceKey: "exposureControlMode") {
            controller, target, isCurrent in
            let commands = try controller.commands(through: target)
            let result = try await commands.writeExposureControlMode(exposureMode, in: mode, isCurrent: isCurrent)
            try controller.validate(target)
            guard isCurrent() else { throw CancellationError() }
            controller.acceptReported(result)
        }
    }

    /// 固定感光度或完全自动；传入非空值时清除 ISO Max。
    func setExposureISO(_ iso: UInt64?) {
        guard let existing = parameters?.exposure,
              iso.map({ cameraProfile?.exposure.iso.contains($0) == true }) ?? true else { return }
        setExposure(ConsoleExposure(iso: iso, shutter: existing.shutter, isoTopLimit: nil))
    }

    /// Auto ISO 上限（如 800Max）；与固定感光度互斥。
    func setExposureISOMax(_ limit: UInt64) {
        guard let existing = parameters?.exposure,
              cameraProfile?.exposure.isoMax.contains(limit) == true else { return }
        setExposure(ConsoleExposure(iso: nil, shutter: existing.shutter, isoTopLimit: limit))
    }

    func setExposureShutter(_ shutter: Double?) {
        guard let existing = parameters?.exposure,
              shutter.map(shutterChoices.contains) ?? true else { return }
        setExposure(ConsoleExposure(iso: existing.iso, shutter: shutter, isoTopLimit: existing.isoTopLimit))
    }

    var shutterChoices: [Double] {
        guard let shootingMode, let cameraProfile else { return [] }
        return cameraProfile.shutterChoices(mode: shootingMode, format: parameters?.format, firmware: firmware)
    }

    private func setExposure(_ exposure: ConsoleExposure) {
        // 必须用 matchesIntent：matches 会把无上限 Auto 与残留/当前 Max 当成相同，Max→Auto 会被跳过不下发。
        guard canAdjustExposure, exposure.isComplete, let mode = shootingMode,
              !exposure.matchesIntent(parameters?.exposure) else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.exposure = exposure
        enqueueParameters(changes, title: String(localized: "console.error.exposure"),
                          coalesceKey: "exposure") { commands, isCurrent in
            try await commands.writeExposure(exposure, in: mode, isCurrent: isCurrent)
        }
    }

    func setExposureBias(_ tenths: Int32) {
        guard canEditShootingSettings, let mode = shootingMode, mode != .pano,
              ConsoleParameters.exposureBiasChoices.contains(tenths),
              let current = parameters?.exposureBiasTenths, current != tenths else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.exposureBiasTenths = tenths
        enqueueParameters(changes, title: String(localized: "console.error.exposure"),
                          coalesceKey: "exposureBias") { commands, isCurrent in
            try await commands.writeExposureBias(tenths, in: mode, isCurrent: isCurrent)
        }
    }

    func setMetering(_ facePriority: Bool) {
        guard canEditShootingSettings, let mode = shootingMode, mode != .pano,
              let current = parameters?.faceMetering, current != facePriority else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.faceMetering = facePriority
        enqueueParameters(changes, title: String(localized: "console.error.setting"),
                          coalesceKey: "metering") { commands, isCurrent in
            try await commands.writeMetering(facePriority, in: mode, isCurrent: isCurrent)
        }
    }

    /// 当前拍摄模式在机型 JSON 里声明的对焦档。
    var focusChoices: [LunaAFMode] {
        guard let cameraProfile, let shootingMode else { return [] }
        return cameraProfile.focusChoices(for: shootingMode)
    }

    var currentFocusChoice: LunaAFMode? {
        focusChoices.first { $0.rawValue == parameters?.autofocus }
    }

    func setNativeFocus(_ focus: LunaAFMode) {
        guard canEditShootingSettings, let mode = shootingMode, focusChoices.contains(focus),
              parameters?.autofocus != focus.rawValue else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.autofocus = focus.rawValue
        enqueueParameters(changes, title: String(localized: "console.error.setting"),
                          coalesceKey: "focus") { commands, isCurrent in
            let request = try LunaProtocol.setAFMode(focus, functionMode: mode.functionMode.rawValue)
            return try await commands.write(request, in: mode, options: [93],
                                            isCurrent: isCurrent) { $0.autofocus == focus.rawValue }
        }
    }

    func setNativeColor(_ color: LunaColorMode) {
        guard canEditShootingSettings, let mode = shootingMode,
              cameraProfile?.colorChoices(for: parameters?.format, mode: mode).contains(color) == true,
              parameters?.color != color.rawValue else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.color = color.rawValue
        enqueueParameters(changes, title: String(localized: "console.error.setting"),
                          coalesceKey: "color") { commands, isCurrent in
            let request = try LunaProtocol.setColorMode(color, functionMode: mode.functionMode.rawValue)
            return try await commands.write(request, in: mode, options: [35],
                                            isCurrent: isCurrent) { $0.color == color.rawValue }
        }
    }

    /// 当前模式可见的画面项。隐藏条件来自 JSON 的 visibleWhen。
    func visibleImageControls() -> [ConsoleCameraProfile.ImageControl] {
        guard let cameraProfile, let shootingMode else { return [] }
        return cameraProfile.imageControls(for: shootingMode).filter { control in
            control.isVisible { parameters?.imageValue(id: $0) }
        }
    }

    /// 按标识取当前可见的画面项。
    func visibleImageControl(id: String) -> ConsoleCameraProfile.ImageControl? {
        visibleImageControls().first { $0.id == id }
    }

    /// 这项在当前格式下可选的线值。
    func imageChoiceValues(for control: ConsoleCameraProfile.ImageControl) -> [UInt64] {
        guard let cameraProfile, let shootingMode else { return control.choices }
        return cameraProfile.choiceValues(for: control, format: parameters?.format, mode: shootingMode)
    }

    /// 把画面项写成 JSON 里的默认值。格式收窄后默认值不在列表里时改写唯一可选项。
    func restoreImageControl(_ control: ConsoleCameraProfile.ImageControl) {
        let choices = imageChoiceValues(for: control)
        let value = choices.contains(control.defaultValue) ? control.defaultValue : (choices.count == 1 ? choices[0] : nil)
        guard let value else { return }
        setImageControl(control, value: value)
    }

    /// 写入一项画面调节。对焦和色彩走原有确认字段，其余按 option 号下发。
    func setImageControl(_ control: ConsoleCameraProfile.ImageControl, value: UInt64) {
        if control.id == "metering" {
            setMetering(value != 0)
            return
        }
        if control.id == "focus", let focus = LunaAFMode(rawValue: value) {
            setNativeFocus(focus)
            return
        }
        if control.id == "color", let color = LunaColorMode(rawValue: value) {
            setNativeColor(color)
            return
        }
        guard canEditShootingSettings, let mode = shootingMode,
              visibleImageControl(id: control.id) != nil,
              imageChoiceValues(for: control).contains(value),
              parameters?.imageValue(id: control.id) != value,
              let type = LunaPhotographyType(rawValue: control.option) else { return }
        var changes = ConsoleParameters(mode: mode)
        changes.setImageValue(id: control.id, value)
        enqueueParameters(changes, title: String(localized: "console.error.setting"),
                          coalesceKey: control.id) { commands, isCurrent in
            let request = try LunaProtocol.setPhotographyValue(type, value, functionMode: mode.functionMode.rawValue)
            return try await commands.write(request, in: mode, options: [control.option],
                                            isCurrent: isCurrent) { $0.imageValue(id: control.id) == value }
        }
    }

    var canSavePreset: Bool {
        canChangeMode && shootingMode != .pano && exposureControlMode != nil && parameters != nil
    }

    func savePreset(name: String) {
        guard canSavePreset, let cameraProfile, var settings = parameters, let exposureControlMode else { return }
        // 连拍是 App 调度态，不在机身回读里，保存时显式写入。
        if settings.mode == .photo {
            settings.continuousPhoto = continuousPhoto
            settings.continuousInterval = continuousPhoto ? continuousInterval : nil
        } else {
            settings.continuousPhoto = nil
            settings.continuousInterval = nil
        }
        if exposureControlMode == .basic, professionalPresetBanks[settings.mode]?.exposure == nil {
            let snapshot = settings
            let mode = snapshot.mode.native
            enqueueSetting(String(localized: "console.error.presetSave"), coalesceKey: "preset.readProfessional") {
                controller, target, isCurrent in
                let commands = try controller.commands(through: target)
                let professional: ConsoleParameters
                do {
                    professional = try await commands.writeExposureControlMode(.professional, in: mode, isCurrent: isCurrent)
                } catch {
                    if isCurrent() {
                        _ = try? await commands.writeExposureControlMode(.basic, in: mode, isCurrent: isCurrent)
                    }
                    throw error
                }
                let basic = try await commands.writeExposureControlMode(.basic, in: mode, isCurrent: isCurrent)
                guard isCurrent() else { throw CancellationError() }
                controller.acceptReported(basic)
                guard professional.exposure != nil else { throw ControlError.readbackMismatch }
                controller.professionalPresetBanks[snapshot.mode] = professional
                var preset = snapshot
                preset.useProfessionalSettings(from: professional)
                try controller.persistPreset(name: name, settings: preset, profile: cameraProfile)
            }
            return
        }
        if exposureControlMode == .basic, let professional = professionalPresetBanks[settings.mode] {
            settings.useProfessionalSettings(from: professional)
        }
        settings.exposureControlMode = .professional
        do {
            try persistPreset(name: name, settings: settings, profile: cameraProfile)
        } catch {
            report(String(localized: "console.error.presetSave"), error: error)
        }
    }

    private func persistPreset(name: String, settings: ConsoleParameters, profile: ConsoleCameraProfile) throws {
        let saved = settings.restorable(for: profile, firmware: firmware)
        let preset = ConsoleMemory.Preset(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                          savedAt: .now, parameters: saved, profileID: profile.id)
        var next = memory
        next.presets.insert(preset, at: 0)
        try saveMemory(next, notice: String(localized: "console.notice.presetSaved"))
    }

    func deletePreset(_ id: UUID) {
        var next = memory
        next.presets.removeAll { $0.id == id }
        do {
            try memoryStore.save(next)
            memory = next
        } catch { report(String(localized: "console.error.presetDelete"), error: error) }
    }

    /// 重命名已保存的参数预设（可留空）。
    func renamePreset(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = memory
        guard let index = next.presets.firstIndex(where: { $0.id == id }) else { return }
        let old = next.presets[index]
        guard old.name != trimmed else { return }
        next.presets[index] = ConsoleMemory.Preset(
            id: old.id, name: trimmed, savedAt: old.savedAt,
            parameters: old.parameters, profileID: old.profileID)
        do {
            try memoryStore.save(next)
            memory = next
        } catch { report(String(localized: "console.error.presetSave"), error: error) }
    }

    /// 拖动调整参数预设顺序并持久化。
    func movePresets(from source: IndexSet, to destination: Int) {
        var next = memory
        var presets = next.presets
        let moving = source.sorted().map { presets[$0] }
        for index in source.sorted(by: >) {
            presets.remove(at: index)
        }
        let insertAt = destination - source.filter { $0 < destination }.count
        presets.insert(contentsOf: moving, at: insertAt)
        next.presets = presets
        do {
            try memoryStore.save(next)
            memory = next
        } catch { report(String(localized: "console.error.presetSave"), error: error) }
    }

    func applyPreset(_ preset: ConsoleMemory.Preset) {
        guard canEditShootingSettings, let settings = supportedParameters(in: preset) else { return }
        applyRememberedParameters(
            settings,
            title: String(localized: "console.error.presetApply"),
            success: String(localized: "console.notice.presetApplied")
        )
    }

    /// 套用最新预设，沿用当前串行队列等待在飞指令退出。
    private func applyRememberedParameters(
        _ settings: ConsoleParameters,
        title: String,
        success: String?
    ) {
        stopContinuousCapture()
        continuousPhoto = settings.mode == .photo && settings.continuousPhoto == true
        if continuousPhoto, let interval = settings.continuousInterval {
            continuousInterval = interval
        }
        rememberContinuousPreference()
        settingWrites.removeAll()
        settingEpoch.removeAll()
        settingsError = nil

        selectedMode = settings.mode.native
        selectedParameters[settings.mode] = settings
        enqueueManualParameterWrites(settings, title: title, success: success)
    }

    /// 切模式、应用预设或重连时，先确认 A／M，再写入其余拍摄参数。
    private func enqueueManualParameterWrites(_ settings: ConsoleParameters, title: String, success: String? = nil) {
        guard let cameraProfile else { return }
        let saved = settings.restorable(for: cameraProfile, currentFormat: reportedBanks[settings.mode]?.format,
                                        firmware: firmware)
        guard saved.hasValues else { return }
        if let zoom = saved.zoom { setZoom(zoom, duringDrag: false) }
        let mode = settings.mode.native
        select(saved)
        enqueueSetting(title, coalesceKey: "apply.\(settings.mode)") { controller, target, isCurrent in
            try await controller.applyMode(mode, through: target)
            guard isCurrent() else { throw CancellationError() }
            let exposureMode = try await controller.commands(through: target).apply(saved, isCurrent: isCurrent)
            try controller.validate(target)
            guard isCurrent() else { throw CancellationError() }
            if let exposureMode {
                var confirmed = ConsoleParameters(mode: mode)
                confirmed.exposureControlMode = exposureMode
                controller.acceptReported(confirmed)
            }
            if let success { controller.showNotice(success) }
        }
    }

    func supportedParameters(in preset: ConsoleMemory.Preset) -> ConsoleParameters? {
        guard let cameraProfile, preset.parameters.mode != .pano,
              preset.parameters.exposureControlMode == .professional,
              cameraProfile.captureModes.contains(preset.parameters.mode) else { return nil }
        let bank = preset.parameters.mode
        let currentFormat = selectedParameters[bank]?.format ?? reportedBanks[bank]?.format
        let values = preset.parameters.restorable(for: cameraProfile, currentFormat: currentFormat, firmware: firmware)
        return values.hasValues ? values : nil
    }

    private func select(_ changes: ConsoleParameters) {
        selectedMode = changes.mode.native
        var current = selectedParameters[changes.mode] ?? ConsoleParameters(mode: changes.mode.native)
        current.merge(changes)
        selectedParameters[changes.mode] = current
    }

    private func acceptReported(_ changes: ConsoleParameters) {
        guard reportedMode == changes.mode.native else { return }
        // 相机侧主动改规格（如竖拍）时，丢掉冲突的本地覆盖，避免 UI 仍显示旧横幅。
        if let format = changes.format, !isWritingFormat,
           let selectedFormat = selectedParameters[changes.mode]?.format,
           selectedFormat != format {
            releaseSelectedFormatOverride(for: changes.mode)
        }
        // 机身侧切换过模式后，拍照前补参不能把旧专业曝光写回。
        if !hasPendingSettings, let mode = changes.exposureControlMode,
           var selection = selectedParameters[changes.mode] {
            if selection.exposureControlMode != mode { selection.exposureControlMode = nil }
            if mode == .basic { selection.clearProfessionalOverrides() }
            selectedParameters[changes.mode] = selection.hasValues ? selection : nil
        }
        var current = reportedParameters ?? ConsoleParameters(mode: changes.mode.native)
        current.merge(changes)
        if current.exposureControlMode == .professional,
           changes.exposureControlMode == .professional || exposureControlMode == .professional {
            var professional = professionalPresetBanks[changes.mode] ?? ConsoleParameters(mode: changes.mode.native)
            professional.merge(changes)
            professionalPresetBanks[changes.mode] = professional
        }
        if reportedBanks[changes.mode] != current { reportedBanks[changes.mode] = current }
    }

    /// 是否正在下发规格（含乐观覆盖窗口）。
    private var isWritingFormat: Bool {
        settingWrites.contains { $0.coalesceKey == "format" }
    }

    /// 清除本地规格覆盖，让显示跟随相机回读。
    private func releaseSelectedFormatOverride(for mode: ConsoleCaptureMode? = nil) {
        let bank = mode ?? shootingMode.map(ConsoleCaptureMode.init)
        guard let bank, var selection = selectedParameters[bank], selection.format != nil else { return }
        selection.format = nil
        if selection.hasValues {
            selectedParameters[bank] = selection
        } else {
            selectedParameters[bank] = nil
        }
    }

    private func ensureSelectedParameters(in mode: LunaShootingMode, through target: LunaCameraSession) async throws {
        guard let selection = selectedParameters[ConsoleCaptureMode(mode)], selection.hasValues else { return }
        if let reportedParameters, selection.isConfirmed(by: reportedParameters) { return }
        // 拍照前补参仍走逐项写入（与手动同确认逻辑），但在当前会话内 await，不另开 UI 队列。
        let result = try await commands(through: target).restore(selection)
        try validate(target)
        acceptReported(result)
    }

    private func enqueueParameters(
        _ changes: ConsoleParameters, title: String, coalesceKey: String? = nil, success: String? = nil,
        write: @escaping @MainActor (ConsoleCameraCommands, _ isCurrent: @escaping () -> Bool) async throws -> ConsoleParameters
    ) {
        select(changes)
        enqueueSetting(title, coalesceKey: coalesceKey) { controller, target, isCurrent in
            try await controller.applyMode(changes.mode.native, through: target)
            guard isCurrent() else { throw CancellationError() }
            let result = try await write(controller.commands(through: target), isCurrent)
            try controller.validate(target)
            guard isCurrent() else { throw CancellationError() }
            controller.acceptReported(result)
            if let success { controller.showNotice(success) }
        }
    }

    private func enqueueSetting(
        _ title: String, requiresIdle: Bool = true,
        zoomMode: LunaShootingMode? = nil, isZoomPreview: Bool = false,
        coalesceKey: String? = nil,
        write: @escaping @MainActor (CameraController, LunaCameraSession, _ isCurrent: @escaping () -> Bool) async throws -> Void
    ) {
        // 新意图清掉上次硬失败冻队状态，允许继续串行下发。
        settingsError = nil
        let generation: Int
        if let coalesceKey {
            let next = (settingEpoch[coalesceKey] ?? 0) + 1
            settingEpoch[coalesceKey] = next
            generation = next
            // 去掉待发中的同 key；在飞项靠 generation / isCurrent 静默取消。
            let keepInFlight = settingTask != nil ? 1 : 0
            let head = Array(settingWrites.prefix(keepInFlight))
            let tail = settingWrites.dropFirst(keepInFlight).filter { write in
                if let zoomMode { return write.zoomMode != zoomMode }
                return write.coalesceKey != coalesceKey
            }
            settingWrites = head + Array(tail)
        } else {
            generation = 0
        }
        settingWrites.append(SettingWrite(
            id: UUID(), title: title, requiresIdle: requiresIdle, zoomMode: zoomMode,
            isZoomPreview: isZoomPreview, coalesceKey: coalesceKey, generation: generation,
            attempts: 0, apply: write))
        startSettingWrites()
    }

    private func canSend(_ write: SettingWrite) -> Bool {
        canWriteSettings && !restartingPreview && !processingCapture && (!write.requiresIdle || canEditShootingSettings)
    }

    /// 瞬时错误（忙/回读未稳）自动重试；硬失败只丢掉当前项，其它 key 继续。
    private func isRetryableSettingError(_ error: Error) -> Bool {
        switch error {
        case ControlError.cameraBusy, ControlError.readbackMismatch: true
        default: false
        }
    }

    private func isSuperseded(_ write: SettingWrite) -> Bool {
        guard let key = write.coalesceKey else { return false }
        return settingEpoch[key] != write.generation
    }

    private func startSettingWrites() {
        guard settingTask == nil, let target = session,
              let first = settingWrites.first, canSend(first) else { return }
        releaseGimbal()
        syncingSettings = true
        settingTask = Task { [weak self] in
            guard let self, session === target else { return }
            defer {
                if session === target {
                    settingTask = nil
                    syncingSettings = false
                    scheduleParameterRead()
                }
            }
            while let write = settingWrites.first, canSend(write) {
                let writeID = write.id
                let isCurrent = { [weak self] in
                    guard let self, self.settingWrites.contains(where: { $0.id == writeID }) else { return false }
                    return !self.isSuperseded(write)
                }
                do {
                    if isSuperseded(write) { throw CancellationError() }
                    try await write.apply(self, target, isCurrent)
                    try Task.checkCancellation()
                    try validate(target)
                    if settingWrites.first?.id == writeID { settingWrites.removeFirst() }
                } catch is CancellationError {
                    if settingWrites.first?.id == writeID { settingWrites.removeFirst() }
                    continue
                } catch {
                    guard !Task.isCancelled, session === target else { return }
                    if settingWrites.first?.id != writeID { continue }
                    if write.isZoomPreview || isSuperseded(write) {
                        AppLog.error(error, context: "console.settings.stale")
                        settingWrites.removeFirst()
                        continue
                    }
                    if isRetryableSettingError(error), write.attempts < ConsoleCommandPreferences.retryLimit {
                        settingWrites[0].attempts += 1
                        let delay = 300 * settingWrites[0].attempts
                        AppLog.error(error, context: "console.settings.retry")
                        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                        continue
                    }
                    AppLog.error(error, context: "console.settings.sync")
                    // 硬失败：提示后丢弃本地覆盖，改用机身当前配置。
                    abandonToCameraConfiguration(
                        message: "\(write.title) · \(error.localizedDescription)")
                }
            }
        }
    }

    func retrySettings() {
        guard canRetrySettings, settingsError != nil else { return }
        resyncSelectedSettings()
    }

    func useCameraSettings() {
        guard settingsError != nil, canUseCameraSettings else { return }
        abandonToCameraConfiguration(message: nil)
    }

    /// 丢掉本地改参意图，提示后以相机回读为准。
    private func abandonToCameraConfiguration(message: String?) {
        if let message {
            showNotice(message, isError: true)
        }
        clearSettingSelections()
        guard connected, let target = session else { return }
        let token = attempt
        Task { [weak self] in
            guard let self, attempt == token, session === target else { return }
            await backend.refreshShootingMode()
            guard attempt == token, session === target else { return }
            await backend.refreshSettings()
            guard attempt == token else { return }
            scheduleParameterRead()
        }
    }

    private func clearSettingSelections() {
        settingWrites.removeAll()
        settingEpoch.removeAll()
        settingsError = nil
        selectedMode = nil
        selectedParameters.removeAll()
        selectedGimbalMode = nil
    }

    /// 重连或重试只重放最新意图，避免先回写已被用户替换的旧值。
    private func resyncSelectedSettings() {
        settingWrites.removeAll()
        settingEpoch.removeAll()
        settingsError = nil
        let mode = selectedMode
        let gimbal = selectedGimbalMode
        let activeBank = mode.map { ConsoleCaptureMode($0) }
        let banks = ConsoleCaptureMode.allCases.filter { bank in activeBank != bank } + (activeBank.map { [$0] } ?? [])
        let selections = banks.compactMap { selectedParameters[$0] }.filter(\.hasValues)
        guard mode != nil || gimbal != nil || !selections.isEmpty else { return }

        if let mode {
            enqueueSetting(String(localized: "console.error.mode"), coalesceKey: "mode") { controller, target, isCurrent in
                try await controller.applyMode(mode, through: target)
                guard isCurrent() else { throw CancellationError() }
            }
        }
        for selection in selections {
            enqueueManualParameterWrites(selection, title: String(localized: "console.error.setting"))
        }
        if let mode, reportedMode != mode {
            enqueueSetting(String(localized: "console.error.mode"), coalesceKey: "mode.return") { controller, target, isCurrent in
                try await controller.applyMode(mode, through: target)
                guard isCurrent() else { throw CancellationError() }
            }
        }
        if let gimbal {
            enqueueSetting(String(localized: "console.error.setting"), coalesceKey: "gimbalMode") { controller, target, isCurrent in
                try await controller.writeGimbalMode(gimbal, through: target)
                guard isCurrent() else { throw CancellationError() }
            }
        }
    }

    private func commands(through target: LunaCameraSession) throws -> ConsoleCameraCommands {
        guard let cameraProfile else { throw ControlError.settingUnavailable }
        // 确认期只校验会话/模式；写前空闲由 checkIdle / requireCameraIdle 负责。
        return ConsoleCameraCommands(session: target, profile: cameraProfile, firmware: firmware,
                              checkIdle: { try await self.requireCameraIdle(target) },
                              lastReportedLivePhoto: { self.reportedParameters?.livePhoto }) { mode in
            try self.validate(target)
            guard self.reportedMode == mode, self.backend.functionMode == mode.functionMode.rawValue else {
                throw ControlError.modeChanged
            }
        }
    }

    func saveGimbalPosition() {
        guard canRememberGimbal, let cameraID = selectedCamera?.id else { return }
        perform(String(localized: "console.error.gimbalSave")) { target in
            let angles = try await self.gimbalCommands(through: target).readPosition(cameraID: cameraID)
            // 角度来自机身回读。翻转只在本会话确认过朝向时写入，避免重连后的默认值盖掉真实方向。
            guard let position = ConsoleGimbalPosition(cameraID: cameraID, yaw: angles.yaw, pitch: angles.pitch,
                                                       isFlipped: self.gimbalIsFlipped) else {
                throw ControlError.gimbalPosition
            }
            var next = self.memory
            next.lastPosition = position
            try self.saveMemory(next, notice: String(localized: "console.notice.gimbalSaved"))
        }
    }

    /// 转到这台相机记忆的角度。点击时先停掉正在进行的主体追踪，避免追踪把云台拉离记忆点。
    func restoreGimbalPosition() {
        guard !continuousShooting, canRememberGimbal, let saved = savedGimbalForCamera,
              let position = ConsoleGimbalPosition(cameraID: saved.cameraID, yaw: saved.yaw, pitch: saved.pitch,
                                                   isFlipped: saved.isFlipped) else { return }
        perform(String(localized: "console.error.gimbalRestore")) { target in
            // 追踪还占着云台时直接转角会被拒绝；先等取消完成，再归位。
            try await self.stopSubjectTracking(through: target)
            var commands = self.gimbalCommands(through: target)
            commands.atAxisLimit = { self.gimbalWasAtLimit }
            let outcome: Result<ConsoleGimbalRestoreResult, Error>
            do {
                outcome = .success(try await commands.restore(position, currentFlip: self.gimbalIsFlipped))
            } catch {
                outcome = .failure(error)
            }
            // 命令进行中收到的休眠通知不会触发自动唤醒，定位结束时补上，否则摇杆会一直禁用。
            if self.gimbalSleeping { try? await self.wakeGimbalSequence(target) }
            switch try outcome.get() {
            case .flipMismatch:
                self.showNotice(String(localized: "console.notice.gimbalFlipMismatch"))
            case .arrived:
                self.showNotice(String(localized: "console.notice.gimbalRestored"))
            case .axisLimit:
                // 相机没发限位通知、靠停转判断出来时，这里是唯一的提示。
                self.showNotice(String(localized: "console.notice.gimbalLimit"))
            }
        }
    }

    // MARK: - 相机相册的独占入口

    /// 浏览相册期间保留相机会话，控制台操作让位。
    func acquireAlbumControl(_ owner: UUID) throws -> AlbumLink {
        guard connected, selectedCamera != nil, let session else { throw CameraAlbumError.disconnected }
        guard albumControlOwner == owner || (canControl && !restartingPreview && !motion.isHeld) else {
            throw CameraAlbumError.busy
        }
        albumControlOwner = owner
        return AlbumLink(generation: attempt, host: backend.cameraHost, session: session)
    }

    func albumLinkIsCurrent(_ link: AlbumLink, owner: UUID) -> Bool {
        connected && albumControlOwner == owner && attempt == link.generation && session === link.session
    }

    func releaseAlbumControl(_ owner: UUID) {
        if albumControlOwner == owner { albumControlOwner = nil }
    }

    func notePhotoAddDenied() { photoAddDenied = true }
    func clearPhotoAddDenied() { photoAddDenied = false }

    /// 有追踪时先发取消，并等到相机关掉追踪后再返回。本地提前清掉会和后续转角抢命令。
    private func stopSubjectTracking(through target: LunaCameraSession) async throws {
        guard tracking.active else { return }
        _ = try await target.control(LunaProtocol.cancelTrackingRequest, timeout: .seconds(3))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while tracking.active {
            if clock.now >= deadline { throw ControlError.gimbalPosition }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func gimbalCommands(through target: LunaCameraSession) -> ConsoleGimbalCommands {
        ConsoleGimbalCommands(session: target, checkIdle: { try await self.requireCameraIdle(target) }) {
            try self.validate(target)
            guard !self.gimbalSleeping, self.capture?.isSettledIdle == true, !self.recording else {
                throw ControlError.gimbalPosition
            }
        }
    }

    private func requireCameraIdle(_ target: LunaCameraSession) async throws {
        try validate(target)
        let reply = try await target.control(LunaProtocol.captureStatusRequest, timeout: .seconds(3))
        try validate(target)
        let status = try LunaCaptureStatus(captureStatusResponse: reply)
        guard !reply.isEmpty, status.isSettledIdle, !recording else { throw ControlError.cameraBusy }
    }

    private func saveMemory(_ next: ConsoleMemory, notice text: String) throws {
        try memoryStore.save(next)
        memory = next
        showNotice(text)
    }

    private func adoptGimbalSleep(_ sleeping: Bool) {
        gimbalSleeping = sleeping
        if sleeping {
            releaseGimbal()
            scheduleAutoWake()
        }
    }

    /// 云台轴限位：仅在刚顶到时弹一次轻提示。
    private func presentGimbalLimitIfNeeded(_ status: LunaGimbalStatus) {
        let atLimit = status.isAtAxisLimit
        defer { gimbalWasAtLimit = atLimit }
        guard atLimit, !gimbalWasAtLimit else { return }
        showNotice(String(localized: "console.notice.gimbalLimit"))
    }

    // MARK: - 云台睡眠唤醒

    /// 官方做法：进入拍摄视图发 cmd 118 {1:5} 唤醒云台。休眠时控制台提供手动唤醒。
    func wakeGimbal() {
        guard supportsGimbal, connected, gimbalSleeping else { return }
        perform(String(localized: "console.error.wake")) { target in
            try await self.wakeGimbalSequence(target)
            self.showNotice(String(localized: "console.notice.gimbalAwake"))
        }
    }

    /// 拍摄视图内收到休眠通知时自动唤醒，相册操作期间不打断。
    private func scheduleAutoWake() {
        guard supportsGimbal, connected, albumControlOwner == nil, !busy, !processingCapture, autoWakeTask == nil else { return }
        let token = attempt
        autoWakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, attempt == token else { return }
            autoWakeTask = nil
            guard connected, gimbalSleeping, albumControlOwner == nil, !busy, !processingCapture else { return }
            perform(String(localized: "console.error.wake")) { target in
                try await self.wakeGimbalSequence(target)
            }
        }
    }

    private func wakeGimbalSequence(_ target: LunaCameraSession) async throws {
        for _ in 0..<6 {
            _ = try await target.control(
                LunaProtocol.setAccessCameraFileState(LunaProtocol.shootingViewAccessState), timeout: .seconds(2))
            try validate(target)
            try await Task.sleep(for: .milliseconds(200))
            await backend.refreshSettings()
            try validate(target)
            if !gimbalSleeping { return }
        }
        throw ControlError.gimbalAsleep
    }

    /// 记下连续拍摄开关和间隔，不弹出保存提示。
    private func rememberContinuousPreference() {
        var next = memory
        next.continuousPhoto = continuousPhoto
        next.continuousInterval = continuousInterval
        next.continuousGimbalReturn = continuousGimbalReturn
        guard next != memory else { return }
        do {
            try memoryStore.save(next)
            memory = next
        } catch {
            AppLog.error(error, context: "console.memory.continuous")
        }
    }

    private func adoptMode(_ mode: LunaShootingMode) {
        guard reportedMode != mode else { return }
        cancelParameterRead()
        subjectTracking.clear()
        reportedMode = mode
        restoreContinuousPreference(for: mode)
        if connected {
            pictureStalled = false
            previewDeadline = .now.addingTimeInterval(8)
            scheduleParameterRead()
        }
    }

    /// 相机读到照片模式，且上次开着连续拍摄时，回到 App 侧连续拍摄。已选其它模式时不改。
    private func restoreContinuousPreference(for mode: LunaShootingMode) {
        guard mode == .photo, memory.continuousPhoto, selectedMode == nil || selectedMode == .photo else { return }
        continuousPhoto = true
        if let interval = memory.continuousInterval {
            continuousInterval = interval
        }
    }

    func retryPhotoFormat() { scheduleParameterRead() }

    private func cancelParameterRead() {
        parameterReadTask?.cancel()
        parameterReadTask = nil
        parameterReadID = nil
        readingPhotoFormat = false
    }

    /// 等连接可以控制后单独读取照片格式。首个回复缺字段时继续重试。
    private func scheduleParameterRead() {
        guard connected, let cameraProfile, reportedMode == .photo, parameterReadTask == nil,
              (cameraProfile.rawPhoto && reportedParameters?.rawCapture == nil)
                || (!cameraProfile.livePhotoFormatIDs.isEmpty && reportedParameters?.livePhoto == nil) else { return }
        let id = UUID()
        parameterReadID = id
        readingPhotoFormat = true
        parameterReadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.parameterReadID == id {
                    self.parameterReadID = nil
                    self.parameterReadTask = nil
                    self.readingPhotoFormat = false
                }
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            var lastError: Error?
            while clock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard parameterReadID == id, connected, reportedMode == .photo else { return }
                let needsRAW = cameraProfile.rawPhoto && reportedParameters?.rawCapture == nil
                let needsLive = !cameraProfile.livePhotoFormatIDs.isEmpty && reportedParameters?.livePhoto == nil
                if !needsRAW && !needsLive { return }
                guard albumControlOwner == nil, !busy, !syncingSettings, !restartingPreview,
                      let target = session, target.admitsControl else { continue }
                let commands = ConsoleCameraCommands(session: target, profile: cameraProfile, checkIdle: {}) { mode in
                    try Task.checkCancellation()
                    try self.validate(target)
                    guard self.parameterReadID == id, self.reportedMode == mode,
                          self.backend.functionMode == mode.functionMode.rawValue else { throw CancellationError() }
                }
                do {
                    if needsRAW {
                        let fresh = try await commands.readPhotoFormat()
                        guard parameterReadID == id, reportedMode == .photo else { return }
                        if busy || syncingSettings || albumControlOwner != nil { continue }
                        acceptReported(fresh)
                    }
                    if needsLive, let enabled = try? await commands.readLivePhoto() {
                        guard parameterReadID == id, reportedMode == .photo else { return }
                        if !busy && !syncingSettings && albumControlOwner == nil && reportedParameters?.livePhoto == nil {
                            var changes = ConsoleParameters(mode: .photo)
                            changes.livePhoto = enabled
                            acceptReported(changes)
                        }
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    lastError = error
                }
            }
            if let lastError { AppLog.error(lastError, context: "console.photoFormat.read") }
        }
    }

    private func receive(_ event: CameraBackendEvent) {
        switch event {
        case .discovered(let camera):
            guard phase == .scanning else { return }
            if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
                if cameras[index] != camera { cameras[index] = camera }
            } else {
                cameras.append(camera)
            }
        case .phase(let phase):
            // Backend 在断线前会发 idle；已直播时忽略回退到连接过程态，避免已连接/连接中反复跳。
            if phase == .idle {
                break
            } else if self.phase == .streaming, !reconnecting, phase != .streaming {
                break
            } else {
                self.phase = phase
            }
            if phase == .streaming {
                privacy.stop()
                previewDeadline = .now.addingTimeInterval(8)
                // 首连/重连时 adoptMode 可能早于 streaming，这里再确保补一次完整回读。
                scheduleParameterRead()
            }
        case .information(let info):
            guard let selectedCamera, let profile = ConsoleCameraProfile.matching(info.model) else { return }
            if let cameraProfile, cameraProfile.id != profile.id {
                clearSettingSelections()
                reportedBanks.removeAll()
                professionalPresetBanks.removeAll()
            }
            cameraProfile = profile
            session?.configureLens(zoomDomain: profile.zoomDomain)
            session?.configureWhiteBalance(range: profile.whiteBalance.range)
            self.selectedCamera = MonitorCamera(id: selectedCamera.id, name: selectedCamera.name, model: profile.displayName,
                                                capabilities: selectedCamera.capabilities)
            firmware = info.firmware
        case .videoAccessUnit(let data, _):
            guard selectedCamera != nil, !pictureInPicture.isPaused else { return }
            if preview.decode(accessUnit: [UInt8](data)), !pictureReady {
                pictureReady = true
                pictureStalled = false
            }
        case .disconnected(let reason):
            // 重连期间的再次断开由重试循环处理，避免互相打断。
            if reconnecting { return }
            let wasStreaming = phase == .streaming
            let camera = selectedCamera
            teardown(preserveContinuous: wasStreaming && camera != nil)
            if wasStreaming, let camera {
                startReconnect(to: camera, reason: reason)
            } else {
                pictureInPicture.stop()
                selectedCamera = nil
                cameraProfile = nil
                showNotice(String(localized: "console.notice.disconnected \(reason)"), isError: true)
            }
        case .joinedWiFi, .note:
            break
        }
    }

    private func receive(_ notification: LunaNotification) {
        switch notification {
        case .liveStream(let format):
            let previous = streamFormat
            streamFormat = format
            streamPreviewSize = CGSize(width: CGFloat(format.width), height: CGFloat(format.height))
            // 图传横竖变化：相机已进入/退出竖拍，释放本地规格覆盖并回读录像规格。
            let isPortrait = format.height > format.width
            if let previous, (previous.height > previous.width) != isPortrait {
                releaseSelectedFormatOverride()
                preview.noteCompressedDiscontinuity()
                let token = attempt
                Task { [weak self] in
                    guard let self, attempt == token else { return }
                    await backend.refreshSettings()
                }
            }
        case .tracking(let state, _, _):
            subjectTracking.ingest(trackingState: state)
        case .livePhoto(let errorCode, let state):
            guard reportedMode == .photo, errorCode == 0, let enabled = ConsoleLivePhoto.enabled(mode: state) else { return }
            var changes = ConsoleParameters(mode: .photo)
            changes.livePhoto = enabled
            acceptReported(changes)
        case .gimbalStatus(let status):
            adoptGimbalSleep(status.sleep)
            presentGimbalLimitIfNeeded(status)
        case .screenBattery(let battery):
            if selectedCamera != nil { updateScreenBattery(battery) }
        case .unknown(code: 8309, body: let body):
            if selectedCamera != nil, let state = try? ProtoMessage(body).unsigned(1) {
                updateScreenConnection(state)
            }
        case .captureStopped(let errorCode, let uri):
            guard pendingPhoto != nil else { break }
            if let uri, !uri.isEmpty {
                photoCompletion = true
            } else if errorCode != 0 {
                photoCompletion = false
            }
        default:
            break
        }
    }

    private func updateScreenBattery(_ battery: LunaBattery) {
        guard !screenDisconnected else { return }
        screenBattery = battery.percent <= 100 ? Double(battery.percent) / 100 : nil
        screenCharging = battery.isCharging
    }

    private func updateScreenConnection(_ state: UInt64) {
        // 1–3 包含装上、拆卸中和仍联网的拆卸状态。4 才是屏幕断开。
        guard (1...4).contains(state) else { return }
        screenDisconnected = state == 4
        if screenDisconnected {
            screenBattery = nil
            screenCharging = false
        }
    }

    private func watchPreview(_ token: UUID) {
        previewWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, attempt == token, connected else { return }
                if busy || syncingSettings || processingCapture || previewCommandID != nil
                    || albumControlOwner != nil || pictureInPicture.isPaused {
                    previewDeadline = .now.addingTimeInterval(8)
                    previewStallBegan = nil
                    previewStableSince = nil
                    if pictureStalled { pictureStalled = false }
                    continue
                }
                guard !restartingPreview, Date.now >= previewDeadline else { continue }
                let now = Date.now
                let stalled = preview.lastSourceFrameAt.map { now.timeIntervalSince($0) > 4 } ?? true
                if stalled != pictureStalled { pictureStalled = stalled }
                if stalled { requestKeyframe(minimumInterval: 4) }
                updatePreviewQuality(stalled: stalled, at: now)
            }
        }
    }

    private func updatePreviewQuality(stalled: Bool, at now: Date) {
        if stalled {
            previewStableSince = nil
            if previewStallBegan == nil { previewStallBegan = now }
            guard let previewStallBegan, now.timeIntervalSince(previewStallBegan) >= 3 else { return }
            if reducedPreviewResolution != nil {
                // The alternate stream may be accepted without a picture on some firmware.
                restartPreview(resolution: nil, automatic: true)
            } else if now >= nextPreviewQualityTrial, let alternate = alternatePreviewResolution {
                restartPreview(resolution: alternate, automatic: true)
            }
        } else {
            previewStallBegan = nil
            if previewStableSince == nil { previewStableSince = now }
            if reducedPreviewResolution != nil && max(previewSize.width, previewSize.height) > 640 {
                // Some firmware acknowledges the preference but keeps its negotiated raster.
                reducedPreviewResolution = nil
            }
            if reducedPreviewResolution != nil, now >= nextPreviewQualityTrial,
               let previewStableSince, now.timeIntervalSince(previewStableSince) >= 30 {
                restartPreview(resolution: nil, automatic: true)
            }
        }
    }

    private var alternatePreviewResolution: UInt64? {
        let width = previewSize.width > 0 ? Double(previewSize.width) : Double(streamFormat?.width ?? 0)
        let height = previewSize.height > 0 ? Double(previewSize.height) : Double(streamFormat?.height ?? 0)
        guard min(width, height) > 0, max(width, height) > 640 else { return nil }
        let aspect = width / height
        let candidates: [UInt64] = [75, 76, 77, 78, 79]
        return candidates.compactMap { LunaVideoResolution(rawValue: $0) }.first {
            abs(aspect - Double($0.width) / Double($0.height)) < 0.03
        }?.rawValue
    }

    private func resumePictureInPictureFeed() {
        guard connected else { return }
        preview.noteCompressedDiscontinuity()
        previewDeadline = .now.addingTimeInterval(8)
        requestKeyframe(minimumInterval: 0)
    }

    private func requestKeyframe(minimumInterval: TimeInterval = 1) {
        guard connected, !busy, !syncingSettings, !processingCapture, albumControlOwner == nil,
              Date.now.timeIntervalSince(lastKeyframeRequest) >= minimumInterval else { return }
        lastKeyframeRequest = .now
        let token = attempt
        Task { [weak self] in
            guard let self, attempt == token else { return }
            await backend.requestKeyframe()
        }
    }

    private func applyMode(_ mode: LunaShootingMode, through target: LunaCameraSession) async throws {
        guard cameraProfile?.captureModes.contains(ConsoleCaptureMode(mode)) == true else {
            throw ControlError.settingUnavailable
        }
        if reportedMode == mode, backend.functionMode == mode.functionMode.rawValue { return }
        guard !recording else { throw ControlError.modeChanged }
        _ = try await target.control(mode.request())
        try validate(target)
        await backend.refreshShootingMode()
        try validate(target)
        for _ in 0..<10 {
            if reportedMode == mode, backend.functionMode == mode.functionMode.rawValue { break }
            try await Task.sleep(for: .milliseconds(200))
            try validate(target)
        }
        guard reportedMode == mode, backend.functionMode == mode.functionMode.rawValue else { throw ControlError.readbackMismatch }
        await backend.refreshSettings()
        try validate(target)
    }

    private func submit(_ intent: CameraCommandIntent, through target: LunaCameraSession,
                        waitForObservation: Bool = true) async throws {
        let command = CameraCommand(intent, preconditions: CommandPreconditions(target.current))
        let receipt = await target.submit(command)
        try validate(target)
        if !waitForObservation, receipt.stage == .awaitingObservation { return }
        let result: CommandReceipt
        if receipt.isFinished {
            result = receipt
        } else if let outcome = await target.outcome(of: command.operation) {
            result = outcome
        } else {
            throw ControlError.readbackMismatch
        }
        try validate(target)
        switch result.stage {
        case .confirmed, .accepted: return
        case .rejected(.outOfDomain), .rejected(.unsupported), .rejected(.unavailable):
            throw ControlError.settingUnavailable
        case .rejected(.cameraRefused): throw ControlError.cameraRefused
        default: throw ControlError.readbackMismatch
        }
    }

    private func validate(_ target: LunaCameraSession) throws {
        guard session === target, connected else { throw CancellationError() }
    }

    /// 相册删除占用命令提示，文案是「正在删除媒体」。
    func setDeletingMedia(_ active: Bool) {
        deletingMedia = active
    }

    /// `reportsError` 为假时只记日志，不弹失败提示，也不因此结束调用方的循环。
    private func perform(
        _ title: String, presentation: CommandPresentation = .processing, reportsError: Bool = true,
        action: @escaping @MainActor (LunaCameraSession) async throws -> Void
    ) {
        guard canControl, let target = session else { return }
        releaseGimbal()
        busy = true
        if presentation == .shutter { shutterCommand = true }
        dismissTransientFeedback()
        Task { [weak self] in
            guard let self, session === target else { return }
            defer {
                if session === target {
                    busy = false
                    shutterCommand = false
                    if queuedShutterPresses > 0 {
                        queuedShutterPresses -= 1
                        takePhoto()
                    }
                    if !busy { startSettingWrites() }
                }
            }
            do {
                try await action(target)
            } catch is CancellationError {
                return
            } catch {
                guard session === target else { return }
                if reportsError {
                    report(title, error: error)
                } else {
                    AppLog.error(error, context: "console.continuous")
                }
            }
        }
    }

    private func report(_ title: String, error: Error) {
        AppLog.error(error, context: "console.control")
        showNotice("\(title) · \(error.localizedDescription)", isError: true)
    }
}

extension LunaCaptureStatus {
    var isSettledIdle: Bool { isIdle && !isProcessingCapture }

    var isProcessingCapture: Bool {
        // 2 写卡、5 启动录制、13 全景合成。稳定录像仍应监测预览。
        submode == 2 || submode == 5 || submode == 13 || (!isIdle && !isRecording)
    }
}

enum ControlError: LocalizedError {
    case cameraBusy, captureFailed, readbackMismatch, settingUnavailable, cameraRefused, gimbalPosition, gimbalFlipState, modeChanged,
         gimbalAsleep

    var errorDescription: String? {
        switch self {
        case .cameraBusy: String(localized: "console.error.busy")
        case .captureFailed: String(localized: "console.error.capture")
        case .readbackMismatch: String(localized: "console.error.readback")
        case .settingUnavailable: String(localized: "console.error.unsupported")
        case .cameraRefused: String(localized: "console.error.refused")
        case .gimbalPosition: String(localized: "console.error.gimbalPosition")
        case .gimbalFlipState: String(localized: "console.error.gimbalFlipState")
        case .modeChanged: String(localized: "console.error.modeChanged")
        case .gimbalAsleep: String(localized: "console.error.gimbalAsleep")
        }
    }
}
