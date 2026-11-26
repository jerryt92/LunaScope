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
    private let focusModes: [UInt64]
    private let colors: [UInt64]
    private let colorOverrides: [String: [UInt64]]
    let zoomStops: [Double]
    private let gimbalModes: [UInt64]
    let detachableScreen: Bool

    var captureModes: [ConsoleCaptureMode] { ConsoleCaptureMode.allCases.filter { modes[$0.rawValue] != nil } }
    var focusChoices: [LunaAFMode] { focusModes.compactMap(LunaAFMode.init(rawValue:)) }
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

    func colorChoices(for format: UInt64?) -> [LunaColorMode] {
        let values = format.flatMap { colorOverrides[String($0)] } ?? colors
        return values.compactMap(LunaColorMode.init(rawValue:))
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
