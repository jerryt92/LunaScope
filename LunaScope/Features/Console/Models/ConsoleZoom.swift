import LunaTransportProtocol
import OpenCineCore

/// 当前机型、拍摄模式和规格允许使用的变焦范围。
struct ConsoleZoom: Equatable {
    static let step = 0.025

    let stops: [Double]
    let fineRange: ClosedRange<Double>?
    private let domain: SettingDomain

    init?(profile: ConsoleCameraProfile, mode: LunaShootingMode, format: UInt64?, domain: SettingDomain,
          recording: Bool = false, reportedZoom: Double? = nil) {
        guard let rule = profile.zoomRule(mode: mode, format: format) else { return nil }
        var range: ClosedRange<Double>?
        if let maximum = rule.maximum, maximum.isFinite, maximum > 1 {
            range = 1...maximum
            if recording, let starts = rule.recordingLensStarts {
                guard let reportedZoom, (1...maximum).contains(reportedZoom),
                      let lower = starts.last(where: { $0 <= reportedZoom }) else { return nil }
                let upper = starts.first(where: { $0 > reportedZoom }).map { $0 - Self.step } ?? maximum
                guard lower <= upper, lower >= 1, upper <= maximum else { return nil }
                range = lower...upper
            }
        }

        let supportedStops = range.map { range in profile.zoomStops.filter(range.contains) } ?? rule.fixedStops ?? []
        stops = supportedStops.filter { domain.contains(.zoom($0)) }
        fineRange = Self.intersection(range, domain.range)
        self.domain = domain
        guard !stops.isEmpty || fineRange != nil else { return nil }
    }

    func allows(_ factor: Double) -> Bool {
        (stops.contains(factor) || fineRange?.contains(factor) == true) && domain.contains(.zoom(factor))
    }

    static func quantize(_ factor: Double) -> Double { (factor * 40).rounded() / 40 }

    private static func intersection(_ allowed: ClosedRange<Double>?, _ reported: ClosedRange<Double>?) -> ClosedRange<Double>? {
        guard let allowed, let reported else { return nil }
        let minimum = max(allowed.lowerBound, reported.lowerBound)
        let maximum = min(allowed.upperBound, reported.upperBound)
        let first = (minimum * 40).rounded(.up) / 40
        let last = (maximum * 40).rounded(.down) / 40
        return first < last ? first...last : nil
    }
}
