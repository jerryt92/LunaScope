import Foundation
import LunaTransportProtocol
import OpenCineCore

/// 保存相机已报告的曝光值。自动部分保持为空，恢复时在一次命令里写入完整曝光程序。
/// `isoTopLimit` 表示 Auto ISO 上限（如 800Max）；与固定 ISO 互斥。
struct ConsoleExposure: Codable, Equatable {
    enum Program: String, Codable {
        case automatic, manual, isoPriority, shutterPriority

        var native: LunaExposureProgram {
            switch self {
            case .automatic: .automatic
            case .manual: .manual
            case .isoPriority: .isoPriority
            case .shutterPriority: .shutterPriority
            }
        }
    }

    let program: Program
    let iso: UInt64?
    let shutter: Double?
    let isoTopLimit: UInt64?

    init(iso: UInt64?, shutter: Double?, isoTopLimit: UInt64? = nil) {
        let ceiling = iso == nil ? isoTopLimit : nil
        let program: Program = switch (iso, shutter) {
        case (nil, nil): .automatic
        case (.some, nil): .isoPriority
        case (nil, .some): .shutterPriority
        case (.some, .some): .manual
        }
        self.init(program: program, iso: iso, shutter: shutter, isoTopLimit: ceiling)
    }

    init(program: Program, iso: UInt64?, shutter: Double?, isoTopLimit: UInt64? = nil) {
        self.program = program
        self.iso = (program == .manual || program == .isoPriority) ? iso : nil
        self.shutter = (program == .manual || program == .shutterPriority) ? shutter : nil
        // Max 只在 Auto ISO 程序下生效，与固定感光度互斥。
        self.isoTopLimit = (program == .automatic || program == .shutterPriority) ? isoTopLimit : nil
    }

    init?(_ value: LunaExposure, isoTopLimit reportedLimit: UInt64? = nil) {
        guard let native = value.exposureProgram else { return nil }
        let program: Program
        switch native {
        case .automatic, .adaptive, .fullAuto: program = .automatic
        case .manual: program = .manual
        case .isoPriority: program = .isoPriority
        case .shutterPriority: program = .shutterPriority
        }
        let fixedISO = value.iso > 0 ? value.iso : nil
        let ceiling: UInt64? = {
            guard fixedISO == nil, let reportedLimit,
                  !LunaProtocol.isUnlimitedISOTopLimit(reportedLimit) else { return nil }
            return reportedLimit
        }()
        self.init(program: program, iso: fixedISO,
                  shutter: value.shutterSeconds > 0 ? value.shutterSeconds : nil,
                  isoTopLimit: ceiling)
        guard isComplete else { return nil }
    }

    var isComplete: Bool {
        let validISO = iso.map { (1...UInt64(UInt32.max)).contains($0) } == true
        let validShutter = shutter.map { $0.isFinite && $0 > 0 && $0 <= 60 } == true
        let validMax = isoTopLimit.map {
            (1...UInt64(UInt32.max)).contains($0) && !LunaProtocol.isUnlimitedISOTopLimit($0)
        } == true
        switch program {
        case .automatic: return iso == nil && shutter == nil && (isoTopLimit == nil || validMax)
        case .manual: return validISO && validShutter && isoTopLimit == nil
        case .isoPriority: return validISO && shutter == nil && isoTopLimit == nil
        case .shutterPriority: return iso == nil && validShutter && (isoTopLimit == nil || validMax)
        }
    }

    func matches(_ observed: Self?) -> Bool {
        guard let observed, program == observed.program, iso == observed.iso else { return false }
        // 固定 ISO 时 Max 无效。带上限时核对；无上限 Auto/快门优先允许机身残留 Max（清 24 常被忽略）。
        switch program {
        case .isoPriority, .manual:
            break
        case .automatic, .shutterPriority:
            if let isoTopLimit {
                guard isoTopLimit == observed.isoTopLimit else { return false }
            }
        }
        switch (shutter, observed.shutter) {
        case (nil, nil): return true
        case (let expected?, let actual?):
            if abs(expected - actual) <= max(expected * 0.005, 0.000_001) { return true }
            // 快门常用 1/N：用倒数比较，避免机身 IEEE 双精度与选项表不完全一致。
            guard expected > 0, actual > 0, expected < 1, actual < 1 else { return false }
            let expectedDenominator = 1 / expected
            let actualDenominator = 1 / actual
            return abs(expectedDenominator - actualDenominator) <= 0.51
                && abs(expectedDenominator.rounded() - expectedDenominator) < 0.05
        default: return false
        }
    }

