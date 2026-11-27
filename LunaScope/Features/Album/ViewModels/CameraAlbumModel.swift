import Observation
import UIKit

@MainActor
@Observable
final class CameraAlbumModel {
    let camera: CameraController
    private let service: any CameraAlbumAccess
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private var catalogRequest = UUID()
    @ObservationIgnored private var deleteRequest = UUID()
    @ObservationIgnored private var connectionRevision = UUID()
    @ObservationIgnored private var failedStorage: CameraAlbumStorage?
    /// 同名 DNG 不进网格，删除对应 JPG 时一起删掉。
    @ObservationIgnored private var rawCompanions: [String: CameraAlbumItem] = [:]
    /// 相册页是否正在显示。删除进行中离开页面时不中断，结束后再释放相机。
    @ObservationIgnored private var browsing = false

    private(set) var cameraID: UUID?
    private(set) var storage: CameraAlbumStorage = .internalStorage
    private(set) var sdAvailable = true
    private var snapshots: [CameraAlbumStorage: [CameraAlbumDaySection]] = [:]
    private(set) var sections: [CameraAlbumDaySection] = []
    private(set) var dataVersion = 0
    private(set) var storageRevision = 0
    private(set) var thumbnailRevision = 0
    private(set) var selectableIdentifiers: Set<String> = []
    private(set) var loading = false
    private(set) var deleting = false
    private(set) var deletedCount = 0
    private(set) var deleteTotal = 0
    private(set) var opened = false
    private(set) var notice: CameraController.Notice?
    private(set) var selection: Set<String> = []
    private(set) var isSelecting = false
    private(set) var selectionPreviewCount: Int?

    init(camera: CameraController, service: (any CameraAlbumAccess)? = nil) {
        self.camera = camera
        self.service = service ?? CameraAlbumService(camera: camera)
    }

    var hasSnapshot: Bool { snapshots[storage] != nil }
    var itemCount: Int { sections.reduce(0) { $0 + $1.itemCount } }
    var isAllSelected: Bool { !selectableIdentifiers.isEmpty && selection == selectableIdentifiers }

    func updateContext(cameraID: UUID?, connected: Bool, active: Bool) {
        browsing = active && cameraID != nil && connected
        if self.cameraID != cameraID {
            stop(cancelSelection: true)
            self.cameraID = cameraID
            snapshots.removeAll()
            rawCompanions = [:]
            storage = .internalStorage
            sdAvailable = true
            notice = nil
            replaceSections([])
            storageRevision &+= 1
        }
        guard cameraID != nil, connected else {
            stop(cancelSelection: !active)
            return
        }
        guard active else {
            // 切到拍摄、设置等页面时，已开始的删除继续；只停掉列表刷新。
            if deleting { pauseCatalog() }
            else { stop(cancelSelection: true) }
            return
        }
        guard !deleting else { return }
        retry()
    }

    func retry() {
        guard !loading, !deleting, cameraID != nil else { return }
        load(failedStorage ?? storage, readStorageStatus: !opened)
    }

    func selectStorage(_ target: CameraAlbumStorage) {
        guard opened, !deleting, target != storage, sdAvailable || target == .internalStorage else { return }
        if let cached = snapshots[target] {
            show(target, sections: cached)
        }
        load(target)
    }

