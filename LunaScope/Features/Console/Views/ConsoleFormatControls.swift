import LunaTransportProtocol
import SwiftUI

/// 规格类配置的单项；由参数栏按需排入同一行。
enum ConsoleFormatControl: Hashable {
    case photoSize, photoRAW, ratio, resolution, frameRate

    /// 当前模式可写入的规格项，顺序与原先菜单一致。
    static func available(for camera: CameraController) -> [Self] {
        guard let mode = camera.shootingMode, let profile = camera.cameraProfile else { return [] }
        switch mode {
        case .photo:
            var items: [Self] = [.photoSize]
            if profile.rawPhoto { items.append(.photoRAW) }
            return items
        case .pano:
            return []
        default:
            let all = profile.video(for: mode)
            let current = camera.parameters?.format.flatMap { profile.videoFormat($0) }
            let ratios = unique(all.map(\.aspectLabel))
            let sameRatio = all.filter { $0.aspectLabel == (current?.aspectLabel ?? ratios.first) }
            let sizes = unique(sameRatio.map(VideoSize.init))
            let currentSize = current.map(VideoSize.init)
            let sameSize = sameRatio.filter { VideoSize($0) == (currentSize ?? sizes.first) }
            var items: [Self] = []
            if !ratios.isEmpty { items.append(.ratio) }
            if !sizes.isEmpty { items.append(.resolution) }
            if !sameSize.isEmpty { items.append(.frameRate) }
            return items
        }
    }

    private static func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }

    private nonisolated struct VideoSize: Hashable {
        let width: Int
        let height: Int
        init(_ format: LunaVideoResolution) {
            width = format.width
            height = format.height
        }
    }
}

/// 呈现当前模式下相机能写入的完整比例、尺寸和帧率组合中的一项。
struct ConsoleFormatControls: View {
    let camera: CameraController
    let control: ConsoleFormatControl
    @State private var photoSizeSelection: PhotoSizeDraft?

    var body: some View {
        switch control {
        case .photoSize: photoSizeControl
        case .photoRAW: photoRAWMenu
        case .ratio: videoRatioMenu
        case .resolution: videoSizeMenu
        case .frameRate: frameRateMenu
        }
    }

    /// 照片尺寸：点开后左右分栏，一边选标准/超清，一边选比例。
    /// 实况开启时仍列出超清；选中冲突规格时由 setFormat 关掉实况。
    private var photoSizeControl: some View {
        let photos = camera.cameraProfile?.photoFormats ?? []
        let current = photos.first { $0.id == camera.parameters?.format }
        return Button {
            photoSizeSelection = PhotoSizeDraft(formats: photos, current: current)
        } label: {
            ConsoleMenuLabel(title: "console.format.photoSize",
                             value: current.map { "\($0.ratio) · \(qualityLabel($0.quality))" })
        }
        .buttonStyle(.plain)
        .disabled(!camera.canEditShootingSettings || photos.isEmpty)
        .accessibilityIdentifier("console.format.photoSize")
        .sheet(item: $photoSizeSelection) { draft in
            PhotoSizeSheet(camera: camera, draft: draft) { photoSizeSelection = nil }
        }
        .onChange(of: camera.shootingMode) { photoSizeSelection = nil }
        .onChange(of: camera.connected) { if !camera.connected { photoSizeSelection = nil } }
    }

    private var photoRAWMenu: some View {
        let raw = camera.parameters?.rawCapture
        let value = raw.map { $0 ? "JPG + RAW" : "JPG" }
        return Menu {
            Button { camera.setPhotoRAW(false) } label: { selection("JPG", raw == false) }
                .disabled(raw == nil)
            Button { camera.setPhotoRAW(true) } label: { selection("JPG + RAW", raw == true) }
                .disabled(raw == nil)
            if raw == nil {
                Button("common.retry", action: camera.retryPhotoFormat)
            }
        } label: {
            ConsoleMenuLabel(title: "console.format.photoFormat",
                             value: value ?? (camera.readingPhotoFormat ? String(localized: "console.capture.working")
                                               : String(localized: "permissions.status.unknown")))
        }
        .consoleMenu(raw == nil ? camera.connected && !camera.readingPhotoFormat : camera.canEditShootingSettings)
        .accessibilityIdentifier("console.format.raw")
    }