    /// 用户选择是否已是目标。无上限 Auto 与 xxxMax 必须区分；回读确认仍用 `matches`。
    func matchesIntent(_ observed: Self?) -> Bool {
        guard let observed, isoTopLimit == observed.isoTopLimit else { return false }
        return matches(observed)
    }

    /// 照片会同时写 still(20)/video(21)，确认时任一路匹配即视为成功，避免仍读到旧 still 误失败。
    func matchedReport(in settings: LunaPhotographySettings) -> ConsoleExposure? {
        let limit = settings.isoTopLimit
        let banks = [settings.stillExposure, settings.videoExposure].compactMap { bank -> ConsoleExposure? in
            guard let bank else { return nil }
            return ConsoleExposure(bank, isoTopLimit: limit)
        }
        return banks.first { matches($0) }
    }

    func request(mode: LunaShootingMode) throws -> LunaRequest {
        try LunaProtocol.setVideoExposure(program: program.native, iso: iso, shutterSeconds: shutter,
                                          isoTopLimit: isoTopLimit, functionMode: mode.functionMode.rawValue)
    }

    /// 参数记忆里曝光字段的可读片段。
    var summaryParts: [String] {
        var parts: [String] = []
        let auto = String(localized: "console.settings.auto")
        switch program {
        case .automatic:
            if let isoTopLimit {
                parts.append("ISO \(ConsoleManualExposure.isoMaxLabel(isoTopLimit))")
            } else {
                parts.append("\(auto) ISO")
            }
        case .isoPriority:
            if let iso { parts.append("ISO \(iso)") }
        case .shutterPriority:
            if let shutter { parts.append(ConsoleManualExposure.shutterLabel(shutter)) }
            if let isoTopLimit {
                parts.append("ISO \(ConsoleManualExposure.isoMaxLabel(isoTopLimit))")
            } else {
                parts.append("\(auto) ISO")
            }
        case .manual:
            if let iso { parts.append("ISO \(iso)") }
            if let shutter { parts.append(ConsoleManualExposure.shutterLabel(shutter)) }
        }
        return parts
    }
}

/// 一组拍摄模式的参数。回读和界面选择分别保存，合并时只覆盖有值的字段。
struct ConsoleParameters: Codable, Equatable {
    static let optionTypes: [UInt32] = [7, 20, 21, 24, 25, 31, 35, 39, 40, 46, 53, 93, 100]
    static let exposureBiasChoices = (-12...12).map { Int32((Double($0) * 10 / 3).rounded()) }

    let mode: ConsoleCaptureMode
    var format: UInt64?
    var exposure: ConsoleExposure?
    var exposureControlMode: LunaIQ3AMode?
    var exposureBiasTenths: Int32?
    var faceMetering: Bool?
    var whiteBalance: UInt64?
    var autofocus: UInt64?
    var zoom: Double?
    var color: UInt64?
    var rawCapture: Bool?
    var livePhoto: Bool?
    /// App 侧连续拍照；相机仍是单张照片模式，不进机身回读。
    var continuousPhoto: Bool?
    /// 连续拍照间隔；仅在 `continuousPhoto == true` 时有意义。
    var continuousInterval: ConsoleShootInterval?

    init(mode: LunaShootingMode) { self.mode = ConsoleCaptureMode(mode) }

