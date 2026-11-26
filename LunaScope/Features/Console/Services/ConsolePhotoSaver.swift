import Foundation
import Photos

/// 系统相册写入接口，隔离 Photos 框架以便测试。
@MainActor
protocol PhotoLibraryAccess {
    /// 确认照片图库允许添加媒体。
    func requestAddAccess() async -> Bool
    /// 把已校验的媒体文件存入照片图库。权限允许时归入指定相册。
    func add(fileAt url: URL, toAlbumNamed name: String) async throws
}

enum ConsolePhotoSaverError: LocalizedError {
    case invalidURI, downloadFailed, accessDenied, albumFailed

    var errorDescription: String? {
        switch self {
        case .invalidURI, .downloadFailed: String(localized: "console.error.albumDownload")
        case .accessDenied: String(localized: "console.error.albumDenied")
        case .albumFailed: String(localized: "console.error.albumSave")
        }
    }
}

/// 从相机按地址下载原片并写入系统照片 App。
/// 支持 JPEG、DNG（16-bit RAW）与 MP4：先流式落盘，校验响应与魔数后再导入，
/// 相机地址之外或损坏的文件一律拒绝。
@MainActor
final class ConsolePhotoSaver {
    static let albumName = "LunaScope"

    private let library: PhotoLibraryAccess
    private let downloader: CameraMediaDownload

    init(library: PhotoLibraryAccess? = nil,
         download: ((URL) async throws -> (URL, URLResponse))? = nil) {
        self.library = library ?? SystemPhotoLibrary()
        downloader = CameraMediaDownload(download: download)
    }

    /// 下载并保存一个相机文件。拒绝非相机地址、非受支持扩展名与内容不符的文件。
    func save(uri: String, host: String) async throws {
        let file = try await downloader.file(uri: uri, host: host)
        try Task.checkCancellation()
        guard await library.requestAddAccess() else { throw ConsolePhotoSaverError.accessDenied }
        try Task.checkCancellation()
        do {
            try await library.add(fileAt: file.url, toAlbumNamed: Self.albumName)
        } catch is CancellationError {
            throw CancellationError()
        } catch ConsolePhotoSaverError.accessDenied {
            throw ConsolePhotoSaverError.accessDenied
        } catch {
            AppLog.error(error, context: "album.save.photos")
            throw ConsolePhotoSaverError.albumFailed
        }
    }
}

/// Owns a validated download for the lifetime of its decoder, player, or Photos import.
nonisolated final class CameraMediaFile: Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor
final class CameraMediaDownload {
    private let mediaSession: URLSession
    private let download: ((URL) async throws -> (URL, URLResponse))?

    init(download: ((URL) async throws -> (URL, URLResponse))? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        mediaSession = URLSession(configuration: configuration)
        self.download = download
    }

    func file(uri: String, host: String, allowProxy: Bool = false) async throws -> CameraMediaFile {
        let originalExtension = (uri as NSString).pathExtension.lowercased()
        let ext = allowProxy && originalExtension == "lrv" ? "mp4" : originalExtension
        guard ["jpg", "jpeg", "dng", "mp4"].contains(ext),
              let url = Self.mediaURL(uri, host: host) else { throw ConsolePhotoSaverError.invalidURI }
        let (downloaded, response) = try await fetch(url)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        try Self.validate(response: response, url: url, fileURL: downloaded, ext: ext)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("LunaScope-\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: downloaded, to: staged)
        return CameraMediaFile(url: staged)
    }

    private func fetch(_ url: URL) async throws -> (URL, URLResponse) {
        if let download { return try await download(url) }
        return try await mediaSession.download(from: url, delegate: AlbumDownloadDelegate())
    }

    private static func validate(response: URLResponse, url: URL, fileURL: URL, ext: String) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == url.host,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
              http.expectedContentLength < 0 || http.expectedContentLength == Int64(size)
        else { throw ConsolePhotoSaverError.downloadFailed }
        guard let header = try? FileHandle(forReadingFrom: fileURL).read(upToCount: 12)
        else { throw ConsolePhotoSaverError.downloadFailed }
        let matches: Bool
        switch ext {
        case "jpg", "jpeg": matches = header.starts(with: [0xFF, 0xD8, 0xFF])
        case "dng": // TIFF 头，小端 II*\0 或大端 MM\0*
            matches = header.starts(with: [0x49, 0x49, 0x2A, 0x00]) || header.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        case "mp4": matches = header.count >= 8 && Array(header[4..<8]) == Array("ftyp".utf8)
        default: matches = false
        }
        guard matches else { throw ConsolePhotoSaverError.downloadFailed }
    }

    private static func mediaURL(_ uri: String, host: String) -> URL? {
        guard uri.hasPrefix("/"), !uri.hasPrefix("//") else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = uri
        return components.url
    }
}

@MainActor
struct SystemPhotoLibrary: PhotoLibraryAccess {
    func requestAddAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return Self.canAddMedia(with: status)
    }

    func add(fileAt url: URL, toAlbumNamed name: String) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canAddMedia(with: status) else {
            throw ConsolePhotoSaverError.accessDenied
        }
        try await Self.commitImport(fileAt: url, albumName: status == .authorized ? name : nil)
    }

    private static func canAddMedia(with status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    // PhotoKit 在自己的队列执行变更闭包，闭包须在无主执行器隔离的作用域内创建。
    private nonisolated static func commitImport(fileAt url: URL, albumName: String?) async throws {
        let album = albumName.flatMap { existingAlbum(named: $0) }
        let resource: PHAssetResourceType = url.pathExtension.lowercased() == "mp4" ? .video : .photo
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: resource, fileURL: url, options: nil)

            guard let albumName, let placeholder = request.placeholderForCreatedAsset else { return }
            if let album {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            } else {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    .addAssets([placeholder] as NSArray)
            }
        }
    }

    private nonisolated static func existingAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular,
                                                       options: options).firstObject
    }
}

private nonisolated final class AlbumDownloadDelegate: NSObject, URLSessionTaskDelegate {
    // 原片仅从相机地址读取。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
