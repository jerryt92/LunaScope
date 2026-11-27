import AVFoundation
import LunaTransportApple
import LunaTransportProtocol
import OpenCineApple
import OpenCineCore
import SwiftUI
import UIKit

/// 拍摄页随窗口方向调整取景与操作区，全屏时沿用同一个相机画面。
struct ConsoleView: View {
    let camera: CameraController
    let openConnection: () -> Void
    @State private var fullScreen = false
    @State private var fullScreenControlsVisible = true
    @State private var displaysPreview = false
    @State private var showsPresets = false
    @State private var customIntervalDraft = ""
    @State private var customIntervalUnit = ConsoleShootInterval.Unit.seconds
    @State private var showsCustomInterval = false
    /// 云台位置菜单里点「记忆」后弹出确认。
    @State private var confirmsGimbalSave = false
    @ScaledMetric(relativeTo: .caption2) private var batteryRowHeight: CGFloat = 22
    /// 设备图标槽宽，保证机身 / 屏幕两行胶囊左缘对齐且等宽。
    @ScaledMetric(relativeTo: .caption2) private var batteryDeviceIconWidth: CGFloat = 12
    /// 电池档位图标槽宽；充电闪电比普通档更宽，固定槽避免两行胶囊错位。
    @ScaledMetric(relativeTo: .caption2) private var batteryGaugeIconWidth: CGFloat = 20
    /// 百分比最小宽度，按「100%」预留，避免 9% 与 100% 把胶囊拉成不同宽。
    @ScaledMetric(relativeTo: .caption2) private var batteryPercentMinWidth: CGFloat = 30
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geometry in
            let windowHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            let landscape = verticalSizeClass == .compact || geometry.size.width > windowHeight
            Group {
                if fullScreen {
                    // 含安全区整屏尺寸，横竖都铺满，不为底部退出栏留空。
                    let fullSize = CGSize(
                        width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                        height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                    )
                    fullScreenViewfinder(in: fullSize, safeArea: geometry.safeAreaInsets)
                        .ignoresSafeArea()
                } else {
                    shootingLayout(in: geometry.size, landscape: landscape)
                        .padding(Layout.spacing)
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
        .toolbarVisibility(fullScreen ? .hidden : .automatic, for: .tabBar)
        .statusBarHidden(fullScreen)
        .persistentSystemOverlays(fullScreen && !fullScreenControlsVisible ? .hidden : .automatic)
        .foregroundStyle(.white)
        .background((fullScreen ? Color.black : Palette.background).ignoresSafeArea())
        .tint(Palette.accent)
        .onChange(of: scenePhase) { _, next in
            if next != .active { camera.releaseGimbal() }
        }
        .onAppear { displaysPreview = true }
        .onDisappear {
            displaysPreview = false
            fullScreen = false
            camera.pictureInPicture.cancelPendingStart()
            camera.releaseGimbal()
        }
        .sheet(isPresented: $showsPresets) { ConsolePresetView(camera: camera) }
        .sheet(isPresented: $showsCustomInterval) {
            NavigationStack {
                Form {
                    TextField("console.interval.customPlaceholder", text: $customIntervalDraft)
                        .keyboardType(.decimalPad)
                    Picker("console.interval.unit", selection: $customIntervalUnit) {
                        Text("console.interval.unit.seconds").tag(ConsoleShootInterval.Unit.seconds)
                        Text("console.interval.unit.minutes").tag(ConsoleShootInterval.Unit.minutes)
                    }
                    .pickerStyle(.segmented)
                    Text("console.interval.customHint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("console.interval.customTitle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { showsCustomInterval = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") {
                            commitCustomInterval()
                            showsCustomInterval = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
            .tint(Palette.accent)
            .modifier(KeyboardDoneBar())
        }
        .alert("console.preview.pipFailed", isPresented: Binding(
            get: { camera.pictureInPicture.startError != nil },
            set: { if !$0 { camera.pictureInPicture.dismissError() } }
        )) {
            Button("common.close", role: .cancel) {}
        } message: {
            Text(camera.pictureInPicture.startError ?? "")
        }
        .alert("console.gimbal.saveConfirmTitle", isPresented: $confirmsGimbalSave) {
            Button("console.gimbal.saveConfirm", action: camera.saveGimbalPosition)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("console.gimbal.saveConfirmMessage")
        }
        .overlay {
            ConsoleNoticeOverlay(camera: camera)
        }
    }

    private func commitCustomInterval() {
        let amount = Double(customIntervalDraft.replacingOccurrences(of: ",", with: "."))
        guard let amount,
              let selection = ConsoleShootInterval.custom(amount: amount, unit: customIntervalUnit) else {
            return
        }
        camera.setContinuousInterval(ConsoleShootInterval(selection: selection))
    }

    private func shootingLayout(in size: CGSize, landscape: Bool) -> some View {
        let contentWidth = max(0, size.width - 2 * Layout.spacing)
        let contentHeight = max(0, size.height - 2 * Layout.spacing)
        let availableWidth = max(0, contentWidth - Layout.spacing)
        let preferredSidebarWidth = min(Layout.maximumSidebarWidth, max(Layout.controlsWidth, availableWidth * 0.36))
        let sidebarWidth = min(availableWidth * 0.48, preferredSidebarWidth)
        let previewColumnWidth = landscape ? availableWidth - sidebarWidth : contentWidth
        let showsZoom = camera.zoomLimits?.offersChoice == true
        // 横屏变焦在取景下方，4:3 外框只用扣掉变焦后的高度，避免整框被推出屏幕。
        let zoomBand = showsZoom ? ConsoleZoomControls.barHeight + Layout.spacing : 0
        let previewMaxHeight = landscape ? max(1, contentHeight - zoomBand) : previewColumnWidth * 3 / 4
        let layout = landscape ? AnyLayout(HStackLayout(alignment: .top, spacing: Layout.spacing))
            : AnyLayout(VStackLayout(spacing: Layout.spacing))
        // 外框就是这块区域里的最大 4:3，高度不再把上下空白算进去。
        let stage = AVMakeRect(
            aspectRatio: Layout.previewStageAspect,
            insideRect: CGRect(x: 0, y: 0, width: max(1, previewColumnWidth), height: max(1, previewMaxHeight)))
        return layout {
            if !landscape { portraitParameters(width: contentWidth, windowHeight: size.height) }
            // 横竖屏共用同一个取景视图，旋转时不重建图传宿主。
            VStack(spacing: Layout.spacing) {
                flexibleViewfinder(maxWidth: previewColumnWidth)
                    .frame(maxWidth: .infinity)
                    .frame(height: stage.height)
                if let limits = camera.zoomLimits, limits.offersChoice {
                    ConsoleZoomControls(camera: camera, limits: limits)
                }
            }
            .frame(width: landscape ? previewColumnWidth : nil,
                   height: landscape ? contentHeight : nil,
                   alignment: .top)
            if landscape {
                landscapeSidebar(width: sidebarWidth)
            } else {
                portraitDock(availableHeight: contentHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(width: contentWidth, height: contentHeight, alignment: .top)
    }

    /// 图传缓冲画幅（旋转前）；8234 先于解码器时优先用流尺寸。
    private var sourcePreviewAspect: CGSize {
        let stream = camera.streamPreviewSize
        if stream.width > 1, stream.height > 1 { return stream }
        let raster = camera.previewSize
        if raster.width > 1, raster.height > 1 { return raster }
        if let code = camera.parameters?.format, let profile = camera.cameraProfile {
            if camera.shootingMode?.isPhoto == true,
               let photo = profile.photoFormats.first(where: { $0.id == code }),
               photo.width > 0, photo.height > 0 {
                return CGSize(width: photo.width, height: photo.height)
            }
            if let video = profile.videoFormat(code), video.width > 0, video.height > 0 {
                return CGSize(width: CGFloat(video.width), height: CGFloat(video.height))
            }
        }
        return CGSize(width: 4, height: 3)
    }

    /// 按机身姿态矫正后的显示画幅（±90° 对调宽高）。
    private var displayPreviewAspect: CGSize {
        let source = sourcePreviewAspect
        if camera.previewRotationSwapsAspect {
            return CGSize(width: source.height, height: source.width)
        }
        return source
    }

    private enum Layout {
        static let controlsWidth: CGFloat = 360
        static let maximumSidebarWidth: CGFloat = 460
        static let compactSidebarWidth: CGFloat = 250
        static let maximumDockWidth: CGFloat = 560
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 12
        /// 参数面板和云台面板的内边距，算横屏是否并排时要扣掉。
        static let panelInset: CGFloat = 12
        static let joystick: CGFloat = 120
        static let buttonSize: CGFloat = 44
        /// 云台回中、翻转、模式和位置按钮。
        static let gimbalButton: CGFloat = 56
        /// 拍照键比开始键更宽，两者并排且不压到摇杆。
        static let shutterWidth: CGFloat = 108
        static let shutterHeight: CGFloat = 76
        static let continuousWidth: CGFloat = 72
        /// 取景右上角全屏 / 画中画按钮，略小于其他操作钮。
        static let previewControlSize: CGFloat = 32
        static let minimumExpandedHeight: CGFloat = 300
        static let shortWindow: CGFloat = 570
        /// 预览外框固定 4:3；4:3 图传铺满，其它画幅在框内 letterbox / pillarbox。
        static let previewStageAspect = CGSize(width: 4, height: 3)
    }

    private func landscapeSidebar(width: CGFloat) -> some View {
        let compact = landscapeDockIsCompact(width: width)
        return ViewThatFits(in: .vertical) {
            VStack(spacing: Layout.spacing) {
                parametersPanel(width: width, columns: 3)
                Spacer(minLength: 0)
                shootingDock(width: width, compact: compact)
            }
            ScrollView(.vertical) {
                VStack(spacing: Layout.spacing) {
                    parametersPanel(width: width, columns: 3)
                    shootingDock(width: width, compact: compact)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityIdentifier("console.landscape.controls")
    }

    @ViewBuilder
    private func portraitParameters(width: CGFloat, windowHeight: CGFloat) -> some View {
        let panel = parametersPanel(width: width)
        if typeSize.isAccessibilitySize || windowHeight < Layout.minimumExpandedHeight {
            ScrollView { panel }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: windowHeight * 0.42)
        } else {
            panel.fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func portraitDock(availableHeight: CGFloat) -> some View {
        if typeSize.isAccessibilitySize || availableHeight < Layout.shortWindow {
            ScrollView { shootingDock() }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: Layout.maximumDockWidth, maxHeight: availableHeight * 0.42)
        } else {
            shootingDock()
                .frame(maxWidth: Layout.maximumDockWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 取景右上角：画中画 + 全屏/收起。
    @ViewBuilder
    private var previewChromeButtons: some View {
        HStack(spacing: 4) {
            if camera.pictureInPicture.isSupported { pictureInPictureButton }
            previewSizeButton
        }
    }

    private var previewSizeButton: some View {
        Button {
            camera.releaseGimbal()
            if fullScreen { camera.pictureInPicture.cancelPendingStart() }
            fullScreenControlsVisible = true
            fullScreen.toggle()
        } label: {
            Label(fullScreen ? LocalizedStringKey("console.preview.exitFullscreen") : "console.preview.fullscreen",
                  systemImage: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: Layout.previewControlSize, height: Layout.previewControlSize)
                .background(.black.opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(fullScreen ? "console.preview.exitFullscreen" : "console.preview.fullscreen")
    }

    private func fullScreenViewfinder(in size: CGSize, safeArea: EdgeInsets) -> some View {
        let bounds = CGRect(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height))
        // 图传落在安全区内；黑底仍铺满全屏。
        let safeBounds = bounds.inset(by: UIEdgeInsets(
            top: safeArea.top, left: safeArea.leading,
            bottom: safeArea.bottom, right: safeArea.trailing))
        let picture = AVMakeRect(aspectRatio: displayPreviewAspect, insideRect: safeBounds)
        let toggleTitle: LocalizedStringKey = fullScreenControlsVisible
            ? "console.preview.hideFullscreenControls" : "console.preview.showFullscreenControls"
        return ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            ZStack {
                rotatedPreviewContent(in: CGSize(width: picture.width, height: picture.height)) {
                    PreviewSurface(layer: camera.preview.displayLayer, pictureInPicture: camera.pictureInPicture)
                        .accessibilityHidden(true)
                }
                if camera.pictureInPicture.isActive { Color.black }
                Button {
                    fullScreenControlsVisible.toggle()
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(toggleTitle))
                .accessibilityIdentifier("console.preview.toggleFullscreenControls")
            }
            .frame(width: picture.width, height: picture.height)
            .position(x: picture.midX, y: picture.midY)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topTrailing) {
            if fullScreenControlsVisible {
                previewChromeButtons
                    .padding(.top, safeArea.top + Layout.padding)
                    .padding(.trailing, safeArea.trailing + Layout.padding)
            }
        }
        .ignoresSafeArea()
    }

    /// 预览面板：在分到的区域内取最大 4:3，外框比例不随剩余高度拉伸；画面按当前画幅在黑底上 letterbox / pillarbox。
    private func flexibleViewfinder(maxWidth: CGFloat) -> some View {
        GeometryReader { proxy in
            let slot = CGRect(x: 0, y: 0, width: min(maxWidth, proxy.size.width), height: max(1, proxy.size.height))
            let stage = AVMakeRect(aspectRatio: Layout.previewStageAspect, insideRect: slot)
            viewfinderStage(size: CGSize(width: stage.width, height: stage.height))
                .frame(width: stage.width, height: stage.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .transaction { $0.animation = nil }
        }
    }

    /// 固定 4:3 舞台 + 画幅适配；4:3 铺满，其它画幅留黑边。
    private func viewfinderStage(size: CGSize) -> some View {
        let stage = CGRect(origin: .zero, size: size)
        let picture = AVMakeRect(aspectRatio: displayPreviewAspect, insideRect: stage)
        return ZStack(alignment: .topLeading) {
            Color.black
            viewfinderPicture(in: CGSize(width: picture.width, height: picture.height))
                .frame(width: picture.width, height: picture.height)
                .position(x: picture.midX, y: picture.midY)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topTrailing) {
            previewChromeButtons.padding(Layout.padding)
        }
        .overlay(alignment: .topLeading) {
            if !camera.pictureInPicture.isActive && (camera.connected || camera.pictureReady) {
                let trailingReserve = Layout.previewControlSize
                    + (camera.pictureInPicture.isSupported ? Layout.previewControlSize + 4 : 0)
                    + Layout.padding
                previewStatus
                    .padding(.trailing, trailingReserve)
                    .padding(Layout.padding)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if showsLivePhotoButton {
                livePhotoButton
                    .padding(.leading, Layout.padding)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !camera.pictureInPicture.isActive, camera.connected, camera.shootingMode != nil, camera.shootingMode != .pano {
                manualExposureReadout
                    .padding([.leading, .bottom], Layout.padding)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let prompt = camera.commandPrompt, !camera.pictureInPicture.isActive {
                Label {
                    Text(prompt.title)
                } icon: {
                    Image(systemName: "hourglass")
                }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding([.trailing, .bottom], Layout.padding)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(prompt == .processing ? "console.capture.working" : "album.deleting.media")
            }
        }
        .clipped()
    }

    /// 仅画面区域：图传按姿态逆时针矫正，手势跟缓冲坐标；等待文案不旋转。
    private func viewfinderPicture(in size: CGSize) -> some View {
        ZStack {
            Palette.preview
            if displaysPreview || camera.pictureInPicture.isActive {
                rotatedPreviewContent(in: size) {
                    PreviewSurface(layer: camera.preview.displayLayer, pictureInPicture: camera.pictureInPicture)
                        .accessibilityHidden(true)
                }
            }

            if camera.pictureInPicture.isActive {
                Color.black
                Image(systemName: "pip.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white)
                    .accessibilityLabel("console.preview.pipActive")
                    .accessibilityIdentifier("console.preview.pipActive")
            } else if !camera.pictureReady || previewInterrupted {
                Color.black.opacity(camera.pictureReady ? 0.6 : 0)
                if !previewWorking {
                    VStack(spacing: 8) {
                        Image(systemName: previewInterrupted ? "video.slash" : "viewfinder")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(Palette.secondary)
                            .accessibilityHidden(true)
                        Text(previewInterrupted ? LocalizedStringKey("console.preview.interrupted") : camera.connected ? LocalizedStringKey("console.preview.waiting") : LocalizedStringKey("console.preview.title"))
                            .font(.subheadline.weight(.medium))
                        if previewInterrupted || camera.restartingPreview {
                            Button("console.preview.restart", action: camera.restartPreview)
                                .buttonStyle(.bordered)
                                .disabled(camera.restartingPreview || camera.recording)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(Layout.padding)
                }
            } else {
                rotatedPreviewContent(in: size) {
                    ConsolePreviewGestures(camera: camera)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// 按姿态把图传/手势旋到显示画幅（竖立 0°，左右侧倾 ±90°）。
    private func rotatedPreviewContent<Content: View>(
        in displaySize: CGSize,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let degrees = camera.previewRotationDegrees
        let bufferSize = camera.previewRotationSwapsAspect
            ? CGSize(width: displaySize.height, height: displaySize.width)
            : displaySize
        return content()
            .frame(width: bufferSize.width, height: bufferSize.height)
            .rotationEffect(.degrees(Double(degrees)))
            .frame(width: displaySize.width, height: displaySize.height)
    }

    @ViewBuilder private var manualExposureReadout: some View {
        let values = ConsoleManualExposure(camera: camera).values
        if !values.isEmpty {
            let readout = Text(values.joined(separator: "  ·  "))
            ViewThatFits(in: .horizontal) {
                readout.fixedSize()
                Text(values.joined(separator: "\n"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            .layoutPriority(1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("console.preview.manualExposure")
        }
    }

    private var previewWorking: Bool {
        camera.connected && (camera.busy || camera.showsParameterWorkingIndicator || camera.processingCapture)
    }
    private var previewInterrupted: Bool { camera.pictureStalled && !previewWorking }

    private var previewStatus: some View {
        // fixedSize + 子行 maxWidth 无限：以较宽一行定宽，两颗胶囊等宽等高对齐。
        VStack(alignment: .leading, spacing: 4) {
            batteryStatus(
                device: "camera.fill",
                level: camera.snapshot?.power.battery.value,
                charging: camera.snapshot?.power.externalPower.value == true,
                identifier: "console.battery.body")
            if camera.cameraProfile?.detachableScreen != false {
                batteryStatus(
                    device: "ipad.landscape",
                    level: camera.screenBattery,
                    charging: camera.screenCharging,
                    identifier: "console.battery.screen")
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 机身 / 屏幕电量：设备图标 + 电量档位 + 百分比；充电时用电池内闪电，不另起图标。
    /// SF Symbols 只有 `battery.100percent.bolt`，低电量档不能拼 `.bolt`；充电态用该符号，具体电量看百分比。
    private func batteryStatus(device: String, level: Double?, charging: Bool, identifier: String) -> some View {
        let value = level.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        let icon = Self.batteryIcon(level: level, charging: charging)
        let showsGauge = level != nil || charging
        let accessibility = {
            let percent = value ?? String(localized: "permissions.status.unknown")
            return charging ? String(localized: "console.battery.charging \(percent)") : percent
        }()
        return HStack(spacing: 4) {
            Image(systemName: device)
                .frame(width: batteryDeviceIconWidth, alignment: .center)
            Image(systemName: icon)
                .opacity(showsGauge ? 1 : 0)
                .frame(width: batteryGaugeIconWidth, alignment: .center)
            Text(value ?? "—")
                .lineLimit(1)
                .frame(minWidth: batteryPercentMinWidth, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: batteryRowHeight)
        .background(.black.opacity(0.65), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibility)
        .accessibilityIdentifier(identifier)
    }

    private static func batteryIcon(level: Double?, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case let level? where level > 0.75: return "battery.100percent"
        case let level? where level > 0.5: return "battery.75percent"
        case let level? where level > 0.25: return "battery.50percent"
        case let level? where level > 0: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func shootingDock(width: CGFloat? = nil, compact: Bool = false) -> some View {
        let showsGimbal = camera.cameraProfile?.gimbalChoices.isEmpty != true
        return VStack(alignment: .leading, spacing: Layout.spacing) {
            Group {
                if compact {
                    VStack(alignment: .trailing, spacing: Layout.spacing) {
                        if showsGimbal { joystick.frame(maxWidth: .infinity, alignment: .leading) }
                        shutterCluster
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    HStack(alignment: .center, spacing: Layout.spacing) {
                        if showsGimbal { joystick }
                        Spacer(minLength: Layout.spacing)
                        shutterCluster
                    }
                }
            }
            if showsGimbal {
                gimbalActions(compact: compact)
            }
            if !camera.connected {
                Button("feature.connection.title", systemImage: "antenna.radiowaves.left.and.right", action: openConnection)
                    .accessibilityIdentifier("console.connection.open")
            }
            if camera.photoAddDenied {
                Button("permissions.action.settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
        .panelStyle()
        .frame(maxWidth: width, alignment: .leading)
    }

    private var joystick: some View {
        GimbalPad(move: camera.moveGimbal, release: camera.releaseGimbal, nudge: camera.nudgeGimbal)
            .frame(width: Layout.joystick, height: Layout.joystick)
            .disabled(!camera.canControl || camera.gimbalSleeping)
            .opacity(camera.canControl && !camera.gimbalSleeping ? 1 : 0.5)
            .accessibilityIdentifier("console.gimbal.pad")
    }

    /// 连续拍摄的开始/停止键，固定在拍照键左侧。
    private var shutterCluster: some View {
        HStack(spacing: Layout.spacing) {
            if camera.continuousPhoto {
                continuousStartButton
            }
            shutterButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var continuousStartButton: some View {
        let running = camera.continuousShooting
        return Button {
            camera.toggleContinuousCapture()
        } label: {
            Label(running ? "console.capture.continuousStop" : "console.capture.continuousStart",
                  systemImage: running ? "stop.fill" : "timer")
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: Layout.continuousWidth, height: Layout.shutterHeight)
        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("console.capture.continuous")
    }

    private var shutterButton: some View {
        let photo = !camera.recording && (camera.shootingMode?.isPhoto ?? true)
        let title: LocalizedStringKey = photo ? "console.capture.photo"
            : camera.recording ? "console.capture.stop" : "console.capture.record"
        let icon = photo ? "camera.fill" : camera.recording ? "stop.fill" : "record.circle"
        // 拍照进行中用转圈替换相机图标；处理中仍可继续按。
        let spinning = camera.showsShutterActivity
        return Button {
            if photo { camera.takePhoto() }
            else { camera.toggleRecording() }
        } label: {
            Group {
                if spinning {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                        .accessibilityLabel("console.capture.photo")
                } else {
                    Label(title, systemImage: icon)
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(photo ? Palette.accent : (camera.recording ? .red : Palette.accent))
        .controlSize(.large)
        .disabled(spinning ? false : photo ? !camera.canTakePhoto : !camera.canSet(.recording) || !recordStateKnown)
        .accessibilityIdentifier("console.capture.shutter")
        .frame(width: Layout.shutterWidth, height: Layout.shutterHeight)
    }

    /// 顶部配置栏槽位。手动面板里已有的项不再排到外面；全景没有手动面板，对焦留在这里。
    private enum ParameterSlot: Hashable {
        case mode, interval, format(ConsoleFormatControl), exposure, focus, presets
    }

    private var parameterSlots: [ParameterSlot] {
        var slots: [ParameterSlot] = [.mode]
        if camera.continuousPhoto { slots.append(.interval) }
        slots.append(contentsOf: ConsoleFormatControl.available(for: camera).map(ParameterSlot.format))
        if camera.shootingMode == .pano {
            if !camera.focusChoices.isEmpty { slots.append(.focus) }
        } else {
            slots.append(.exposure)
        }
        slots.append(.presets)
        return slots
    }

    /// 横屏侧栏放不下摇杆和快门并排时改为上下排列，避免面板被侧栏裁掉左右边框。
    private func landscapeDockIsCompact(width: CGFloat) -> Bool {
        if width < Layout.compactSidebarWidth || typeSize.isAccessibilitySize { return true }
        let showsGimbal = camera.cameraProfile?.gimbalChoices.isEmpty != true
        var row = Layout.shutterWidth
        if camera.continuousPhoto { row += Layout.spacing + Layout.continuousWidth }
        if showsGimbal { row += Layout.spacing + Layout.joystick }
        return row + Layout.panelInset * 2 > width
    }

    /// 按最小宽度换行，同行等宽。横屏可指定每行列数，把项目收窄后排进侧栏。
    private func parametersPanel(width: CGFloat, columns: Int? = nil) -> some View {
        let slots = parameterSlots
        let inset: CGFloat = 4
        let contentWidth = max(0, width - inset * 2)
        let minWidth = typeSize.isAccessibilitySize ? ConsoleMenuLabel.minItemWidth * 1.35
            : ConsoleMenuLabel.minItemWidth
        let spacing = ConsoleMenuLabel.spacing
        let fitted = max(1, Int(floor((contentWidth + spacing) / (minWidth + spacing))))
        let perRow = max(1, columns ?? fitted)
        let rows = parameterRows(slots, perRow: perRow)
        return VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { slot in
                        parameterCell(slot)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .panelStyle(inset: 4)
    }

    /// 按每行容量切行。末行项数更少时在该行内均分变宽。
    private func parameterRows(_ slots: [ParameterSlot], perRow: Int) -> [[ParameterSlot]] {
        guard !slots.isEmpty else { return [] }
        var rows: [[ParameterSlot]] = []
        var index = 0
        while index < slots.count {
            let end = min(index + perRow, slots.count)
            rows.append(Array(slots[index..<end]))
            index = end
        }
        return rows
    }

    @ViewBuilder
    private func parameterCell(_ slot: ParameterSlot) -> some View {
        switch slot {
        case .mode: shootingModeMenu
        case .interval: continuousIntervalMenu
        case .format(let control): ConsoleFormatControls(camera: camera, control: control)
        case .exposure: ConsoleExposureControls(camera: camera) { shutterButton }
        case .focus: focusMenu
        case .presets: presetsEntry
        }
    }

    /// 参数记忆入口，样式与顶部配置项一致。
    private var presetsEntry: some View {
        let count = camera.memory.presets.count
        return Button { showsPresets = true } label: {
            ConsoleMenuLabel(
                title: "console.presets.title",
                value: count > 0
                    ? String(format: String(localized: "console.presets.countFormat"), locale: .current, Int64(count))
                    : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("console.presets.open")
    }

    private var shootingModeMenu: some View {
        Menu {
            Section("console.mode.videoFamily") {
                ForEach((camera.cameraProfile?.captureModes ?? []).filter { !$0.native.isPhoto }) { mode in
                    shootingModeChoice(mode.native)
                }
            }
            Section("console.mode.photoFamily") {
                ForEach((camera.cameraProfile?.captureModes ?? []).filter { $0.native.isPhoto }) { mode in
                    if mode == .photo {
                        Button {
                            camera.setMode(.photo)
                        } label: {
                            if camera.shootingMode == .photo, !camera.continuousPhoto {
                                Label(mode.native.label, systemImage: "checkmark")
                            } else {
                                Text(mode.native.label)
                            }
                        }
                        Button {
                            camera.setContinuousPhotoMode()
                        } label: {
                            if camera.continuousPhoto {
                                Label("console.mode.continuousPhoto", systemImage: "checkmark")
                            } else {
                                Text("console.mode.continuousPhoto")
                            }
                        }
                    } else {
                        shootingModeChoice(mode.native)
                    }
                }
            }
        } label: {
            ConsoleMenuLabel(title: "console.mode.switch", value: camera.modeLabel)
        }
        .consoleMenu(camera.canEditShootingSettings && !camera.continuousShooting)
        .accessibilityIdentifier("console.mode.menu")
    }

    private var continuousIntervalMenu: some View {
        Menu {
            ForEach(ConsoleShootInterval.presets, id: \.self) { seconds in
                Button {
                    camera.setContinuousInterval(ConsoleShootInterval(selection: .preset(seconds)))
                } label: {
                    let selected = !camera.continuousInterval.isCustom
                        && abs(camera.continuousInterval.seconds - seconds) < 0.001
                    let title = ConsoleShootInterval(selection: .preset(seconds)).summaryLabel
                    if selected {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
            Button {
                customIntervalDraft = ""
                customIntervalUnit = .seconds
                showsCustomInterval = true
            } label: {
                if camera.continuousInterval.isCustom {
                    Label("console.interval.custom", systemImage: "checkmark")
                } else {
                    Text("console.interval.custom")
                }
            }
        } label: {
            ConsoleMenuLabel(title: "console.interval.title",
                             value: camera.continuousInterval.summaryLabel)
        }
        .consoleMenu(camera.canEditShootingSettings || camera.continuousShooting)
        .accessibilityIdentifier("console.interval.menu")
    }

    private func shootingModeChoice(_ mode: LunaShootingMode) -> some View {
        Button {
            camera.setMode(mode)
        } label: {
            if camera.shootingMode == mode, !camera.continuousPhoto {
                Label(mode.label, systemImage: "checkmark")
            } else {
                Text(mode.label)
            }
        }
    }

    private var pictureInPictureButton: some View {
        let pip = camera.pictureInPicture
        let title: LocalizedStringKey = pip.isActive ? "console.preview.pipStop" : "console.preview.pipStart"
        return Button(action: pip.toggle) {
            Group {
                if pip.isTransitioning {
                    ProgressView().controlSize(.mini)
                } else {
                    Label(title, systemImage: pip.isActive ? "pip.exit" : "pip.enter")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(width: Layout.previewControlSize, height: Layout.previewControlSize)
            .background(.black.opacity(0.7), in: Circle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pip.isTransitioning || (!pip.isActive && (!camera.connected || !camera.pictureReady)))
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("console.preview.pip")
    }

    private var showsLivePhotoButton: Bool {
        !camera.pictureInPicture.isActive && camera.pictureReady && !previewInterrupted
            && camera.shootingMode == .photo
            && !(camera.cameraProfile?.livePhotoFormatIDs.isEmpty ?? true)
    }

    private var livePhotoButton: some View {
        let current = camera.parameters?.livePhoto
        // 连拍进行中总线被占用，仅禁止切换；连拍模式下仍显示按钮。
        let canToggle = camera.canEditShootingSettings && !camera.continuousShooting
        return Button {
            camera.setLivePhoto(current != true)
        } label: {
            Image(systemName: current == true ? "livephoto" : "livephoto.slash")
                .font(.title3)
                .foregroundStyle(current == true ? Palette.accent : .white)
                .frame(width: Layout.buttonSize, height: Layout.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canToggle)
        .opacity(canToggle ? 1 : 0.45)
        .accessibilityLabel("console.livePhoto.title")
        .accessibilityValue(current.map {
            $0 ? String(localized: "console.livePhoto.on") : String(localized: "console.livePhoto.off")
        } ?? String(localized: "permissions.status.unknown"))
        .accessibilityIdentifier("console.format.livePhoto")
    }

    private var recordStateKnown: Bool {
        let state = camera.snapshot?.recording.value
        return state == .recording || state == .idle
    }

    /// 回中 / 翻转保持正方形；模式和位置占满剩余宽度。窄栏时文字按钮另起一行。
    private func gimbalActions(compact: Bool) -> some View {
        let stacked = compact || typeSize.isAccessibilitySize
        let aim = HStack(spacing: 6) {
            gimbalAimButton("console.gimbal.center", icon: "scope", recenter: true)
            gimbalAimButton("console.gimbal.flip", icon: "arrow.left.arrow.right", recenter: false)
        }
        let menus = HStack(spacing: 6) {
            gimbalModeMenu
            gimbalPositionMenu
        }
        .frame(maxWidth: .infinity)
        return VStack(alignment: .leading, spacing: 6) {
            if camera.connected && camera.gimbalSleeping { wakeButton }
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    aim
                    menus
                }
            } else {
                HStack(spacing: 6) {
                    aim
                    menus
                }
            }
        }
    }

    /// 云台位置二级菜单。记忆会先确认，避免直接覆盖已保存的角度。
    private var gimbalPositionMenu: some View {
        let enabled = camera.canRememberGimbal
        return Menu {
            Button {
                // 等菜单收起再弹确认，否则本次点击会被菜单关闭吃掉。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    confirmsGimbalSave = true
                }
            } label: {
                Label("console.gimbal.remember", systemImage: "bookmark")
            }
            .accessibilityIdentifier("console.gimbal.savePosition")
            Button(action: camera.restoreGimbalPosition) {
                Label("console.gimbal.restore", systemImage: "location")
            }
            .disabled(camera.savedGimbalForCamera == nil)
            .accessibilityIdentifier("console.gimbal.restorePosition")
        } label: {
            Label("console.gimbal.position", systemImage: "mappin.and.ellipse")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: Layout.gimbalButton)
                .foregroundStyle(enabled ? Palette.accent : Palette.secondary)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(!enabled)
        .accessibilityIdentifier("console.gimbal.position")
    }

    /// 云台模式入口。按钮只写标题，当前模式在菜单里用勾表示。
    private var gimbalModeMenu: some View {
        var seen = Set<LunaGimbalMode>()
        let modes = camera.cameraProfile?.gimbalChoices
            ?? ConsoleCameraProfile.bundled.flatMap(\.gimbalChoices).filter { seen.insert($0).inserted }
        let current = camera.gimbalMode
        let enabled = camera.canEditGimbalMode
        return Menu {
            ForEach(modes, id: \.self) { mode in
                Button {
                    camera.setGimbalMode(mode)
                } label: {
                    if mode == current {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
                .accessibilityIdentifier("console.gimbal.mode.\(mode.rawValue)")
            }
        } label: {
            Label("console.gimbal.mode", systemImage: "gyroscope")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: Layout.gimbalButton)
            .foregroundStyle(enabled ? Palette.accent : Palette.secondary)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel("console.gimbal.mode")
        .accessibilityValue(Text(current?.label ?? "—"))
        .accessibilityIdentifier("console.gimbal.mode.menu")
    }

    private func gimbalAimButton(_ title: LocalizedStringKey, icon: String, recenter: Bool) -> some View {
        Button { camera.aimGimbal(recenter: recenter) } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: Layout.gimbalButton, height: Layout.gimbalButton)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!camera.canControl || camera.gimbalSleeping)
        .opacity(camera.canControl && !camera.gimbalSleeping ? 1 : 0.5)
        .accessibilityIdentifier(recenter ? "console.gimbal.center" : "console.gimbal.flip")
    }

    private var wakeButton: some View {
        Button("console.gimbal.wake", systemImage: "sun.max", action: camera.wakeGimbal)
            .buttonStyle(.bordered)
            .disabled(camera.busy || camera.processingCapture || camera.albumControlOwner != nil)
            .accessibilityIdentifier("console.gimbal.wake")
    }

    private var focusMenu: some View {
        let current = camera.currentFocusChoice
        let choices = camera.focusChoices
        return Menu {
            ForEach(choices, id: \.rawValue) { focus in
                Button { camera.setNativeFocus(focus) } label: {
                    if current == focus { Label(focus.label, systemImage: "checkmark") }
                    else { Text(focus.label) }
                }
            }
        } label: {
            ConsoleMenuLabel(title: "console.settings.focus", value: current?.label)
        }
        .consoleMenu(camera.canEditShootingSettings && camera.parameters?.autofocus != nil && !choices.isEmpty)
        .accessibilityIdentifier("console.settings.focus")
    }

}

/// 在控制台和校准页间复用实时视频层。
struct PreviewSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    var pictureInPicture: ConsolePictureInPicture? = nil

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.isUserInteractionEnabled = false
        view.claim(layer)
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        view.pictureInPicture = pictureInPicture
        view.attach(layer)
        view.preparePictureInPicture()
    }

    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.retire()
    }

    /// 图传层的宿主视图。同一图层只归最新创建的宿主；退场中的旧宿主不能把它抢回去。
    final class Surface: UIView {
        /// 每个图传层当前的宿主。
        private static let owners = NSMapTable<AVSampleBufferDisplayLayer, Surface>.weakToWeakObjects()
        private weak var displayLayer: AVSampleBufferDisplayLayer?
        weak var pictureInPicture: ConsolePictureInPicture?

        /// 新宿主直接接管图层。
        func claim(_ display: AVSampleBufferDisplayLayer) {
            Self.owners.setObject(self, forKey: display)
            displayLayer = display
            mount()
        }

        /// 只在没人持有、或原宿主已离开窗口时接管，避免和新宿主互抢。
        func attach(_ display: AVSampleBufferDisplayLayer) {
            displayLayer = display
            let owner = Self.owners.object(forKey: display)
            guard owner === self || owner == nil || owner?.window == nil else { return }
            Self.owners.setObject(self, forKey: display)
            mount()
        }

        /// 宿主销毁时交出所有权，留下的宿主在下次布局时接回。
        func retire() {
            guard let displayLayer, Self.owners.object(forKey: displayLayer) === self else { return }
            Self.owners.removeObject(forKey: displayLayer)
        }

        private func mount() {
            guard let displayLayer else { return }
            displayLayer.videoGravity = .resizeAspect
            if displayLayer.superlayer !== layer {
                layer.addSublayer(displayLayer)
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let displayLayer, displayLayer.superlayer !== layer, window != nil {
                attach(displayLayer)
            }
            applyDisplayFrame()
        }

        /// 把图传层贴到当前视图尺寸，并去掉旋转事务附带的尺寸动画。
        private func applyDisplayFrame() {
            guard let displayLayer, displayLayer.superlayer === layer else { return }
            guard bounds.width > 1, bounds.height > 1 else { return }
            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                displayLayer.removeAnimation(forKey: "bounds")
                displayLayer.removeAnimation(forKey: "position")
                displayLayer.frame = bounds
                CATransaction.commit()
            }
            preparePictureInPicture()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let displayLayer { attach(displayLayer) }
            preparePictureInPicture()
        }

        func preparePictureInPicture() {
            guard window != nil, !bounds.isEmpty, displayLayer?.superlayer === layer else { return }
            pictureInPicture?.sourceDidAttach()
        }
    }
}

/// 使用持续拖动控制云台，松手或离开页面时停止。
struct GimbalPad: View {
    let move: (Double, Double) -> Void
    let release: () -> Void
    let nudge: (Double, Double) -> Void
    @GestureState private var tracking = false
    @State private var offset = CGSize.zero
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { geometry in
            let radius = geometry.size.width / 2
            let knob = geometry.size.width * 0.44
            ZStack {
                Circle().fill(Palette.field).strokeBorder(Palette.border)
                Image(systemName: "arrowtriangle.up.fill").offset(y: -radius * 0.72)
                Image(systemName: "arrowtriangle.down.fill").offset(y: radius * 0.72)
                Image(systemName: "arrowtriangle.left.fill").offset(x: -radius * 0.72)
                Image(systemName: "arrowtriangle.right.fill").offset(x: radius * 0.72)
                Circle()
                    .fill(tracking ? Palette.accent : Color(red: 0.24, green: 0.31, blue: 0.34))
                    .frame(width: knob, height: knob)
                    .overlay { Circle().strokeBorder(.white.opacity(0.16)) }
                    .offset(offset)
                    .allowsHitTesting(false)
            }
            .font(.system(size: max(12, geometry.size.width * 0.1), weight: .medium))
            .foregroundStyle(Palette.secondary)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($tracking) { _, value, _ in value = true }
                .onChanged { value in
                    guard enabled else { return }
                    let x = value.location.x - radius
                    let y = value.location.y - radius
                    let reach = radius * 0.58
                    let scale = max(reach, hypot(x, y))
                    offset = CGSize(width: x / scale * reach, height: y / scale * reach)
                    if hypot(x, y) < 5 { release() }
                    else { move(x / scale * 0.68, -y / scale * 0.68) }
                }
                .onEnded { _ in stop() })
            .onChange(of: tracking) { _, active in if !active { stop() } }
            .onChange(of: enabled) { _, active in if !active { stop() } }
            .onDisappear { stop() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("console.gimbal.joystick")
        .accessibilityHint("console.gimbal.joystickHint")
        .accessibilityAction(named: Text("console.gimbal.up")) { nudge(0, 0.5) }
        .accessibilityAction(named: Text("console.gimbal.down")) { nudge(0, -0.5) }
        .accessibilityAction(named: Text("console.gimbal.left")) { nudge(-0.5, 0) }
        .accessibilityAction(named: Text("console.gimbal.right")) { nudge(0.5, 0) }
    }

    private func stop() {
        offset = .zero
        release()
    }
}

private extension View {
    func panelStyle(inset: CGFloat = 12) -> some View {
        padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.border) }
    }
}

enum Palette {
    static let background = Color(red: 0.055, green: 0.071, blue: 0.078)
    static let preview = Color(red: 0.04, green: 0.052, blue: 0.06)
    static let panel = Color(red: 0.088, green: 0.106, blue: 0.115)
    static let field = Color(red: 0.135, green: 0.161, blue: 0.175)
    static let border = Color.white.opacity(0.09)
    static let accent = Color("AccentColor")
    static let secondary = Color(red: 0.67, green: 0.72, blue: 0.74)
    static let error = Color(red: 1, green: 0.59, blue: 0.52)
}

extension LunaShootingMode {
    var label: String {
        switch self {
        case .video: String(localized: "console.mode.video")
        case .timelapse: String(localized: "console.mode.timelapse")
        case .timeShift: String(localized: "console.mode.timeShift")
        case .slowMotion: String(localized: "console.mode.slowMotion")
        case .pureVideo: String(localized: "console.mode.pureVideo")
        case .photo: String(localized: "console.mode.photo")
        case .pano: String(localized: "console.mode.pano")
        }
    }
}

private extension LunaGimbalMode {
    var label: String {
        switch self {
        case .fpv: "FPV"
        case .rollLock: String(localized: "console.gimbal.rollLock")
        case .rollAndTiltLock: String(localized: "console.gimbal.rollTiltLock")
        case .fpvVertical: "FPV-V"
        case .lock: String(localized: "console.gimbal.lock")
        case .stabilizedVertical: String(localized: "console.gimbal.vertical")
        }
    }
}

extension LunaAFMode {
    var label: String {
        switch self {
        case .single: String(localized: "console.settings.singleAF")
        case .continuous: String(localized: "console.settings.continuousAF")
        case .productShowcase: String(localized: "console.settings.productFocus")
        }
    }
}

#Preview { NavigationStack { ConsoleView(camera: CameraController(), openConnection: {}) } }
