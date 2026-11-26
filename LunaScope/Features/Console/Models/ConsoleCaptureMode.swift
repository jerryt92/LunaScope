import LunaTransportProtocol

/// 持久化使用稳定名称，模式切换沿用 OpenCine 的相机读写定义。
enum ConsoleCaptureMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case video, pureVideo, slowMotion, timelapse, timeShift, photo, pano

    var id: Self { self }

    var native: LunaShootingMode {
        switch self {
        case .video: .video
        case .pureVideo: .pureVideo
        case .slowMotion: .slowMotion
        case .timelapse: .timelapse
        case .timeShift: .timeShift
        case .photo: .photo
        case .pano: .pano
        }
    }

    init(_ mode: LunaShootingMode) {
        switch mode {
        case .video: self = .video
        case .pureVideo: self = .pureVideo
        case .slowMotion: self = .slowMotion
        case .timelapse: self = .timelapse
        case .timeShift: self = .timeShift
        case .photo: self = .photo
        case .pano: self = .pano
        }
    }
}
