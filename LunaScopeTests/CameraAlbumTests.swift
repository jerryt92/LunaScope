import LunaTransportProtocol
import UIKit
import XCTest
@testable import LunaScope

final class CameraAlbumTests: XCTestCase {
    @MainActor
    func testBusyPreviewKeepsCatalogThumbnailAndSelectionWhileRefreshWaits() async throws {
        let photo = CameraAlbumItem(file: LunaMediaFile(uri: "/DCIM/IMG_1.jpg"))
        let service = AlbumAccessStub(items: [photo])
        let model = CameraAlbumModel(camera: CameraController(), service: service)
        let cameraID = UUID()
        model.updateContext(cameraID: cameraID, connected: true, active: true)
        try await waitFor { model.hasSnapshot && !model.loading }
        defer { model.updateContext(cameraID: cameraID, connected: true, active: false) }

        model.toggleSelectionMode()
        model.toggleGroup(model.selectableIdentifiers)
        let session = try XCTUnwrap(model.previewSession(startingAt: photo))
        let dataVersion = model.dataVersion
        let before = model.cachedThumbnail(photo, in: session)
        service.shouldWait = true
        model.retry()
        var previewBusy = false
        let preview = Task {
            try await model.preview(photo, in: session) { previewBusy = $0 }
        }

        try await waitFor { previewBusy && model.loading }
        XCTAssertEqual(model.sections.flatMap(\.items), [photo])
        XCTAssertEqual(model.dataVersion, dataVersion)
        XCTAssertEqual(model.selection, [photo.id])
        XCTAssertTrue(model.cachedThumbnail(photo, in: session) === before)

        service.shouldWait = false
        guard case .image(let image) = try await preview.value else { return XCTFail("Expected a photo preview") }
        XCTAssertTrue(image === service.image)
        try await waitFor { !model.loading }
        XCTAssertFalse(previewBusy)
        XCTAssertEqual(model.selection, [photo.id])
    }

    @MainActor
    func testUncachedStorageCommitsOnlyOnSuccessAndRejectsLateResults() async throws {
        let internalImage = CameraAlbumItem(file: LunaMediaFile(uri: "/DCIM/IMG_1.jpg"))
        let cardImage = CameraAlbumItem(file: LunaMediaFile(uri: "/DCIM/IMG_2.dng"))
        let service = AlbumAccessStub(items: [internalImage])
        let model = CameraAlbumModel(camera: CameraController(), service: service)
        let cameraID = UUID()
        model.updateContext(cameraID: cameraID, connected: true, active: true)
        try await waitFor { model.hasSnapshot && !model.loading }

        service.items[.sdCard] = nil
        model.selectStorage(.sdCard)
        try await waitFor { !model.loading }
        XCTAssertEqual(model.storage, .internalStorage)
        XCTAssertEqual(model.sections.flatMap(\.items), [internalImage])

        service.items[.sdCard] = [cardImage]
        service.holdList = true
        model.retry()
        try await waitFor { service.pendingList != nil }
        XCTAssertEqual(model.storage, .internalStorage)
        XCTAssertEqual(model.sections.flatMap(\.items), [internalImage])
        let replacementID = UUID()
        model.updateContext(cameraID: replacementID, connected: true, active: false)
        service.finishList([cardImage])
        await Task.yield()
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertEqual(model.cameraID, replacementID)
    }

    @MainActor
    func testClosingOrChangingPageRejectsCancelledPreviewResult() async throws {
        let first = CameraAlbumItem(file: LunaMediaFile(uri: "/DCIM/IMG_1.jpg"))
        let second = CameraAlbumItem(file: LunaMediaFile(uri: "/DCIM/IMG_2.jpg"))
        let service = AlbumAccessStub(items: [first, second])
        let model = CameraAlbumModel(camera: CameraController(), service: service)
        let cameraID = UUID()
        model.updateContext(cameraID: cameraID, connected: true, active: true)
        try await waitFor { model.hasSnapshot && !model.loading }
        let session = try XCTUnwrap(model.previewSession(startingAt: first))
        let firstRead = Task { try await model.preview(first, in: session, onBusy: { _ in }) }
        try await waitFor { service.pendingPreview != nil }
        firstRead.cancel()
        service.finishPreview()
        do {
            _ = try await firstRead.value
            XCTFail("A cancelled page delivered its preview")
        } catch is CancellationError {}

        let secondRead = Task { try await model.preview(second, in: session, onBusy: { _ in }) }
        try await waitFor { service.pendingPreview != nil }
        model.updateContext(cameraID: cameraID, connected: false, active: true)
        model.updateContext(cameraID: cameraID, connected: true, active: true)
        try await waitFor { model.opened }
        service.finishPreview()
        do {
            _ = try await secondRead.value
            XCTFail("A retired connection delivered its preview")
        } catch CameraAlbumError.disconnected {}
        model.updateContext(cameraID: cameraID, connected: true, active: false)
    }

    @MainActor
    func testLivePhotoAndPhotoClassification() {
        let live = CameraAlbumItem(file: LunaMediaFile(
            uri: "/DCIM/LIV_20260818_184246.jpg",
            metadata: try? LunaFileMetadata(Self.metadata(width: 3840, height: 2160))
        ))
        XCTAssertEqual(live.kind, .livePhoto)
        XCTAssertTrue(live.isSelectable)

        let photo = CameraAlbumItem(file: LunaMediaFile(
            uri: "/DCIM/IMG_standard.jpg",
            metadata: try? LunaFileMetadata(Self.metadata(width: 3520, height: 2644))
        ))
        XCTAssertEqual(photo.kind, .photo)
        XCTAssertTrue(photo.isSelectable)
    }