    mutating func merge(_ changes: Self) {
        guard mode == changes.mode else { return }
        format = changes.format ?? format
        exposure = changes.exposure ?? exposure
        exposureControlMode = changes.exposureControlMode ?? exposureControlMode
        exposureBiasTenths = changes.exposureBiasTenths ?? exposureBiasTenths
        faceMetering = changes.faceMetering ?? faceMetering
        whiteBalance = changes.whiteBalance ?? whiteBalance
        autofocus = changes.autofocus ?? autofocus
        zoom = changes.zoom ?? zoom
        color = changes.color ?? color
        rawCapture = changes.rawCapture ?? rawCapture
        livePhoto = changes.livePhoto ?? livePhoto
        continuousPhoto = changes.continuousPhoto ?? continuousPhoto
        continuousInterval = changes.continuousInterval ?? continuousInterval
    }

    mutating func ingest(_ value: LunaPhotographySettings) {
        let photo = mode.native.isPhoto
        if let raw = value.iq3AMode, let exposureMode = LunaIQ3AMode(rawValue: raw) {
            exposureControlMode = exposureMode
        }
        if let reported = photo ? value.photoResolution : value.recordResolution {
            format = reported
        }
        // 照片优先 still、录像优先 video；空默认包（全 0）视为未就绪，改用另一路，避免误判成 Auto。
        if let reported = Self.preferredExposure(
            primary: photo ? value.stillExposure : value.videoExposure,
            secondary: photo ? value.videoExposure : value.stillExposure
        ) {
            exposure = ConsoleExposure(reported, isoTopLimit: value.isoTopLimit)
        }
        if let kelvin = value.whiteBalanceKelvin ?? (value.types.contains(39) ? 0 : nil) { whiteBalance = kelvin }
        if let bias = value.exposureBiasTenths { exposureBiasTenths = bias }
        if let enabled = value.faceMetering { faceMetering = enabled }
        if let autofocus = value.afMode { self.autofocus = autofocus }
        if let zoom = value.zoom, zoom.isFinite, zoom >= 1 { self.zoom = zoom }
        if !photo, let color = value.colorMode { self.color = color }
    }

    /// 只解析请求包含照片格式的回复。成功回读的照片尺寸或选项回显才能证明省略的 RAW 为默认 JPG。
    mutating func ingestRAW(response: Data) throws {
        guard mode == .photo else { return }
        let outer = try ProtoMessage(response)
        let reportedTypes = try outer.repeatedUnsigned(1, maximumValues: 256)
        if let nested = try outer.optionalBytes(2) {
            let options = try ProtoMessage(nested)
            if options.fields.contains(where: { $0.number == 25 }) {
                rawCapture = try options.unsigned(25) != 0
                return
            }
            if options.fields.contains(where: { $0.number == 40 }) {
                rawCapture = false
                return
            }
        }
        if reportedTypes.contains(25) { rawCapture = false }
    }

    /// 实况照片的切换中状态和未报告字段都不能当作关。
    mutating func ingestLivePhoto(response: Data) throws {
        guard mode == .photo, let bytes = try ProtoMessage(response).optionalBytes(2),
              let live = try ProtoMessage(bytes).optionalBytes(ConsoleLivePhoto.option) else { return }
        let result = try ProtoMessage(live).unsigned(2)
        livePhoto = ConsoleLivePhoto.enabled(mode: result)
    }