    private var videoRatioMenu: some View {
        let all = videoFormats
        let current = currentVideo
        let ratios = unique(all.map(\.aspectLabel))
        return Menu {
            ForEach(ratios, id: \.self) { ratio in
                Button {
                    let options = all.filter { $0.aspectLabel == ratio }
                    if let choice = ConsoleCaptureFormats.closestVideo(options, to: current) {
                        camera.setFormat(choice.rawValue)
                    }
                } label: { selection(ratio, current?.aspectLabel == ratio) }
            }
        } label: { ConsoleMenuLabel(title: "console.format.ratio", value: current?.aspectLabel) }
        .consoleMenu(camera.canEditShootingSettings && !ratios.isEmpty)
        .accessibilityIdentifier("console.format.ratio")
    }

    private var videoSizeMenu: some View {
        let all = videoFormats
        let current = currentVideo
        let ratios = unique(all.map(\.aspectLabel))
        let sameRatio = all.filter { $0.aspectLabel == (current?.aspectLabel ?? ratios.first) }
        let sizes = unique(sameRatio.map(VideoSize.init))
        return Menu {
            ForEach(sizes, id: \.self) { size in
                Button {
                    let matches = sameRatio.filter { VideoSize($0) == size }
                    if let choice = ConsoleCaptureFormats.closestVideo(matches, to: current) {
                        camera.setFormat(choice.rawValue)
                    }
                } label: {
                    selection(resolution(size.width, size.height), current.map(VideoSize.init) == size)
                }
            }
        } label: {
            ConsoleMenuLabel(title: "console.format.resolution",
                             value: current.map { resolution($0.width, $0.height) })
        }
        .consoleMenu(camera.canEditShootingSettings && !sizes.isEmpty)
        .accessibilityIdentifier("console.format.resolution")
    }

    private var frameRateMenu: some View {
        let all = videoFormats
        let current = currentVideo
        let ratios = unique(all.map(\.aspectLabel))
        let sameRatio = all.filter { $0.aspectLabel == (current?.aspectLabel ?? ratios.first) }
        let sizes = unique(sameRatio.map(VideoSize.init))
        let currentSize = current.map(VideoSize.init)
        let sameSize = sameRatio.filter { VideoSize($0) == (currentSize ?? sizes.first) }
        return Menu {
            ForEach(sameSize, id: \.rawValue) { choice in
                Button { camera.setFormat(choice.rawValue) } label: {
                    selection(frameRate(choice.framesPerSecond), current?.rawValue == choice.rawValue)
                }
            }
        } label: {
            ConsoleMenuLabel(title: "console.format.frameRate",
                             value: current.map { frameRate($0.framesPerSecond) })
        }
        .consoleMenu(camera.canEditShootingSettings && !sameSize.isEmpty)
        .accessibilityIdentifier("console.format.frameRate")
    }

    private var videoFormats: [LunaVideoResolution] {
        guard let mode = camera.shootingMode, let profile = camera.cameraProfile else { return [] }
        return profile.video(for: mode)
    }

    private var currentVideo: LunaVideoResolution? {
        camera.parameters?.format.flatMap { camera.cameraProfile?.videoFormat($0) }
    }

    private func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func resolution(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }

    private func frameRate(_ rate: Double) -> String {
        let value = rate.formatted(.number.precision(.fractionLength(0...2)))
        return String(localized: "console.format.fps \(value)")
    }

    private func qualityLabel(_ quality: ConsoleCaptureFormats.Photo.Quality) -> String {
        Self.qualityLabel(quality)
    }

    fileprivate static func qualityLabel(_ quality: ConsoleCaptureFormats.Photo.Quality) -> String {
        switch quality {
        case .standard: String(localized: "console.format.standardPhoto")
        case .ultra: String(localized: "console.format.ultraPhoto")
        }
    }

    @ViewBuilder
    private func selection(_ text: String, _ selected: Bool) -> some View {
        if selected { Label(text, systemImage: "checkmark") }
        else { Text(text) }
    }

    private nonisolated struct VideoSize: Hashable {
        let width: Int
        let height: Int
        init(_ format: LunaVideoResolution) {
            width = format.width
            height = format.height
        }
    }
}

/// 打开照片尺寸面板时冻结可选规格，避免回读抖动重置滚轮。
private struct PhotoSizeDraft: Identifiable {
    let id = UUID()
    let formats: [ConsoleCaptureFormats.Photo]
    let current: ConsoleCaptureFormats.Photo?
}

