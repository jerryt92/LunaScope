import AVFoundation
import ImageIO
import LunaTransportApple
import LunaTransportProtocol
import OpenCineApple
import UIKit

enum CameraAlbumError: LocalizedError {
    case disconnected, busy, listing, unreadable

    var errorDescription: String? {
        switch self {
        case .disconnected: String(localized: "album.error.disconnected")
        case .busy: String(localized: "album.error.busy")
        case .listing: String(localized: "album.error.load")
        case .unreadable: String(localized: "album.preview.error")
        }
    }
}

enum CameraAlbumPreviewMedia {
    case image(UIImage)
    case livePhoto(still: UIImage, motion: CameraMediaFile?)
    case video(CameraMediaFile)
}

@MainActor
protocol CameraAlbumAccess: AnyObject {
    func open() throws
    func close()
    func storages() async throws -> (available: Set<CameraAlbumStorage>, active: CameraAlbumStorage?)
    func list(_ storage: CameraAlbumStorage) async throws -> [CameraAlbumItem]
    func cachedThumbnail(_ item: CameraAlbumItem, cameraID: UUID, storage: CameraAlbumStorage) -> UIImage?
    func thumbnail(_ item: CameraAlbumItem, cameraID: UUID, storage: CameraAlbumStorage) async -> UIImage?
    func preview(_ item: CameraAlbumItem, onBusy: (Bool) -> Void) async throws -> CameraAlbumPreviewMedia
    func delete(_ items: [CameraAlbumItem]) async throws
}

/// 浏览相册时独占拍摄会话。保留实况与拍摄状态，避免触发云台收起。
@MainActor
final class CameraAlbumService: CameraAlbumAccess {
    private let camera: CameraController
    private let owner = UUID()
    private let downloader = CameraMediaDownload()
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private lazy var encoder = MonitorMediaThumbnailEncoder()
    private var link: CameraController.AlbumLink?
    private var lease = UUID()
    private var lastCapture: (time: ContinuousClock.Instant, idle: Bool)?
    private var captureRequest: Task<Bool, Error>?
    private var thumbnailReads = 0

    init(camera: CameraController) {
        self.camera = camera
        thumbnailCache.totalCostLimit = 48 * 1024 * 1024
    }

    func open() throws {
        try Task.checkCancellation()
        guard link == nil else { return }
        link = try camera.acquireAlbumControl(owner)
    }

    func close() {
        lease = UUID()
        captureRequest?.cancel()
        captureRequest = nil
        lastCapture = nil
        thumbnailReads = 0
        link = nil
        camera.releaseAlbumControl(owner)
    }

    /// 存储可用性按相机回读：SD 以卡状态为准，未知清单不视为无卡。
    func storages() async throws -> (available: Set<CameraAlbumStorage>, active: CameraAlbumStorage?) {
        let operation = lease
        let link = try currentLink()
        let status = try await mediaControl(LunaProtocol.statusRequest(), link, operation, decode: LunaDeviceStatus.init(response:))
        var available: Set<CameraAlbumStorage> = [.internalStorage]
        let sdStates = status.storageList.filter { $0.location == 3 }
        if sdStates.isEmpty || sdStates.contains(where: { $0.cardState == 0 }) {
            available.insert(.sdCard)
        }
        let active = status.storage.flatMap { CameraAlbumStorage(rawValue: UInt32($0.location)) }
        return (available, active)
    }

    func list(_ storage: CameraAlbumStorage) async throws -> [CameraAlbumItem] {
        let operation = lease
        let link = try currentLink()
        var offset: UInt32 = 0
        var uris: [String] = []
        var seen: Set<String> = []
        while true {
            let page = try await mediaControl(
                LunaProtocol.fileListRequest(start: offset, location: storage.rawValue), link, operation,
                decode: LunaProtocol.fileList(response:))
            let previousCount = uris.count
            uris.append(contentsOf: page.uris.filter { seen.insert($0).inserted })
            if page.totalCount == 0 || UInt64(uris.count) >= page.totalCount { break }
            let next = UInt64(offset) + UInt64(page.uris.count)
            guard uris.count > previousCount, let offsetValue = UInt32(exactly: next) else {
                throw CameraAlbumError.listing
            }
            offset = offsetValue
        }
        var files = uris.map { LunaMediaFile(uri: $0) }
        if let metadata = try? await mediaControl(
            LunaProtocol.fileInfoListRequest(location: storage.rawValue), link, operation,
            decode: LunaProtocol.fileInfoList(response:)) {
            let byURI = Dictionary(metadata.map { ($0.uri, $0) }, uniquingKeysWith: { a, _ in a })
            files = files.map { byURI[$0.uri] ?? $0 }
        }
        try check(link, operation)
        return files.filter { !$0.isProxy }.map { file in
            CameraAlbumItem(file: file, proxyURI: file.proxyURI.flatMap { seen.contains($0) ? $0 : nil })
        }
    }

