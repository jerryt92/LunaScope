import Foundation
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

    /// 固定档多于一个，或可以连续变焦时，才显示控件。
    var offersChoice: Bool { fineRange != nil || stops.count > 1 }

    /// 连续范围内的对数位置：0 为下限，1 为上限，每加倍程占同样路程。
    func unitPosition(of factor: Double) -> Double? {
        guard let fineRange, factor > 0 else { return nil }
        let lower = log2(fineRange.lowerBound)
        let upper = log2(fineRange.upperBound)
        guard upper > lower else { return nil }
        let clamped = min(max(factor, fineRange.lowerBound), fineRange.upperBound)
        return min(1, max(0, (log2(clamped) - lower) / (upper - lower)))
    }

    /// 把 0...1 的对数位置还原成连续范围内的量化倍数。
    func factor(atUnitPosition position: Double) -> Double? {
        guard let fineRange else { return nil }
        let lower = log2(fineRange.lowerBound)
        let upper = log2(fineRange.upperBound)
        guard upper > lower else { return nil }
        let unit = min(1, max(0, position))
        let quantized = Self.quantize(pow(2, lower + (upper - lower) * unit))
        return min(fineRange.upperBound, max(fineRange.lowerBound, quantized))
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
