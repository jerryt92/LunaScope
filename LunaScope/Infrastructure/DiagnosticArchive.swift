import Foundation

/// 诊断仅有两个小型文本条目，使用 ZIP 的存储模式以便系统和桌面工具直接解包。
nonisolated enum DiagnosticArchive {
    static func zip(_ files: [(String, Data)]) -> Data {
        var content = Data()
        var directory = Data()
        for (filename, data) in files {
            let name = Data(filename.utf8)
            let offset = UInt32(content.count)
            let size = UInt32(data.count)
            let crc = checksum(data)
            content.put(UInt32(0x04034b50))
            content.put(UInt16(20))
            content.put(UInt16(0))
            content.put(UInt16(0))
            content.put(UInt16(0))
            content.put(UInt16(0x21))
            content.put(crc)
            content.put(size)
            content.put(size)
            content.put(UInt16(name.count))
            content.put(UInt16(0))
            content.append(name)
            content.append(data)

            directory.put(UInt32(0x02014b50))
            directory.put(UInt16(20))
            directory.put(UInt16(20))
            directory.put(UInt16(0))
            directory.put(UInt16(0))
            directory.put(UInt16(0))
            directory.put(UInt16(0x21))
            directory.put(crc)
            directory.put(size)
            directory.put(size)
            directory.put(UInt16(name.count))
            directory.put(UInt16(0))
            directory.put(UInt16(0))
            directory.put(UInt16(0))
            directory.put(UInt16(0))
            directory.put(UInt32(0))
            directory.put(offset)
            directory.append(name)
        }
        let offset = UInt32(content.count)
        content.append(directory)
        content.put(UInt32(0x06054b50))
        content.put(UInt16(0))
        content.put(UInt16(0))
        content.put(UInt16(files.count))
        content.put(UInt16(files.count))
        content.put(UInt32(directory.count))
        content.put(offset)
        content.put(UInt16(0))
        return content
    }

    private static let table = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in
            value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320
        }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crc, byte in
            (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 255)]
        }
    }
}

private extension Data {
    nonisolated mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
