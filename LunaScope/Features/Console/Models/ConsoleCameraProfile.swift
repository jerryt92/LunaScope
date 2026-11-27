import Foundation
import LunaTransportProtocol

/// A bundled profile describes the options available over the shared Luna protocol.
struct ConsoleCameraProfile: Decodable {
    struct Mode: Decodable {
        let videoFormats: [UInt64]?
        let zoom: ZoomRule?
        let zoomOverrides: [ZoomOverride]?
        let tracking: Bool?
    }

    /// 画面调节项。出现在哪些拍摄模式、可选值和恢复默认值都写在机型 JSON 里。
    struct ImageControl: Decodable, Equatable {
        /// 稳定标识，同一模式内不重复。
        let id: String
        /// 摄影 option 类型号。
        let option: UInt32
        /// 拥有这项的拍摄模式，取值与 `modes` 的键相同。
        let modes: [String]
        /// 可选线值，顺序即界面顺序。
        let choices: [UInt64]
        /// 恢复默认时写回的线值。
        let defaultValue: UInt64
        /// 有符号显示的零点。对比度线值 3 显示为 0。
        let origin: UInt64?
        /// 线值到本地化 key。缺省时用枚举名、原点偏移或数字。
        let labels: [String: String]?
        /// 另一项的当前线值不在列表中时隐藏。
        let visibleWhen: VisibleWhen?

        /// 按另一项的当前值决定本项是否出现。
        struct VisibleWhen: Decodable, Equatable {
            let id: String
            let values: [UInt64]
        }

        enum CodingKeys: String, CodingKey {
            case id, option, modes, choices, origin, labels, visibleWhen
            case defaultValue = "default"
        }

        /// 当前线值的界面文字。
        func choiceLabel(_ value: UInt64) -> String {
            if let key = labels?[String(value)] {
                return String(localized: String.LocalizationValue(key))
            }
            if id == "focus", let focus = LunaAFMode(rawValue: value) { return focus.label }
            if id == "color", let color = LunaColorMode(rawValue: value) {
                switch color {
                case .standard: return String(localized: "console.settings.colorStandard")
                case .vivid: return String(localized: "console.settings.colorVivid")
                case .iLog, .hdr, .dolbyVision: return color.label
                }
            }
            if let origin {
                let delta = Int(value) - Int(origin)
                return delta > 0 ? "+\(delta)" : "\(delta)"
            }
            return String(value)
        }

        /// 项目名称。
        var title: String {
            switch id {
            case "focus": String(localized: "console.settings.focus")
            case "breathingCompensation": String(localized: "console.settings.breathingCompensation")
            case "contrast": String(localized: "console.settings.contrast")
            case "saturation": String(localized: "console.settings.saturation")
            case "sharpness": String(localized: "console.settings.sharpness")
            case "color": String(localized: "console.settings.color")
            default: id
            }
        }

        /// 项目图标。
        var symbol: String {
            switch id {
            case "focus": "scope"
            case "breathingCompensation": "lungs"
            case "contrast": "circle.lefthalf.filled"
            case "saturation": "drop.fill"
            case "sharpness": "triangle"
            case "color": "paintpalette"
            default: "slider.horizontal.3"
            }
        }

        /// 另一项当前值未知时仍显示；已知且不在允许列表里则隐藏。
        func isVisible(currentValue: (String) -> UInt64?) -> Bool {
            guard let visibleWhen else { return true }
            guard let current = currentValue(visibleWhen.id) else { return true }
            return visibleWhen.values.contains(current)
        }
    }

    struct VideoDefinition: Decodable {
        let width: Int
        let height: Int
        let framesPerSecond: Double
    }

    struct ZoomRule: Decodable {
        let maximum: Double?
        let fixedStops: [Double]?
        let recordingLensStarts: [Double]?
    }

    struct ZoomOverride: Decodable {
        let formatIDs: [UInt64]
        let rule: ZoomRule?
    }

    struct Exposure: Decodable {
        struct SlowVideoShutter: Decodable {
            let formatIDs: [UInt64]
            let minimumFirmware: String?

            func allows(format: UInt64, firmware: String?) -> Bool {
                guard formatIDs.contains(format) else { return false }
                guard let minimumFirmware else { return true }
                guard let firmware else { return false }
                let version = firmware.lowercased().hasPrefix("v") ? String(firmware.dropFirst()) : firmware
                guard version.first?.isNumber == true else { return false }
                return version.compare(minimumFirmware, options: .numeric) != .orderedAscending
            }
        }