    func cachedThumbnail(_ item: CameraAlbumItem, cameraID: UUID, storage: CameraAlbumStorage) -> UIImage? {
        thumbnailCache.object(forKey: thumbnailKey(item, cameraID, storage))
    }

    func thumbnail(_ item: CameraAlbumItem, cameraID: UUID, storage: CameraAlbumStorage) async -> UIImage? {
        let key = thumbnailKey(item, cameraID, storage)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard camera.selectedCamera?.id == cameraID, let link = try? currentLink() else { return nil }
        let operation = lease
        do {
            try await waitUntilIdle(link, operation)
            while thumbnailReads >= 4 {
                try await Task.sleep(for: .milliseconds(50))
                try check(link, operation)
            }
            if let cached = thumbnailCache.object(forKey: key) { return cached }
            thumbnailReads += 1
            defer { if lease == operation { thumbnailReads -= 1 } }
            let thumb = try await mediaControl(
                LunaProtocol.fileExtraRequest(item.uri, extraType: .thumbnail), link, operation,
                decode: LunaThumbnail.init(response:))
            let jpeg = await Task.detached(priority: .utility) { [encoder] in
                encoder.jpeg(width: thumb.width, height: thumb.height, nv12: thumb.nv12)
            }.value
            try check(link, operation)
            guard let jpeg, let image = UIImage(data: jpeg) else { return nil }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? jpeg.count
            thumbnailCache.setObject(image, forKey: key, cost: cost)
            return image
        } catch {
            return nil
        }
    }

    func preview(_ item: CameraAlbumItem, onBusy: (Bool) -> Void) async throws -> CameraAlbumPreviewMedia {
        let operation = lease
        let link = try currentLink()
        if camera.processingCapture || camera.recording || camera.capture?.isSettledIdle == false {
            onBusy(true)
        }
        while true {
            try await waitUntilIdle(link, operation, onBusy: onBusy)
            do {
                let media = try await loadMedia(item, host: link.host)
                try check(link, operation)
                return media
            } catch {
                try check(link, operation)
                // A capture may begin after the status check but before the HTTP read.
                let idle = try? await captureIsIdle(link, operation, refresh: true)
                try check(link, operation)
                guard idle == false else { throw error }
                onBusy(true)
                try await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func loadMedia(_ item: CameraAlbumItem, host: String) async throws -> CameraAlbumPreviewMedia {
        switch item.kind {
        case .video:
            if let proxyURI = item.proxyURI,
               let proxy = try? await downloader.file(uri: proxyURI, host: host, allowProxy: true),
               (try? await AVURLAsset(url: proxy.url).load(.isPlayable)) == true {
                return .video(proxy)
            }
            try Task.checkCancellation()
            let original = try await downloader.file(uri: item.uri, host: host)
            guard try await AVURLAsset(url: original.url).load(.isPlayable) else { throw CameraAlbumError.unreadable }
            return .video(original)
        case .livePhoto:
            let file = try await downloader.file(uri: item.uri, host: host)
            let (decoded, motionURL) = await Task.detached(priority: .userInitiated) {
                let image = Self.decodeImage(file)
                let motion = try? CameraAlbumMotionPhoto.extractMotionVideo(from: file.url)
                return (image, motion)
            }.value
            guard let decoded else { throw CameraAlbumError.unreadable }
            // 抽出的片段必须可播，否则预览只剩静帧却无法播放。
            var motion: CameraMediaFile?
            if let motionURL {
                let candidate = CameraMediaFile(url: motionURL)
                if (try? await AVURLAsset(url: candidate.url).load(.isPlayable)) == true {
                    motion = candidate
                }
            }
            return .livePhoto(still: UIImage(cgImage: decoded), motion: motion)
        case .photo, .raw:
            let file = try await downloader.file(uri: item.uri, host: host)
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decodeImage(file)
            }.value
            guard let decoded else { throw CameraAlbumError.unreadable }
            return .image(UIImage(cgImage: decoded))
        case .other:
            throw CameraAlbumError.unreadable
        }
    }

    func delete(_ items: [CameraAlbumItem]) async throws {
        let operation = lease
        let link = try currentLink()
        for item in items {
            try await waitUntilIdle(link, operation)
            _ = try await control(try LunaProtocol.deleteFiles(item.uri), link, operation)
            try check(link, operation)
        }
    }

    private nonisolated static func decodeImage(_ file: CameraMediaFile) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary)
    }

