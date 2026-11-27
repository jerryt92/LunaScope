import Foundation
import LunaTransportProtocol

/// 相机存储位置：2 内置，3 SD 卡。
enum CameraAlbumStorage: UInt32, CaseIterable, Identifiable {
    case internalStorage = 2
    case sdCard = 3

    var id: Self { self }

    var title: String {
        switch self {
        case .internalStorage: String(localized: "album.storage.internal")
        case .sdCard: String(localized: "album.storage.sd")
        }
    }
}

/// 相机相册里的一个文件。支持预览与删除；`LIV_` 为实况照片。
nonisolated struct CameraAlbumItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case photo, livePhoto, raw, video, other }

    let uri: String
    let filename: String
    let date: Date?
    let byteCount: UInt64?
    let kind: Kind
    let dimensions: CameraAlbumDimensions?
    let duration: TimeInterval?
    let proxyURI: String?

    var id: String { uri }
    var isSelectable: Bool { kind == .photo || kind == .livePhoto || kind == .raw || kind == .video }

    init(file: LunaMediaFile, proxyURI: String? = nil) {
        uri = file.uri
        self.proxyURI = proxyURI
        filename = (file.uri as NSString).lastPathComponent
        date = Self.captureDate(metadata: file.metadata, filename: filename)
        byteCount = file.metadata?.fileSize
        if let width = file.metadata?.width, let height = file.metadata?.height, width > 0, height > 0 {
            dimensions = CameraAlbumDimensions(width: width, height: height)
        } else {
            dimensions = nil
        }
        duration = file.metadata?.durationMilliseconds.map { Double($0) / 1_000 }
            ?? file.metadata?.durationSeconds.map(Double.init)
        let ext = (file.uri as NSString).pathExtension.lowercased()
        let stem = filename.uppercased()
        if file.isVideo { kind = .video }
        else if stem.hasPrefix("LIV_"), ["jpg", "jpeg"].contains(ext) { kind = .livePhoto }
        else if ["jpg", "jpeg"].contains(ext) { kind = .photo }
        else if ext == "dng" { kind = .raw }
        else { kind = .other }
    }

    /// 优先用相机元数据里的本地墙钟时间；没有元数据时从文件名解析，避免大量照片被归到未知时间。
    private static func captureDate(metadata: LunaFileMetadata?, filename: String) -> Date? {
        if let components = metadata?.creationDate, let date = wallClock.date(from: components) {
            return date
        }
        return date(in: filename)
    }

    /// 文件名形如 `IMG_20260818_184246_00_001.jpg` 或 `LIV_20260818184246.jpg`。
    private static func date(in filename: String) -> Date? {
        guard let match = stampExpression.firstMatch(
            in: filename, range: NSRange(filename.startIndex..., in: filename)) else { return nil }
        let text = { (index: Int) -> String? in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let span = Range(range, in: filename) else { return nil }
            return String(filename[span])
        }
        let digits: String
        if let day = text(1), let time = text(2) { digits = day + time }
        else if let combined = text(3) { digits = combined }
        else { return nil }
        guard digits.count == 14, let stamp = Int(digits) else { return nil }
        return wallClock.date(from: DateComponents(
            year: stamp / 10_000_000_000, month: stamp / 100_000_000 % 100,
            day: stamp / 1_000_000 % 100, hour: stamp / 10_000 % 100,
            minute: stamp / 100 % 100, second: stamp % 100))
    }

    private static let wallClock: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static let stampExpression: NSRegularExpression = {
        let pattern = #"(?:_|^)(\d{8})_(\d{6})(?=_|\.)|(?:_|^)(\d{14})(?=_|\.)"#
        return try! NSRegularExpression(pattern: pattern)
    }()
}

nonisolated struct CameraAlbumDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// 按本地日期分组，新日期在前；无日期的文件归入末尾的未知日期组。
/// 组内按拍摄时间倒序，与 PhotoAssistant 照片墙的顺序一致。
nonisolated struct CameraAlbumDaySection: Identifiable, Equatable, Sendable {
    static let unknownKey = "unknown"

    let key: String
    let items: [CameraAlbumItem]

    var id: String { key }
    var yearKey: String { String(key.prefix(4)) }
    var monthKey: String { String(key.prefix(7)) }
    var itemCount: Int { items.count }
    var identifiers: [String] { items.map(\.id) }
    var selectableIdentifiers: [String] { items.filter(\.isSelectable).map(\.id) }

    func item(at index: Int) -> CameraAlbumItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// 删除指定资源后返回新分组；全部删光时返回空数组。
    func removing(_ identifiers: Set<String>) -> Self? {
        let kept = items.filter { !identifiers.contains($0.id) }
        guard !kept.isEmpty else { return nil }
        guard kept.count != items.count else { return self }
        return Self(key: key, items: kept)
    }

    static func group(_ items: [CameraAlbumItem], calendar: Calendar = .current) -> [Self] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: items) { item in
            item.date.map { formatter.string(from: $0) } ?? unknownKey
        }
        let known = grouped.keys.filter { $0 != unknownKey }.sorted(by: >)
        let ordered = grouped.keys.contains(unknownKey) ? known + [unknownKey] : known
        return ordered.map { key in
            let sorted = (grouped[key] ?? []).sorted {
                let lhs = $0.date ?? .distantPast
                let rhs = $1.date ?? .distantPast
                return lhs == rhs ? $0.uri > $1.uri : lhs > rhs
            }
            return Self(key: key, items: sorted)
        }
    }
}

enum CameraAlbumDateFormatter {
    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayTitle(for key: String) -> String {
        keyFormatter.date(from: key)?.formatted(.dateTime.day().weekday(.abbreviated)) ?? key
    }

    static func monthTitle(for key: String) -> String {
        keyFormatter.date(from: key + "-01")?.formatted(.dateTime.month(.wide)) ?? key
    }
}
