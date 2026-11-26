import Foundation
import XCTest
@testable import LunaScope

final class ConsolePhotoSaverTests: XCTestCase {
    private func makeFile(_ bytes: [UInt8], ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saver-test-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    private func response(for url: URL, statusCode: Int = 200, length: Int? = nil) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil,
            headerFields: length.map { ["Content-Length": "\($0)"] }))
    }

    @MainActor
    func testSaveJpegDngAndMp4ThroughFilePipeline() async throws {
        let library = FakeLibrary()
        let cases: [(uri: String, ext: String, bytes: [UInt8])] = [
            ("/DCIM/Camera01/IMG_1.jpg", "jpg", [0xFF, 0xD8, 0xFF, 0xE0]),
            ("/DCIM/Camera01/IMG_1.dng", "dng", [0x49, 0x49, 0x2A, 0x00]),
            ("/DCIM/Camera01/VID_1.mp4", "mp4", [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]),
        ]
        for item in cases {
            let payload = Data(item.bytes + Array(repeating: 0x11, count: 24))
            let file = try makeFile([UInt8](payload), ext: item.ext)
            let saver = ConsolePhotoSaver(library: library) { url in
                (file, try self.response(for: url, length: payload.count))
            }
            try await saver.save(uri: item.uri, host: "192.168.42.1")
        }
        XCTAssertEqual(library.saved.count, 3)
        XCTAssertEqual(library.saved.map(\.ext), ["jpg", "dng", "mp4"])
        // 头部长度按类型不同：JPEG/DNG 4 字节，MP4 8 字节，均加 24 字节正文。
        XCTAssertEqual(library.saved.map(\.bytes.count), [28, 28, 32])
        XCTAssertEqual(library.album, "LunaScope")
    }

    @MainActor
    func testSaveRejectsWrongMagicBadStatusAndForeignSources() async throws {
        let library = FakeLibrary()
        // 内容不是 JPEG：魔数拒绝，且文件不进入图库。
        let mismatched = try makeFile([0x89, 0x50, 0x4E, 0x47], ext: "jpg")
        let wrongMagic = ConsolePhotoSaver(library: library) { url in
            (mismatched, try self.response(for: url))
        }
        do {
            try await wrongMagic.save(uri: "/DCIM/a.jpg", host: "192.168.42.1")
            XCTFail("A PNG masquerading as JPEG was saved")
        } catch ConsolePhotoSaverError.downloadFailed {}
        XCTAssertTrue(library.saved.isEmpty)

        // 404。
        let missing = try makeFile([0xFF, 0xD8, 0xFF], ext: "jpg")
        let notFound = ConsolePhotoSaver(library: library) { url in
            (missing, try self.response(for: url, statusCode: 404))
        }
        do {
            try await notFound.save(uri: "/DCIM/a.jpg", host: "192.168.42.1")
            XCTFail("A missing file was accepted")
        } catch ConsolePhotoSaverError.downloadFailed {}

        // 不支持的扩展名与非法路径不发起下载。
        var downloads = 0
        let guarded = ConsolePhotoSaver(library: library) { _ in
            downloads += 1
            throw URLError(.timedOut)
        }
        for uri in ["relative.jpg", "//elsewhere/a.jpg", "/DCIM/a.lrv", "/DCIM/a.txt"] {
            do {
                try await guarded.save(uri: uri, host: "192.168.42.1")
                XCTFail("An invalid source was accepted: \(uri)")
            } catch ConsolePhotoSaverError.invalidURI {}
        }
        XCTAssertEqual(downloads, 0)
        XCTAssertTrue(library.saved.isEmpty)
    }

    @MainActor
    func testSaveReportsDeniedAddAccessWithoutWriting() async throws {
        let library = FakeLibrary()
        library.allow = false
        let file = try makeFile([0xFF, 0xD8, 0xFF, 0x01], ext: "jpg")
        let saver = ConsolePhotoSaver(library: library) { url in
            (file, try self.response(for: url))
        }
        do {
            try await saver.save(uri: "/DCIM/a.jpg", host: "192.168.42.1")
            XCTFail("Denied access still wrote to the library")
        } catch ConsolePhotoSaverError.accessDenied {}
        XCTAssertTrue(library.saved.isEmpty)
    }
}

@MainActor
private final class FakeLibrary: PhotoLibraryAccess {
    struct Saved { let ext: String; let bytes: [UInt8] }

    var allow = true
    var saved: [Saved] = []
    var album: String?

    func requestAddAccess() async -> Bool { allow }

    func add(fileAt url: URL, toAlbumNamed name: String) async throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        saved.append(Saved(ext: url.pathExtension.lowercased(), bytes: bytes))
        album = name
    }
}