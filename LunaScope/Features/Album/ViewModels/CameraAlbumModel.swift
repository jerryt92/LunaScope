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
        if self.cameraID != cameraID {
            stop(cancelSelection: true)
            self.cameraID = cameraID
            snapshots.removeAll()
            storage = .internalStorage
            sdAvailable = true
            notice = nil
            replaceSections([])
            storageRevision &+= 1
        }
        guard cameraID != nil, active, connected else {
            stop(cancelSelection: !active)
            return
        }
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
            let items = try await service.list(destination)
            try checkCatalog(request)
            let groups = await Task.detached(priority: .userInitiated) { CameraAlbumDaySection.group(items) }.value
            try checkCatalog(request)
            snapshots[destination] = groups
            show(destination, sections: groups)
            thumbnailRevision &+= 1
        } catch is CancellationError {
            return
        } catch {
            guard request == catalogRequest else { return }
            failedStorage = destination
            AppLog.error(error, context: "album.catalog")
            notice = .init(text: "\(String(localized: "album.error.load")) · \(error.localizedDescription)", isError: true)
        }
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

    private func stop(cancelSelection: Bool) {
        catalogRequest = UUID()
        failedStorage = nil
        catalogTask?.cancel()
        catalogTask = nil
        loading = false
        deleteRequest = UUID()
        deleteTask?.cancel()
        deleteTask = nil
        deleting = false
        if opened { service.close() }
        opened = false
        connectionRevision = UUID()
        if cancelSelection { self.cancelSelection() }
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
        if clearSelection { cancelSelection() }
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
