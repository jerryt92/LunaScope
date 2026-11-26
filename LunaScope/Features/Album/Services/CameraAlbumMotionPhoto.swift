import Foundation

/// 从实况照片 JPEG 中拆出尾部嵌入的运动视频（Motion Photo / MicroVideo）。
enum CameraAlbumMotionPhoto {
    /// 若 JPEG 末尾带有可播放的 MP4，写出临时文件；否则返回 nil。
    nonisolated static func extractMotionVideo(from jpegURL: URL) throws -> URL? {
        let data = try Data(contentsOf: jpegURL, options: [.mappedIfSafe])
        guard let videoRange = motionVideoRange(in: data) else { return nil }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("LunaScope-Live-\(UUID().uuidString).mp4")
        try data[videoRange].write(to: staged, options: .atomic)
        return staged
    }

    /// 定位嵌入 MP4：优先 XMP 声明的长度，其次 MotionPhoto_Data，最后在 EOI 后找 ftyp。
    nonisolated static func motionVideoRange(in data: Data) -> Range<Data.Index>? {
        if let length = videoLengthFromXMP(in: data), length > 0, length < data.count {
            let start = data.count - length
            if hasFtyp(at: start, in: data) { return start..<data.count }
            // 部分固件 Length 含 trailer：向后微调到最近的 ftyp。
            if let ftyp = findFtyp(in: data, from: start), data.count - ftyp >= 16 {
                return ftyp..<data.count
            }
        }
        if let marker = data.range(of: Data("MotionPhoto_Data".utf8)) {
            if let ftyp = findFtyp(in: data, from: marker.upperBound), hasFtyp(at: ftyp, in: data) {
                return ftyp..<data.count
            }
        }
        guard let eoi = jpegEndOfImage(in: data) else { return nil }
        if let ftyp = findFtyp(in: data, from: eoi), hasFtyp(at: ftyp, in: data) {
            return ftyp..<data.count
        }
        return nil
    }

    /// MicroVideoOffset / MotionPhoto 的 Item:Length（取视频项，避免误用首个 Length）。
    private nonisolated static func videoLengthFromXMP(in data: Data) -> Int? {
        for key in ["GCamera:MicroVideoOffset=\"", "GCamera:MicroVideoOffset='",
                    "Camera:MicroVideoOffset=\"", "Camera:MicroVideoOffset='",
                    "MicroVideoOffset=\"", "MicroVideoOffset='"] {
            if let value = integerAttribute(after: key, in: data) { return value }
        }
        // Motion Photo 1.0：Directory 里可能有 Primary / GainMap / MotionPhoto 多个 Length。
        if let motion = lengthNearMotionPhotoSemantic(in: data) { return motion }
        let lengths = allItemLengths(in: data)
        if lengths.count >= 2 { return lengths.last }
        return lengths.first
    }

    private nonisolated static func lengthNearMotionPhotoSemantic(in data: Data) -> Int? {
        let markers = ["Item:Semantic=\"MotionPhoto\"", "Item:Semantic='MotionPhoto'",
                       "Semantic=\"MotionPhoto\"", "Semantic='MotionPhoto'",
                       ">MotionPhoto</"]
        for marker in markers {
            guard let semantic = data.range(of: Data(marker.utf8)) else { continue }
            let windowStart = max(data.startIndex, semantic.lowerBound - 240)
            let windowEnd = min(data.endIndex, semantic.upperBound + 240)
            let window = data[windowStart..<windowEnd]
            if let value = integerAttribute(after: "Item:Length=\"", in: Data(window))
                ?? integerAttribute(after: "Item:Length='", in: Data(window))
                ?? integerAttribute(after: "Length=\"", in: Data(window))
                ?? integerAttribute(after: "Length='", in: Data(window)) {
                return value
            }
            if let tagged = xmlTaggedInteger("Item:Length", in: Data(window))
                ?? xmlTaggedInteger("Length", in: Data(window)) {
                return tagged
            }
        }
        return nil
    }

    private nonisolated static func allItemLengths(in data: Data) -> [Int] {
        var values: [Int] = []
        for key in ["Item:Length=\"", "Item:Length='"] {
            var search = data.startIndex
            let needle = Data(key.utf8)
            while let found = data.range(of: needle, in: search..<data.endIndex) {
                if let value = integerAttribute(after: key, in: Data(data[found.lowerBound...])) {
                    values.append(value)
                }
                search = found.upperBound
            }
        }
        // exiftool 扁平写法：Directory Item Length : 46353, 2106347
        if let flat = data.range(of: Data("Directory Item Length".utf8)) {
            let tail = data[flat.upperBound...]
            var number = 0
            var inNumber = false
            for byte in tail {
                if byte >= 0x30, byte <= 0x39 {
                    inNumber = true
                    number = number * 10 + Int(byte - 0x30)
                } else if inNumber {
                    values.append(number)
                    number = 0
                    inNumber = false
                    if byte == 0x3C || byte == 0x0A { break } // < or newline ends the list
                } else if byte == 0x3C { break }
            }
            if inNumber { values.append(number) }
        }
        return values.filter { $0 > 0 }
    }

    private nonisolated static func integerAttribute(after key: String, in data: Data) -> Int? {
        guard let range = data.range(of: Data(key.utf8)) else { return nil }
        return readDecimal(from: data, at: range.upperBound)
    }

    private nonisolated static func xmlTaggedInteger(_ tag: String, in data: Data) -> Int? {
        let open = Data("<\(tag)>".utf8)
        guard let range = data.range(of: open) else { return nil }
        return readDecimal(from: data, at: range.upperBound)
    }

    private nonisolated static func readDecimal(from data: Data, at start: Data.Index) -> Int? {
        var value = 0
        var sawDigit = false
        for byte in data[start...] {
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            value = value * 10 + Int(byte - 0x30)
            if value > data.count { return nil }
        }
        return sawDigit && value > 0 ? value : nil
    }

    private nonisolated static func jpegEndOfImage(in data: Data) -> Data.Index? {
        var index = data.startIndex
        guard data.count >= 2, data[index] == 0xFF, data[index + 1] == 0xD8 else { return nil }
        index += 2
        while index + 1 < data.endIndex {
            guard data[index] == 0xFF else {
                index += 1
                continue
            }
            let marker = data[index + 1]
            if marker == 0xD9 { return index + 2 }
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                index += 2
                continue
            }
            guard index + 3 < data.endIndex else { return nil }
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            guard length >= 2, index + 2 + length <= data.endIndex else { return nil }
            index += 2 + length
        }
        return nil
    }

    private nonisolated static func findFtyp(in data: Data, from start: Data.Index) -> Data.Index? {
        var index = start
        while index + 8 <= data.endIndex {
            if hasFtyp(at: index, in: data) { return index }
            index += 1
        }
        return nil
    }

    private nonisolated static func hasFtyp(at index: Data.Index, in data: Data) -> Bool {
        guard index + 8 <= data.endIndex else { return false }
        return data[index + 4] == 0x66
            && data[index + 5] == 0x74
            && data[index + 6] == 0x79
            && data[index + 7] == 0x70
    }
}
