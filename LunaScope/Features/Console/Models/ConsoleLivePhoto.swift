import LunaTransportProtocol

/// Luna Ultra 把实况照片存为标准照片选项。8298 的值 3 表示正在切换。
enum ConsoleLivePhoto {
    static let option = 85

    static func enabled(mode: UInt64) -> Bool? {
        switch mode {
        case 1: false
        case 2: true
        default: nil
        }
    }

    static func request(_ enabled: Bool) throws -> LunaRequest {
        let state = try ProtoMessage.integer(field: 2, value: enabled ? 2 : 1)
        let payload = try ProtoMessage.blob(field: option, value: state)
        return try LunaProtocol.setPhotographyOptions(types: [UInt32(option)], nested: payload,
                                                       mode: LunaFunctionMode.normalImage.rawValue)
    }
}