        let iso: [UInt64]
        /// Auto ISO 上限档（界面显示为 400Max 等）；缺省时取 ISO 列表中 ≥400 的值。
        private let isoMaxValues: [UInt64]?
        let shutterDenominators: [Int]
        let longPhotoShutters: [Double]
        let slowVideoShutter: SlowVideoShutter?

        var isoMax: [UInt64] {
            let values: [UInt64] = isoMaxValues ?? iso.filter { $0 >= 400 }
            return values.filter { iso.contains($0) }
        }

        enum CodingKeys: String, CodingKey {
            case iso, shutterDenominators, longPhotoShutters, slowVideoShutter
            case isoMaxValues = "isoMax"
        }
    }

    struct WhiteBalance: Decodable {
        let minimum: Int
        let maximum: Int
        let step: Int
        var range: ClosedRange<Double>? {
            guard minimum > 0, maximum >= minimum, maximum <= Int(Int32.max) else { return nil }
            return Double(minimum)...Double(maximum)
        }

        var choices: [Int] {
            guard step > 0, minimum > 0, maximum >= minimum, maximum <= 100_000 else { return [] }
            return Array(stride(from: minimum, through: maximum, by: step))
        }

        func allows(_ kelvin: UInt64) -> Bool {
            kelvin == 0 || (Int(clamping: kelvin) >= minimum && Int(clamping: kelvin) <= maximum)
        }
    }

    let schemaVersion: Int
    let id: String
    let displayName: String
    let deviceModels: [String]
    let bluetoothPrefixes: [String]
    private let modes: [String: Mode]
    private let videoDefinitions: [String: VideoDefinition]?
    let photoFormats: [ConsoleCaptureFormats.Photo]
    let rawPhoto: Bool
    let livePhotoFormatIDs: [UInt64]
    let exposure: Exposure
    let whiteBalance: WhiteBalance
    private let colors: [UInt64]
    private let colorOverrides: [String: [UInt64]]
    private let imageControls: [ImageControl]?
    let zoomStops: [Double]
    private let gimbalModes: [UInt64]
    let detachableScreen: Bool

    var captureModes: [ConsoleCaptureMode] { ConsoleCaptureMode.allCases.filter { modes[$0.rawValue] != nil } }

    /// 当前拍摄模式在 JSON 里声明的画面项。默认值不在可选值里的项不采用。
    func imageControls(for mode: LunaShootingMode) -> [ImageControl] {
        let key = ConsoleCaptureMode(mode).rawValue
        var seen = Set<String>()
        return (imageControls ?? []).filter { control in
            control.modes.contains(key) && control.choices.contains(control.defaultValue)
                && seen.insert(control.id).inserted
        }
    }

    /// 对焦档位取当前模式的 focus 项，不在代码里按照片或视频删减。
    func focusChoices(for mode: LunaShootingMode) -> [LunaAFMode] {
        imageControls(for: mode).first { $0.id == "focus" }?.choices.compactMap(LunaAFMode.init(rawValue:)) ?? []
    }
    var gimbalChoices: [LunaGimbalMode] { gimbalModes.compactMap(LunaGimbalMode.init(rawValue:)) }
    var zoomDomain: ClosedRange<Double>? {
        let rules = modes.values.flatMap { mode in
            [mode.zoom].compactMap { $0 } + (mode.zoomOverrides ?? []).compactMap(\.rule)
        }
        let limits = rules.flatMap { rule in rule.maximum.map { [$0] } ?? rule.fixedStops ?? [] }
        guard let maximum = limits.max(), maximum.isFinite, maximum > 1 else { return nil }
        return 1...maximum
    }

    func videoFormat(_ code: UInt64) -> LunaVideoResolution? {
        if let custom = videoDefinitions?[String(code)] {
            return LunaVideoResolution(rawValue: code, width: custom.width, height: custom.height,
                                       framesPerSecond: custom.framesPerSecond)
        }
        return LunaVideoResolution(rawValue: code)
    }

    func video(for mode: LunaShootingMode) -> [LunaVideoResolution] {
        modes[ConsoleCaptureMode(mode).rawValue]?.videoFormats?.compactMap { videoFormat($0) } ?? []
    }