    private func thumbnailKey(_ item: CameraAlbumItem, _ cameraID: UUID, _ storage: CameraAlbumStorage) -> NSString {
        "\(cameraID.uuidString)|\(storage.rawValue)|\(item.uri)|\(item.date?.timeIntervalSince1970 ?? 0)|\(item.byteCount ?? 0)" as NSString
    }

    private func currentLink() throws -> CameraController.AlbumLink {
        guard let link, camera.albumLinkIsCurrent(link, owner: owner) else { throw CameraAlbumError.disconnected }
        return link
    }

    private func check(_ link: CameraController.AlbumLink, _ operation: UUID) throws {
        try Task.checkCancellation()
        guard lease == operation, camera.albumLinkIsCurrent(link, owner: owner) else {
            throw CameraAlbumError.disconnected
        }
    }

    private func control(_ request: LunaRequest, _ link: CameraController.AlbumLink, _ operation: UUID) async throws -> Data {
        try check(link, operation)
        let response = try await link.session.control(request, timeout: .seconds(8))
        try check(link, operation)
        return response
    }

    private func mediaControl<Output>(
        _ request: LunaRequest, _ link: CameraController.AlbumLink, _ operation: UUID,
        decode: (Data) throws -> Output
    ) async throws -> Output {
        while true {
            try await waitUntilIdle(link, operation)
            do {
                let response = try await control(request, link, operation)
                if response.isEmpty, try await !captureIsIdle(link, operation, refresh: true) { continue }
                return try decode(response)
            } catch {
                try check(link, operation)
                guard (try? await captureIsIdle(link, operation, refresh: true)) == false else { throw error }
            }
        }
    }

    private func waitUntilIdle(
        _ link: CameraController.AlbumLink, _ operation: UUID, onBusy: (Bool) -> Void = { _ in }
    ) async throws {
        while true {
            try check(link, operation)
            let idle = try await captureIsIdle(link, operation)
            try check(link, operation)
            onBusy(!idle)
            if idle { return }
            try await Task.sleep(for: .milliseconds(750))
        }
    }

    /// Reuse the same short-lived camera status read across thumbnail, list and preview callers.
    private func captureIsIdle(
        _ link: CameraController.AlbumLink, _ operation: UUID, refresh: Bool = false
    ) async throws -> Bool {
        try check(link, operation)
        if let captureRequest { return try await captureRequest.value }
        let observedBusy = camera.processingCapture || camera.recording || camera.capture?.isSettledIdle == false
        if !refresh, let lastCapture,
           lastCapture.time.duration(to: .now) < .milliseconds(650),
           !lastCapture.idle || !observedBusy {
            return lastCapture.idle
        }
        let request = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { if self.lease == operation { self.captureRequest = nil } }
            let idle: Bool
            do {
                let data = try await self.control(LunaProtocol.captureStatusRequest, link, operation)
                guard !data.isEmpty else { throw CameraAlbumError.listing }
                idle = try LunaCaptureStatus(captureStatusResponse: data).isSettledIdle
            } catch {
                try self.check(link, operation)
                guard observedBusy else { throw error }
                idle = false
            }
            self.lastCapture = (.now, idle)
            return idle
        }
        captureRequest = request
        return try await request.value
    }
}