    @MainActor
    func testDeleteRemovesItemsFromSnapshot() async throws {
        let first = CameraAlbumItem(file: LunaMediaFile(uri: "/DCIM/IMG_1.jpg"))
        let second = CameraAlbumItem(file: LunaMediaFile(uri: "/DCIM/LIV_2.jpg"))
        let service = AlbumAccessStub(items: [first, second])
        let model = CameraAlbumModel(camera: CameraController(), service: service)
        let cameraID = UUID()
        model.updateContext(cameraID: cameraID, connected: true, active: true)
        try await waitFor { model.hasSnapshot && !model.loading }

        model.toggleSelectionMode()
        model.toggleGroup([first.id])
        model.deleteSelected()
        try await waitFor { !model.deleting }
        XCTAssertEqual(model.sections.flatMap(\.items), [second])
        XCTAssertEqual(service.deletedURIs, [first.uri])
        XCTAssertFalse(model.isSelecting)
        model.updateContext(cameraID: cameraID, connected: true, active: false)
    }

    func testMotionPhotoFindsEmbeddedFtypAfterJPEG() throws {
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        jpeg.append(mp4)
        let range = try XCTUnwrap(CameraAlbumMotionPhoto.motionVideoRange(in: jpeg))
        XCTAssertEqual(Data(jpeg[range]), mp4)
    }

    func testMotionPhotoUsesMotionPhotoItemLengthNotTheFirstLength() throws {
        let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
            + Data(repeating: 0xAB, count: 20))
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        // 首个 Length 是 GainMap；MotionPhoto 的 Length 才是视频字节数。
        let xmp = """
        <x:xmpmeta><rdf:Description\
         Item:Length="8" Item:Semantic="GainMap"\
         Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="\(mp4.count)"\
        /></x:xmpmeta>
        """.data(using: .utf8)!
        // 把 XMP 塞进 APP1 会更真实，这里只验证解析器按 MotionPhoto Length 取尾部。
        jpeg.append(xmp)
        jpeg.append(mp4)
        let range = try XCTUnwrap(CameraAlbumMotionPhoto.motionVideoRange(in: jpeg))
        XCTAssertEqual(Data(jpeg[range]), mp4)
    }

    func testRAWKindClassification() {
        let raw = CameraAlbumItem(file: LunaMediaFile(
            uri: "/DCIM/IMG_0001.dng",
            metadata: try? LunaFileMetadata(Self.metadata(width: 3520, height: 2644))
        ))
        XCTAssertEqual(raw.kind, .raw)
        XCTAssertTrue(raw.isSelectable)
    }

    private static func metadata(width: Int, height: Int) throws -> Data {
        try ProtoMessage.integer(field: 7, value: 20260818184246)
            + ProtoMessage.integer(field: 9, value: 1_024_000)
            + ProtoMessage.blob(field: 19, value: try ProtoMessage.integer(field: 1, value: UInt64(width))
                + ProtoMessage.integer(field: 2, value: UInt64(height)))
            + ProtoMessage.blob(field: 26, value: try ProtoMessage.integer(field: 1, value: 3))
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try XCTUnwrap(condition() ? true : nil, "The album did not reach the expected state")
    }
}

@MainActor
private final class AlbumAccessStub: CameraAlbumAccess {
    let image = UIImage()
    var items: [CameraAlbumStorage: [CameraAlbumItem]]
    var shouldWait = false
    var holdList = false
    private(set) var deletedURIs: [String] = []
    private(set) var pendingList: CheckedContinuation<[CameraAlbumItem], Never>?
    private(set) var pendingPreview: CheckedContinuation<CameraAlbumPreviewMedia, Never>?

    init(items: [CameraAlbumItem]) {
        self.items = [.internalStorage: items]
    }

    func open() throws {}
    func close() {}

    func storages() async throws -> (available: Set<CameraAlbumStorage>, active: CameraAlbumStorage?) {
        ([.internalStorage, .sdCard], .internalStorage)
    }

    func list(_ storage: CameraAlbumStorage) async throws -> [CameraAlbumItem] {
        if holdList { return await withCheckedContinuation { pendingList = $0 } }
        while shouldWait { try await Task.sleep(for: .milliseconds(10)) }
        guard let items = items[storage] else { throw CameraAlbumError.listing }
        return items
    }

    func finishList(_ items: [CameraAlbumItem]) {
        let pending = pendingList
        pendingList = nil
        pending?.resume(returning: items)
    }

    func cachedThumbnail(_ item: CameraAlbumItem, cameraID: UUID, storage: CameraAlbumStorage) -> UIImage? { image }
    func thumbnail(_ item: CameraAlbumItem, cameraID: UUID, storage: CameraAlbumStorage) async -> UIImage? { image }

    func preview(_ item: CameraAlbumItem, onBusy: (Bool) -> Void) async throws -> CameraAlbumPreviewMedia {
        if shouldWait {
            onBusy(true)
            while shouldWait { try await Task.sleep(for: .milliseconds(10)) }
            onBusy(false)
            return .image(image)
        }
        return await withCheckedContinuation { pendingPreview = $0 }
    }

    func finishPreview() {
        let pending = pendingPreview
        pendingPreview = nil
        pending?.resume(returning: .image(image))
    }

    func delete(_ items: [CameraAlbumItem]) async throws {
        deletedURIs.append(contentsOf: items.map(\.uri))
        for storage in self.items.keys {
            self.items[storage] = self.items[storage]?.filter { item in
                !items.contains(where: { $0.id == item.id })
            }
        }
    }
}
