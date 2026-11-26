import Foundation
import LunaTransportProtocol

/// 视频规格是不可拆分的相机枚举。只列出当前模式有证据支持的规格。
enum ConsoleCaptureFormats {
    /// 更换比例或尺寸时尽量保留原分辨率等级与帧率，组合不可用时选择最接近的一项。
    static func closestVideo(_ choices: [LunaVideoResolution], to current: LunaVideoResolution?) -> LunaVideoResolution? {
        guard let current else { return choices.first(where: { $0.framesPerSecond == 30 }) ?? choices.first }
        return choices.min {
            distance($0, from: current) < distance($1, from: current)
        }
    }

    private static func distance(_ candidate: LunaVideoResolution, from current: LunaVideoResolution) -> (Int, Double) {
        (abs(max(candidate.width, candidate.height) - max(current.width, current.height)),
         abs(candidate.framesPerSecond - current.framesPerSecond))
    }

    struct Photo: Decodable, Identifiable {
        enum Quality: String, Decodable, CaseIterable, Identifiable {
            case standard, ultra
            var id: Self { self }
        }

        let id: UInt64
        let ratio: String
        let ratioCode: UInt64
        let quality: Quality
        let width: Int
        let height: Int

        var size: String { "\(width) × \(height)" }

        /// 比例和值同一次提交，保留相机预期的整个 PhotographyOptions 信封。
        func request() throws -> LunaRequest {
            var body = try ProtoMessage.blob(field: 20, value: Data())
                + ProtoMessage.blob(field: 21, value: Data())
            if ratioCode != 0 { body += try ProtoMessage.integer(field: 30, value: ratioCode) }
            body += try ProtoMessage.integer(field: 31, value: 1)
                + ProtoMessage.integer(field: 40, value: id)
                + ProtoMessage.integer(field: 88, value: 1)
            return try LunaProtocol.setPhotographyOptions(types: [40, 63, 30], nested: body,
                                                           mode: LunaFunctionMode.normalImage.rawValue)
        }
    }

    /// 照片格式只有 JPG 与 JPG+RAW（16-bit DNG）。开启写 type 25 = 1，关闭按官方做法省略该字段。
    static func rawRequest(_ enabled: Bool) throws -> LunaRequest {
        var body = try ProtoMessage.blob(field: 20, value: Data())
            + ProtoMessage.blob(field: 21, value: Data())
        if enabled { body += try ProtoMessage.integer(field: 25, value: 1) }
        body += try ProtoMessage.integer(field: 31, value: 1)
            + ProtoMessage.integer(field: 88, value: 1)
        return try LunaProtocol.setPhotographyOptions(types: [25], nested: body,
                                                       mode: LunaFunctionMode.normalImage.rawValue)
    }
}