/// 照片尺寸双栏：左栏标准/超清，右栏比例；选中即写入对应组合规格。
private struct PhotoSizeSheet: View {
    let camera: CameraController
    let draft: PhotoSizeDraft
    let dismiss: () -> Void
    @State private var quality: ConsoleCaptureFormats.Photo.Quality
    @State private var ratio: String

    init(camera: CameraController, draft: PhotoSizeDraft, dismiss: @escaping () -> Void) {
        self.camera = camera
        self.draft = draft
        self.dismiss = dismiss
        let current = draft.current
        _quality = State(initialValue: current?.quality ?? draft.formats.first?.quality ?? .standard)
        _ratio = State(initialValue: current?.ratio ?? draft.formats.first?.ratio ?? "4:3")
    }

    private var qualities: [ConsoleCaptureFormats.Photo.Quality] {
        ConsoleCaptureFormats.Photo.Quality.allCases.filter { quality in
            draft.formats.contains { $0.quality == quality }
        }
    }

    private var ratios: [String] {
        var seen: Set<String> = []
        // 比例列表随当前画质变化：超清可能没有竖幅等规格。
        return draft.formats.filter { $0.quality == quality }.compactMap { format in
            seen.insert(format.ratio).inserted ? format.ratio : nil
        }
    }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                column("console.format.quality") {
                    Picker("console.format.quality", selection: $quality) {
                        ForEach(qualities, id: \.self) { value in
                            Text(ConsoleFormatControls.qualityLabel(value)).tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityIdentifier("console.format.quality.wheel")
                    .onChange(of: quality, initial: false) { _, value in
                        apply(quality: value, ratio: preferredRatio(keeping: ratio, quality: value))
                    }
                }
                Divider()
                column("console.format.ratio") {
                    Picker("console.format.ratio", selection: $ratio) {
                        ForEach(ratios, id: \.self) { value in
                            Text(verbatim: value).tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityIdentifier("console.format.ratio.wheel")
                    .onChange(of: ratio, initial: false) { _, value in
                        apply(quality: quality, ratio: value)
                    }
                }
            }
            .padding(.horizontal, 8)
            .navigationTitle("console.format.photoSize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close", action: dismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
        .tint(Palette.accent)
        .onChange(of: qualities) { _, values in
            if !values.contains(quality), let first = values.first {
                quality = first
                ratio = preferredRatio(keeping: ratio, quality: first)
            }
        }
        .onChange(of: ratios) { _, values in
            if !values.contains(ratio), let first = values.first { ratio = first }
        }
        // 关掉实况后的轻提示在主界面；收起尺寸面板以免挡住。
        .onChange(of: camera.parameters?.livePhoto) { wasLive, isLive in
            if wasLive == true, isLive == false { dismiss() }
        }
    }

    private func column<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    /// 切换画质时尽量保留原比例；该画质没有该比例则落到同画质第一项。
    private func preferredRatio(keeping ratio: String, quality: ConsoleCaptureFormats.Photo.Quality) -> String {
        let matches = draft.formats.filter { $0.quality == quality }
        if matches.contains(where: { $0.ratio == ratio }) { return ratio }
        return matches.first?.ratio ?? ratio
    }

    private func apply(quality: ConsoleCaptureFormats.Photo.Quality, ratio: String) {
        self.quality = quality
        self.ratio = ratio
        guard let format = draft.formats.first(where: { $0.quality == quality && $0.ratio == ratio })
                ?? draft.formats.first(where: { $0.quality == quality }) else { return }
        if format.ratio != ratio { self.ratio = format.ratio }
        camera.setFormat(format.id)
    }
}

/// 菜单显示相机回读值，缺少回读时保持待确认状态。
struct ConsoleMenuLabel: View {
    static let spacing: CGFloat = 5
    static let minHeight: CGFloat = 32
    /// 每个配置项的最小宽度。放不下就换行，避免把标题挤到不可读。
    static let minItemWidth: CGFloat = 132
    let title: LocalizedStringKey
    let value: String?
    var isMenu = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.secondary)
            HStack(spacing: 3) {
                Text(value ?? "—")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isMenu && value != nil ? Palette.accent : Palette.secondary)
                Spacer(minLength: 0)
                if isMenu {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        .background(isMenu ? Palette.field : Palette.background, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

extension View {
    func consoleMenu(_ enabled: Bool) -> some View {
        menuOrder(.fixed)
            .menuActionDismissBehavior(.disabled)
            .disabled(!enabled)
    }
}