    func supports(_ code: UInt64, in mode: LunaShootingMode) -> Bool {
        guard let options = modes[ConsoleCaptureMode(mode).rawValue] else { return false }
        if mode == .photo { return photoFormats.contains { $0.id == code } }
        return options.videoFormats?.contains(code) == true && videoFormat(code) != nil
    }

    func supportsTracking(in mode: LunaShootingMode) -> Bool {
        modes[ConsoleCaptureMode(mode).rawValue]?.tracking == true
    }

    func allowsLivePhoto(format: UInt64?) -> Bool {
        format.map(livePhotoFormatIDs.contains) ?? false
    }

    /// 色彩档位。模式没有 color 项时为空；格式覆盖仍以 `colorOverrides` 为准。
    func colorChoices(for format: UInt64?, mode: LunaShootingMode) -> [LunaColorMode] {
        guard let control = imageControls(for: mode).first(where: { $0.id == "color" }) else { return [] }
        let listed = format.flatMap { colorOverrides[String($0)] } ?? control.choices
        return listed.filter { colors.contains($0) }.compactMap(LunaColorMode.init(rawValue:))
    }

    /// 某项在当前格式下真正可选的线值。
    func choiceValues(for control: ImageControl, format: UInt64?, mode: LunaShootingMode) -> [UInt64] {
        guard control.id == "color" else { return control.choices }
        let narrowed = colorChoices(for: format, mode: mode).map(\.rawValue)
        return narrowed.isEmpty ? control.choices : narrowed
    }

    func requiredColor(for format: UInt64) -> LunaColorMode? {
        guard let overrides = colorOverrides[String(format)], overrides.count == 1,
              let value = overrides.first else { return nil }
        return LunaColorMode(rawValue: value)
    }

    func shutterChoices(mode: LunaShootingMode, format: UInt64?, firmware: String? = nil) -> [Double] {
        let denominators = exposure.shutterDenominators.filter { $0 > 0 }
        if mode == .photo { return denominators.map { 1 / Double($0) } + exposure.longPhotoShutters }
        guard !mode.isPhoto, let format, supports(format, in: mode),
              let video = videoFormat(format) else { return [] }
        let allowsSlowShutter = mode == .video && exposure.slowVideoShutter?.allows(format: format, firmware: firmware) == true
        let minimumDenominator = allowsSlowShutter ? 5 : video.framesPerSecond
        return denominators.filter { Double($0) >= minimumDenominator }.map { 1 / Double($0) }
    }

    func zoomRule(mode: LunaShootingMode, format: UInt64?) -> ZoomRule? {
        guard let options = modes[ConsoleCaptureMode(mode).rawValue] else { return nil }
        if let overrides = options.zoomOverrides, !overrides.isEmpty {
            guard let format, supports(format, in: mode) else { return nil }
            if let override = overrides.first(where: { $0.formatIDs.contains(format) }) {
                return override.rule
            }
        }
        return options.zoom
    }

    static let bundled: [Self] = {
        // Xcode can flatten resources copied by a file-system-synchronized group.
        let locations: [String?] = [nil, "CameraProfiles", "Resources/CameraProfiles"]
        let urls: [URL] = locations.flatMap {
            Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: $0) ?? []
        }
        var profiles: [Self] = []
        var usedNames = Set<String>()
        var usedIDs = Set<String>()
        for url in Set(urls).sorted(by: { $0.path < $1.path })
        where url.lastPathComponent.hasPrefix("CameraProfile-") {
            do {
                let profile = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
                let names = Set(profile.deviceModels.map(normalize))
                guard profile.schemaVersion == 1, !profile.id.isEmpty, !names.isEmpty,
                      !names.contains(""), !profile.captureModes.isEmpty,
                      names.isDisjoint(with: usedNames), usedIDs.insert(profile.id).inserted else {
                    throw ProfileError.invalid
                }
                usedNames.formUnion(names)
                profiles.append(profile)
            } catch {
                AppLog.error(error, context: "console.profile.load.\(url.lastPathComponent)")
            }
        }
        return profiles
    }()

    static func matching(_ model: String) -> Self? {
        let name = normalize(model)
        return bundled.first { $0.deviceModels.map(normalize).contains(name) }
    }

    nonisolated private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum ProfileError: Error { case invalid }
}