    /// 保存一组由控制台确实能重放的参数。相机可能回读其他固件私有值。
    func restorable(for profile: ConsoleCameraProfile, currentFormat: UInt64? = nil, firmware: String? = nil) -> Self {
        var copy = self
        let native = mode.native
        if let format, !profile.supports(format, in: native) { copy.format = nil }
        let targetFormat = copy.format ?? currentFormat
        if let exposure {
            let isoAllowed = exposure.iso.map { value in
                guard let minimum = profile.exposure.iso.min(), let maximum = profile.exposure.iso.max() else { return false }
                return (minimum...maximum).contains(value)
            } ?? true
            let maxAllowed = exposure.isoTopLimit.map { profile.exposure.isoMax.contains($0) } ?? true
            let shutters = profile.shutterChoices(mode: native, format: targetFormat, firmware: firmware)
            let shutterAllowed = exposure.shutter.map { duration in
                if !native.isPhoto, targetFormat == nil { return duration > 0 && duration <= 0.2 }
                guard let minimum = shutters.min(), let maximum = shutters.max() else { return false }
                return (minimum * 0.995...maximum * 1.005).contains(duration)
            } ?? true
            if native == .pano || !isoAllowed || !maxAllowed || !shutterAllowed { copy.exposure = nil }
        }
        if native != .photo || !profile.rawPhoto { copy.rawCapture = nil }
        if native == .pano {
            copy.exposureControlMode = nil
            copy.exposureBiasTenths = nil
            copy.faceMetering = nil
        }
        if copy.exposureControlMode == .basic { copy.clearProfessionalOverrides() }
        if let bias = copy.exposureBiasTenths, !(-40...40).contains(bias) { copy.exposureBiasTenths = nil }
        if native != .photo || profile.livePhotoFormatIDs.isEmpty
            || (livePhoto == true && !profile.allowsLivePhoto(format: targetFormat)) {
            copy.livePhoto = nil
        }
        if let autofocus, !profile.focusChoices.contains(where: { $0.rawValue == autofocus }) { copy.autofocus = nil }
        if let kelvin = whiteBalance, !profile.whiteBalance.allows(kelvin) {
            copy.whiteBalance = nil
        }
        if let zoom {
            let limits = profile.zoomDomain.flatMap {
                ConsoleZoom(profile: profile, mode: native, format: targetFormat, domain: SettingDomain(range: $0))
            }
            if limits?.allows(ConsoleZoom.quantize(zoom)) == true { copy.zoom = ConsoleZoom.quantize(zoom) }
            else { copy.zoom = nil }
        }
        if let color, native.isPhoto || !profile.colorChoices(for: targetFormat).contains(where: { $0.rawValue == color }) {
            copy.color = nil
        }
        // 连拍是控制台调度，仅照片模式可恢复；可与实况同时保存。
        if native == .photo, continuousPhoto == true {
            copy.continuousPhoto = true
            copy.continuousInterval = continuousInterval ?? ConsoleShootInterval()
        } else {
            copy.continuousPhoto = native == .photo ? false : nil
            copy.continuousInterval = nil
        }
        return copy
    }

    mutating func clearProfessionalOverrides() {
        exposure = nil
        whiteBalance = nil
        faceMetering = nil
    }

    mutating func useProfessionalSettings(from settings: Self) {
        guard mode == settings.mode else { return }
        exposureControlMode = .professional
        exposure = settings.exposure
        exposureBiasTenths = settings.exposureBiasTenths
        whiteBalance = settings.whiteBalance
        faceMetering = settings.faceMetering
        autofocus = settings.autofocus
    }

    func isConfirmed(by current: Self) -> Bool {
        mode == current.mode
            && (format == nil || format == current.format)
            && (exposureControlMode == nil || exposureControlMode == current.exposureControlMode)
            && (exposureControlMode == .basic || exposure == nil || exposure?.matches(current.exposure) == true)
            && (exposureBiasTenths == nil || exposureBiasTenths == current.exposureBiasTenths)
            && (exposureControlMode == .basic || faceMetering == nil || faceMetering == current.faceMetering)
            && (exposureControlMode == .basic || whiteBalance == nil || whiteBalance == current.whiteBalance)
            && (autofocus == nil || autofocus == current.autofocus)
            && (color == nil || color == current.color)
            && (rawCapture == nil || rawCapture == current.rawCapture)
            && (livePhoto == nil || livePhoto == current.livePhoto)
            && (zoom.map { expected in current.zoom.map { abs($0 - expected) <= 0.03 } == true } ?? true)
    }

    var hasValues: Bool {
        format != nil || exposure != nil || whiteBalance != nil || autofocus != nil || zoom != nil || color != nil
            || exposureControlMode != nil || exposureBiasTenths != nil || faceMetering != nil
            || rawCapture != nil || livePhoto != nil
            || continuousPhoto == true
    }