    private func load(_ target: CameraAlbumStorage, readStorageStatus: Bool = false) {
        catalogTask?.cancel()
        let request = UUID()
        catalogRequest = request
        failedStorage = nil
        loading = true
        notice = nil
        catalogTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCatalog(target, readStorageStatus: readStorageStatus, request: request)
        }
    }

    private func loadCatalog(_ target: CameraAlbumStorage, readStorageStatus: Bool, request: UUID) async {
        defer {
            if request == catalogRequest {
                loading = false
                catalogTask = nil
            }
        }
        var destination = target
        do {
            while !opened {
                try checkCatalog(request)
                do {
                    try service.open()
                    opened = true
                    thumbnailRevision &+= 1
                } catch CameraAlbumError.busy {
                    try await Task.sleep(for: .milliseconds(750))
                }
            }
            if readStorageStatus {
                let stores = try await service.storages()
                try checkCatalog(request)
                sdAvailable = stores.available.contains(.sdCard)
                if !hasSnapshot || (storage == .sdCard && !sdAvailable) {
                    let reported = stores.active ?? .internalStorage
                    destination = stores.available.contains(reported) ? reported : .internalStorage
                }
            }
            var collected: [CameraAlbumItem] = []
            try await service.list(destination) { page in
                try self.checkCatalog(request)
                collected.append(contentsOf: page)
                try await self.publish(collected, storage: destination, request: request)
            } onCatalog: { items in
                try self.checkCatalog(request)
                collected = items
                try await self.publish(items, storage: destination, request: request)
            }
            try checkCatalog(request)
            if snapshots[destination] == nil {
                snapshots[destination] = []
                show(destination, sections: [])
            }
        } catch is CancellationError {
            return
        } catch {
            guard request == catalogRequest else { return }
            failedStorage = destination
            AppLog.error(error, context: "album.catalog")
            notice = .init(text: "\(String(localized: "album.error.load")) · \(error.localizedDescription)", isError: true)
        }
    }

    /// 把当前已收到的文件分组并显示。全选状态下，新到的页继续保持全选。
    private func publish(_ items: [CameraAlbumItem], storage: CameraAlbumStorage, request: UUID) async throws {
        try checkCatalog(request)
        let keepAll = isSelecting && isAllSelected
        let visible = items.filter { $0.kind != .raw }
        rawCompanions = Self.pairedRawFiles(in: items)
        guard !visible.isEmpty else { return }
        let groups = await Task.detached(priority: .userInitiated) {
            CameraAlbumDaySection.group(visible)
        }.value
        try checkCatalog(request)
        rawCompanions = Self.pairedRawFiles(in: items)
        snapshots[storage] = groups
        let switchingStorage = storage != self.storage
        show(storage, sections: groups)
        if keepAll, !switchingStorage { selection = selectableIdentifiers }
    }

    /// 网格只保留 JPG、实况和视频。RAW 按同目录同名挂到 JPG 上，供删除时一并移除。
    private static func pairedRawFiles(in items: [CameraAlbumItem]) -> [String: CameraAlbumItem] {
        var rawByStem: [String: CameraAlbumItem] = [:]
        for item in items where item.kind == .raw {
            rawByStem[mediaStem(item.uri)] = item
        }
        var companions: [String: CameraAlbumItem] = [:]
        for item in items where item.kind == .photo || item.kind == .livePhoto {
            if let raw = rawByStem[mediaStem(item.uri)] {
                companions[item.id] = raw
            }
        }
        return companions
    }

    /// 目录加去掉扩展名的文件名，用来配对 JPG 与 DNG。
    private static func mediaStem(_ uri: String) -> String {
        let path = uri as NSString
        return path.deletingLastPathComponent + "/" + path.deletingPathExtension.lowercased()
    }

    private func checkCatalog(_ request: UUID) throws {
        try Task.checkCancellation()
        guard request == catalogRequest else { throw CancellationError() }
    }

    private func show(_ storage: CameraAlbumStorage, sections: [CameraAlbumDaySection]) {
        if storage != self.storage {
            self.storage = storage
            cancelSelection()
            storageRevision &+= 1
        }
        replaceSections(sections)
    }

    private func replaceSections(_ sections: [CameraAlbumDaySection]) {
        guard self.sections != sections else { return }
        self.sections = sections
        selectableIdentifiers = Set(sections.flatMap(\.selectableIdentifiers))
        selection.formIntersection(selectableIdentifiers)
        dataVersion &+= 1
    }

    /// 停掉目录刷新，但保留删除任务和相册会话。
    private func pauseCatalog() {
        catalogRequest = UUID()
        failedStorage = nil
        catalogTask?.cancel()
        catalogTask = nil
        loading = false
    }

    private func stop(cancelSelection: Bool) {
        pauseCatalog()
        deleteRequest = UUID()
        deleteTask?.cancel()
        deleteTask = nil
        deleting = false
        camera.setDeletingMedia(false)
        releaseAlbum()
        if cancelSelection { self.cancelSelection() }
    }

    private func releaseAlbum() {
        if opened { service.close() }
        opened = false
        connectionRevision = UUID()
    }

    func thumbnail(_ item: CameraAlbumItem, cameraID: UUID?, storage: CameraAlbumStorage) async -> UIImage? {
        guard let cameraID, self.cameraID == cameraID else { return nil }
        return await service.thumbnail(item, cameraID: cameraID, storage: storage)
    }

    func cachedThumbnail(_ item: CameraAlbumItem, in session: CameraAlbumPreviewSession) -> UIImage? {
        service.cachedThumbnail(item, cameraID: session.cameraID, storage: session.storage)
    }

    func cachedThumbnail(_ item: CameraAlbumItem, cameraID: UUID?, storage: CameraAlbumStorage) -> UIImage? {
        guard let cameraID else { return nil }
        return service.cachedThumbnail(item, cameraID: cameraID, storage: storage)
    }

    func previewSession(startingAt item: CameraAlbumItem) -> CameraAlbumPreviewSession? {
        guard let cameraID else { return nil }
        let items = sections.flatMap(\.items).filter(\.isSelectable)
        guard items.contains(where: { $0.id == item.id }) else { return nil }
        return CameraAlbumPreviewSession(cameraID: cameraID, storage: storage, items: items, initialID: item.id)
    }

    func preview(
        _ item: CameraAlbumItem, in session: CameraAlbumPreviewSession, onBusy: (Bool) -> Void
    ) async throws -> CameraAlbumPreviewMedia {
        guard cameraID == session.cameraID, storage == session.storage, opened else { throw CameraAlbumError.disconnected }
        let revision = connectionRevision
        let media = try await service.preview(item) { busy in
            guard !Task.isCancelled, revision == connectionRevision, storage == session.storage else { return }
            onBusy(busy)
        }
        try Task.checkCancellation()
        guard revision == connectionRevision, storage == session.storage, opened else { throw CameraAlbumError.disconnected }
        return media
    }

    func toggleSelectionMode() {
        guard !deleting else { return }
        if isSelecting { cancelSelection() }
        else if !selectableIdentifiers.isEmpty { isSelecting = true }
    }

    func commitSelection(_ identifiers: Set<String>) {
        guard isSelecting, !deleting else { return }
        selection = identifiers.intersection(selectableIdentifiers)
        selectionPreviewCount = nil
    }

    func previewSelectionCount(_ count: Int?) {
        guard isSelecting, !deleting, selectionPreviewCount != count else { return }
        selectionPreviewCount = count
    }

    func toggleGroup(_ identifiers: Set<String>) {
        guard isSelecting, !deleting else { return }
        selectionPreviewCount = nil
        let targets = identifiers.intersection(selectableIdentifiers)
        if targets.isSubset(of: selection) { selection.subtract(targets) }
        else { selection.formUnion(targets) }
    }

    private func cancelSelection() {
        isSelecting = false
        selection = []
        selectionPreviewCount = nil
    }

    func deleteSelected() {
        let selected = selection
        let items = sections.flatMap(\.items).filter { selected.contains($0.id) }
        delete(items, clearSelection: true)
    }

    func delete(_ item: CameraAlbumItem, in session: CameraAlbumPreviewSession) {
        guard session.cameraID == cameraID, session.storage == storage, item.isSelectable else { return }
        delete([item], clearSelection: false)
    }

    private func delete(_ items: [CameraAlbumItem], clearSelection: Bool) {
        guard opened, !deleting, !items.isEmpty else { return }
        let request = UUID()
        deleteRequest = request
        deleting = true
        deletedCount = 0
        deleteTotal = items.count
        notice = nil
        camera.setDeletingMedia(true)
        deleteTask = Task { [weak self] in
            guard let self else { return }
            await self.deleteFiles(items, clearSelection: clearSelection, request: request)
        }
    }

    private func deleteFiles(_ items: [CameraAlbumItem], clearSelection: Bool, request: UUID) async {
        var failures = 0
        var removed: Set<String> = []
        for item in items {
            do {
                try Task.checkCancellation()
                if let raw = rawCompanions[item.id] {
                    try await service.delete([raw])
                    rawCompanions[item.id] = nil
                }
                try await service.delete([item])
                try Task.checkCancellation()
                guard request == deleteRequest else { return }
                deletedCount += 1
                removed.insert(item.id)
            } catch is CancellationError {
                break
            } catch {
                guard request == deleteRequest else { return }
                failures += 1
                AppLog.error(error, context: "album.delete")
            }
        }
        guard request == deleteRequest else { return }
        if !removed.isEmpty {
            removeLocally(removed)
        }
        deleteTask = nil
        deleting = false
        camera.setDeletingMedia(false)
        if clearSelection { cancelSelection() }
        // 删除开始后切走页面，完成后释放相机，避免拍摄页一直被相册占用。
        if !browsing { releaseAlbum() }
        // 成功只反映在列表消失，不挂持久「已删除」提示；仅失败才提示。
        if failures > 0 {
            notice = .init(
                text: String(localized: "album.deletePartial \(String(deletedCount)) \(String(failures))"),
                isError: true)
        }
    }

    /// 删除成功后就地更新快照，避免整表重载。
    private func removeLocally(_ identifiers: Set<String>) {
        let updated = sections.compactMap { $0.removing(identifiers) }
        snapshots[storage] = updated
        replaceSections(updated)
    }
}

struct CameraAlbumPreviewSession: Identifiable {
    let id = UUID()
    let cameraID: UUID
    let storage: CameraAlbumStorage
    let items: [CameraAlbumItem]
    let initialID: String
}