    /// 参数记忆列表摘要：按实际保存字段拼装，规格解析失败时回退数值，不丢掉曝光等其它项。
    func detailSummary(profile: ConsoleCameraProfile?) -> String {
        let native = mode.native
        var parts: [String] = []
        switch exposureControlMode {
        case .basic: parts.append("A")
        case .professional: parts.append("M")
        case nil: break
        }
        if continuousPhoto == true {
            parts.append(String(localized: "console.mode.continuousPhoto"))
            if let continuousInterval {
                parts.append(continuousInterval.summaryLabel)
            }
        } else {
            parts.append(native.label)
        }
        if let code = format {
            parts.append(Self.formatSummary(code: code, mode: native, profile: profile))
        }
        if let exposure {
            parts.append(contentsOf: exposure.summaryParts)
        }
        if let bias = exposureBiasTenths, bias != 0 { parts.append("\(Self.exposureBiasLabel(bias)) EV") }
        if let faceMetering { parts.append(Self.meteringLabel(faceMetering)) }
        if let whiteBalance {
            if whiteBalance == 0 {
                parts.append(String(localized: "console.settings.auto") + " WB")
            } else {
                parts.append("\(whiteBalance) K")
            }
        }
        if let autofocus, let focus = LunaAFMode(rawValue: autofocus), focus != .productShowcase {
            parts.append(focus.label)
        }
        if let color, let mode = LunaColorMode(rawValue: color) {
            parts.append(Self.colorLabel(mode))
        }
        if let zoom {
            let value = zoom.formatted(.number.precision(.fractionLength(0...2)))
            parts.append("\(value)×")
        }
        if rawCapture == true { parts.append("RAW") }
        if livePhoto == true { parts.append(String(localized: "console.livePhoto.title")) }
        return parts.joined(separator: " · ")
    }

    nonisolated static func exposureBiasLabel(_ tenths: Int32) -> String {
        (Double(tenths) / 10).formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always(includingZero: false)))
    }

    nonisolated static func meteringLabel(_ facePriority: Bool) -> String {
        facePriority ? String(localized: "console.settings.facePriority") : String(localized: "console.settings.matrixMetering")
    }

    private static func formatSummary(code: UInt64, mode: LunaShootingMode, profile: ConsoleCameraProfile?) -> String {
        if mode == .photo {
            if let format = profile?.photoFormats.first(where: { $0.id == code }) {
                let quality = switch format.quality {
                case .standard: String(localized: "console.format.standardPhoto")
                case .ultra: String(localized: "console.format.ultraPhoto")
                }
                return "\(format.ratio) · \(format.size) · \(quality)"
            }
            return String(localized: "console.presets.formatCode \(code)")
        }
        if let format = profile?.videoFormat(code) ?? LunaVideoResolution(rawValue: code) {
            let fps = format.framesPerSecond.formatted(.number.precision(.fractionLength(0...2)))
            return "\(format.aspectLabel) · \(format.width) × \(format.height) · \(String(localized: "console.format.fps \(fps)"))"
        }
        return String(localized: "console.presets.formatCode \(code)")
    }

    private static func colorLabel(_ color: LunaColorMode) -> String {
        switch color {
        case .standard: String(localized: "console.settings.colorStandard")
        case .vivid: String(localized: "console.settings.colorVivid")
        case .iLog, .hdr, .dolbyVision: color.label
        }
    }

    /// 全 0 的曝光包与「未写入」无法区分时，若另一路有实质值则采用另一路。
    private static func preferredExposure(primary: LunaExposure?, secondary: LunaExposure?) -> LunaExposure? {
        switch (primary, secondary) {
        case (let first?, let second?):
            if isEmptyDefault(first), !isEmptyDefault(second) { return second }
            return first
        case (let first?, nil): return first
        case (nil, let second?): return second
        case (nil, nil): return nil
        }
    }

    private static func isEmptyDefault(_ value: LunaExposure) -> Bool {
        value.program == 0 && value.iso == 0 && value.shutterSeconds == 0
    }
}
