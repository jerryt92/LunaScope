import SwiftUI
import UIKit

/// 标准 UIKit 照片网格：使用系统连续多选 interaction 与原生滚动方向。
struct CameraAlbumGrid: UIViewRepresentable {
    /// Designed for iPad on Mac 将触控板捏合与滚动桥接到 UIKit 时可能触发
    /// `Missing expected nonaccelerated scroll delta` 断言，因此仅禁用网格的捏合改列数手势。
    private let isRunningOnMac = ProcessInfo.processInfo.isiOSAppOnMac
    let sections: [CameraAlbumDaySection]
    let selected: Set<String>
    let selectionMode: Bool
    let isInteractionLocked: Bool
    let dataVersion: Int
    let gridColumnCount: Int
    /// 底部滚动留白，让最后一排照片可以滑到悬浮按钮之上。
    let bottomContentInset: CGFloat
    let scrollRequest: Int
    let scrollToAssetIdentifier: String?
    let scrollToAssetRequest: Int
    let onCommitSelection: (Set<String>) -> Void
    let onPreviewSelectionCount: (Int?) -> Void
    let onColumnCountChange: (Int) -> Void
    let onToggleDateGroup: (Set<String>) -> Void
    let onPreview: (CameraAlbumItem) -> Void
    let thumbnailRevision: Int
    let cachedThumbnail: (CameraAlbumItem) -> UIImage?
    let loadThumbnail: (CameraAlbumItem) async -> UIImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let layout = PhotoGridFlowLayout(columns: gridColumnCount)
        layout.coordinator = context.coordinator

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.isMultipleTouchEnabled = true
        collectionView.showsVerticalScrollIndicator = true
        applyContentInsets(to: collectionView)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(Cell.self, forCellWithReuseIdentifier: Cell.reuseIdentifier)
        collectionView.register(
            GridSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: GridSectionHeader.reuseIdentifier
        )
        if !isRunningOnMac {
            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
            pinch.delegate = context.coordinator
            collectionView.addGestureRecognizer(pinch)
            context.coordinator.pinchGestureRecognizer = pinch
        }

        let container = PhotoGridContainerView()
        container.backgroundColor = .systemBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: container.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.collectionView = collectionView
        context.coordinator.gridColumnCount = gridColumnCount
        container.coordinator = context.coordinator
        context.coordinator.installStickyHeader(in: container)
        return container
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.finishContinuousSelection(commit: false, notify: false)
        for case let cell as Cell in coordinator.collectionView?.visibleCells ?? [] {
            cell.cancelThumbnailLoad()
        }
        coordinator.collectionView?.delegate = nil
        coordinator.collectionView?.dataSource = nil
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let collectionView = context.coordinator.collectionView else { return }
        let coordinator = context.coordinator
        let assetsChanged = coordinator.dataVersion != dataVersion
        let selectionModeChanged = coordinator.selectionMode != selectionMode
        let interactionLockChanged = coordinator.isInteractionLocked != isInteractionLocked
        let gridColumnCountChanged = coordinator.gridColumnCount != gridColumnCount
        let scrollRequestChanged = coordinator.lastScrollRequest != scrollRequest
        let scrollToAssetRequestChanged = coordinator.lastScrollToAssetRequest != scrollToAssetRequest
        // 后台图库变化时保持浏览位置：顶端浏览时展示新插入内容；浏览历史照片时
        // 固定当前资源，避免顶部新增项目把用户正在看的内容推走。
        let shouldPreserveScrollPosition = collectionView.contentOffset.y > -collectionView.adjustedContentInset.top + 1
        let scrollAnchor = assetsChanged && shouldPreserveScrollPosition
            ? coordinator.captureScrollAnchor(in: collectionView)
            : nil

        let thumbnailsChanged = coordinator.thumbnailRevision != thumbnailRevision
        coordinator.thumbnailRevision = thumbnailRevision
        coordinator.cachedThumbnail = cachedThumbnail
        coordinator.loadThumbnail = loadThumbnail
        coordinator.onCommitSelection = onCommitSelection
        coordinator.onPreviewSelectionCount = onPreviewSelectionCount
        coordinator.onColumnCountChange = onColumnCountChange
        coordinator.onToggleDateGroup = onToggleDateGroup
        coordinator.onPreview = onPreview

        // 资源重载或退出选择模式会中断系统连续多选；先提交本地结果，不能让旧的
        // SwiftUI 选择集反向覆盖手势期间的视觉状态。
        let interruptedDrag = coordinator.isContinuousSelectionActive && (assetsChanged || !selectionMode || isInteractionLocked)
        if interruptedDrag {
            coordinator.finishContinuousSelection(commit: false, notify: false)
        }

        let incrementalDataUpdate = assetsChanged
            ? coordinator.incrementalDataUpdate(to: sections)
            : nil
        if assetsChanged {
            coordinator.sections = sections
            coordinator.rebuildIndexPathCache()
            coordinator.dataVersion = dataVersion
        }
        let acceptsExternalSelection = !coordinator.isContinuousSelectionActive
        // 提交回调触发的 SwiftUI 更新可能稍后才到达；当前 update 仍携带手势开始时的
        // 旧集合，必须优先保留刚提交的本地结果。
        let shouldCommitDrag = interruptedDrag && selectionMode && !isInteractionLocked
        let externalSelection = shouldCommitDrag
            ? coordinator.selected.intersection(coordinator.selectableIdentifiers) : selected
        let selectionChanged = acceptsExternalSelection ? coordinator.selected.symmetricDifference(externalSelection) : []
        if acceptsExternalSelection {
            coordinator.selected = externalSelection
        }
        if shouldCommitDrag {
            Task { @MainActor in onCommitSelection(externalSelection) }
        }
        coordinator.selectionMode = selectionMode
        coordinator.isInteractionLocked = isInteractionLocked

        if isInteractionLocked {
            coordinator.finishContinuousSelection(commit: true)
        }

        collectionView.isUserInteractionEnabled = !isInteractionLocked
        collectionView.allowsSelection = !isInteractionLocked
        collectionView.allowsMultipleSelection = selectionMode && !isInteractionLocked
        collectionView.allowsMultipleSelectionDuringEditing = selectionMode && !isInteractionLocked
        collectionView.isEditing = selectionMode && !isInteractionLocked
        // 进入选择模式后，连续多选会占用首指；禁用捏合可让另一根手指稳定滚动网格。
        coordinator.pinchGestureRecognizer?.isEnabled = !isRunningOnMac && !selectionMode && !isInteractionLocked

        if gridColumnCountChanged {
            // 设置面板的滑块会连续发出档位变更；即时换布局可避免多段动画积压造成卡顿。
            coordinator.transitionGrid(
                collectionView,
                to: gridColumnCount,
                notifiesColumnCountChange: false,
                animated: false
            )
        }

        if let incrementalDataUpdate {
            coordinator.apply(
                incrementalDataUpdate,
                in: collectionView,
                preserving: scrollAnchor
            )
        } else if assetsChanged {
            coordinator.reloadData(in: collectionView, preserving: scrollAnchor)
        } else if selectionModeChanged || interactionLockChanged {
            coordinator.refreshVisibleCells(identifiers: Set(coordinator.identifiers))
            coordinator.refreshDateHeaders()
        } else if !selectionChanged.isEmpty {
            coordinator.refreshVisibleCells(identifiers: selectionChanged)
        }

        if thumbnailsChanged {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath) as? Cell else { continue }
                coordinator.configure(cell, at: indexPath)
            }
        }

        if assetsChanged {
            coordinator.synchronizeAllNativeSelection()
        } else if !selectionChanged.isEmpty {
            coordinator.synchronizeNativeSelection(changedIdentifiers: selectionChanged)
        }
        // 拖选预览会令 SwiftUI 每帧重绘工具栏；日期栏的全选判定可能遍历整年资源，
        // 因而只在最终集合提交后刷新，网格单元格仍由 UIKit 实时更新。
        if !coordinator.isContinuousSelectionActive {
            coordinator.refreshDateHeaderSelectionState()
            coordinator.refreshStickyHeader(animated: false)
        }
        if scrollToAssetRequestChanged, let scrollToAssetIdentifier {
            coordinator.scrollToAsset(withIdentifier: scrollToAssetIdentifier)
        } else if scrollRequestChanged {
            coordinator.scrollToNativeOrigin()
        }
        if collectionView.contentInset.bottom != bottomContentInset {
            applyContentInsets(to: collectionView)
        }
        coordinator.lastScrollRequest = scrollRequest
        coordinator.lastScrollToAssetRequest = scrollToAssetRequest
    }

    /// 顶部避开固定日期栏，底部留出悬浮按钮高度，滚动指示条与内容对齐。
    private func applyContentInsets(to collectionView: UICollectionView) {
        collectionView.contentInset.top = GridSectionHeader.stickyHeight
        collectionView.contentInset.bottom = bottomContentInset
        collectionView.verticalScrollIndicatorInsets.top = GridSectionHeader.stickyHeight
        collectionView.verticalScrollIndicatorInsets.bottom = bottomContentInset
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
        struct IncrementalDataUpdate {
            let insertedIndexPaths: [IndexPath]
            let deletedIndexPaths: [IndexPath]
        }

        weak var collectionView: UICollectionView?
        var sections: [CameraAlbumDaySection] = []
        var identifiers: [String] = []
        var dataVersion = -1
        var selected: Set<String> = []
        var selectionMode = false
        var isInteractionLocked = false
        static let columnRange = 3...8
        var thumbnailRevision = 0
        var cachedThumbnail: ((CameraAlbumItem) -> UIImage?)?
        var loadThumbnail: ((CameraAlbumItem) async -> UIImage?)?
        private(set) var selectableIdentifiers: Set<String> = []
        var onCommitSelection: ((Set<String>) -> Void)?
        var onPreviewSelectionCount: ((Int?) -> Void)?
        var onColumnCountChange: ((Int) -> Void)?
        var onToggleDateGroup: ((Set<String>) -> Void)?
        var onPreview: ((CameraAlbumItem) -> Void)?
        var lastScrollRequest = -1
        var lastScrollToAssetRequest = -1
        private var pinchStartColumns = 3
        var gridColumnCount = 3
        weak var pinchGestureRecognizer: UIPinchGestureRecognizer?
        private var pinchTargetColumns = 3
        private var isGridLayoutTransitioning = false
        private var queuedColumnCount: Int?
        private var pinchAnchor: (indexPath: IndexPath, offsetInCellY: CGFloat, viewportY: CGFloat)?
        /// 旋转或宽度变化期间，用最上方可见照片把视口钉住。
        private var rotationAnchor: (identifier: String, offsetFromViewportTop: CGFloat)?
        private let stickyHeader = GridSectionHeader(frame: .zero)
        private var displayedStickySection: Int?
        private var indexPathsByIdentifier: [String: IndexPath] = [:]
        private var dateGroupRanges: [String: Range<Int>] = [:]
        private var dateGroupIdentifiers: [String: Set<String>] = [:]
        private var continuousSelectionActive = false
        private var previewDisplayLink: CADisplayLink?
        private var previewCountNeedsPublishing = false

        var isContinuousSelectionActive: Bool { continuousSelectionActive }

        deinit { previewDisplayLink?.invalidate() }

        /// 将日期栏钉在容器顶部，作为 collection view 的兄弟视图，滚动只更新文案。
        func installStickyHeader(in container: UIView) {
            stickyHeader.translatesAutoresizingMaskIntoConstraints = false
            stickyHeader.isSticky = true
            container.addSubview(stickyHeader)
            NSLayoutConstraint.activate([
                stickyHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stickyHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stickyHeader.topAnchor.constraint(equalTo: container.topAnchor),
                stickyHeader.heightAnchor.constraint(equalToConstant: GridSectionHeader.stickyHeight),
            ])
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int {
            sections.count
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            sections.indices.contains(section) ? sections[section].itemCount : 0
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Cell.reuseIdentifier, for: indexPath) as! Cell
            configure(cell, at: indexPath)
            return cell
        }

        func configure(_ cell: Cell, at indexPath: IndexPath) {
            guard let item = item(at: indexPath) else { return }
            cell.configure(item, selected: selected.contains(item.id), selectionMode: selectionMode,
                           thumbnailRevision: thumbnailRevision, cachedThumbnail: cachedThumbnail,
                           loadThumbnail: loadThumbnail)
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt path: IndexPath) {
            if let cell = cell as? Cell { configure(cell, at: path) }
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt path: IndexPath) {
            (cell as? Cell)?.cancelThumbnailLoad()
        }

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            guard !isInteractionLocked, let item = item(at: indexPath) else { return false }
            return item.isSelectable
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard !isInteractionLocked else { return }
            guard let item = item(at: indexPath) else { return }
            guard selectionMode else {
                collectionView.deselectItem(at: indexPath, animated: false)
                if item.isSelectable { onPreview?(item) }
                return
            }
            guard item.isSelectable else {
                collectionView.deselectItem(at: indexPath, animated: false)
                return
            }
            let identifier = item.id
            selected.insert(identifier)
            if continuousSelectionActive {
                schedulePreviewCount()
            } else {
                onCommitSelection?(selected)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard !isInteractionLocked, selectionMode, let item = item(at: indexPath) else { return }
            let identifier = item.id
            selected.remove(identifier)
            if continuousSelectionActive {
                schedulePreviewCount()
            } else {
                onCommitSelection?(selected)
            }
        }

        /// Apple 的标准连续多选入口。垂直滚动网格支持沿受限轴的单指连续选择。
        func collectionView(
            _ collectionView: UICollectionView,
            shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) -> Bool {
            selectionMode && !isInteractionLocked && item(at: indexPath)?.isSelectable == true
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) {
            guard selectionMode, !isInteractionLocked else { return }
            continuousSelectionActive = true
            schedulePreviewCount()
        }

        func collectionViewDidEndMultipleSelectionInteraction(_ collectionView: UICollectionView) {
            finishContinuousSelection(commit: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            guard kind == UICollectionView.elementKindSectionHeader,
                  indexPath.section > 0,
                  sections.indices.contains(indexPath.section) else {
                return UICollectionReusableView()
            }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: GridSectionHeader.reuseIdentifier,
                for: indexPath
            ) as! GridSectionHeader
            configure(header, for: indexPath.section)
            return header
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> CGSize {
            guard sections.indices.contains(section) else { return .zero }
            // 第一天由顶部悬浮栏显示，避免开头重复日期。
            guard section > 0 else { return .zero }
            if sections[section].key.isEmpty {
                return CGSize(width: collectionView.bounds.width, height: GridSectionHeader.height(forRows: 1))
            }
            let rowCount = 1 + (startsMonth(at: section) ? 1 : 0) + (startsYear(at: section) ? 1 : 0)
            return CGSize(width: collectionView.bounds.width, height: GridSectionHeader.height(forRows: rowCount))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            refreshStickyHeader(animated: true)
        }

        func scrollViewDidLayoutSubviews(_ scrollView: UIScrollView) {
            refreshStickyHeader(animated: false)
        }

        func rebuildIndexPathCache() {
            // 分组下标不变也可能已更换日期或资源数量，不能复用旧日期栏内容。
            displayedStickySection = nil
            dateGroupRanges.removeAll(keepingCapacity: true)
            dateGroupIdentifiers.removeAll(keepingCapacity: true)
            var start = 0
            for section in sections {
                let end = start + section.itemCount
                for key in [section.yearKey, section.monthKey, section.key] {
                    dateGroupRanges[key] = (dateGroupRanges[key]?.lowerBound ?? start)..<end
                }
                start = end
            }
            identifiers = sections.flatMap(\.identifiers)
            selectableIdentifiers = Set(sections.flatMap(\.selectableIdentifiers))
            indexPathsByIdentifier = [:]
            for (sectionIndex, section) in sections.enumerated() {
                for (itemIndex, identifier) in section.identifiers.enumerated() {
                    indexPathsByIdentifier[identifier] = IndexPath(item: itemIndex, section: sectionIndex)
                }
            }
        }

        /// 仅当日期分组不变、旧资源的相对顺序不变时，使用原生批量更新。
        /// 图库在现有日期下插入新资源时不会回收所有可见 cell；跨日
        /// 移动、排序切换等复杂结构变化则安全回退到 reloadData。
        func incrementalDataUpdate(to newSections: [CameraAlbumDaySection]) -> IncrementalDataUpdate? {
            guard sections.count == newSections.count,
                  zip(sections, newSections).allSatisfy({ $0.key == $1.key }) else {
                return nil
            }

            var insertedIndexPaths: [IndexPath] = []
            var deletedIndexPaths: [IndexPath] = []
            for (sectionIndex, pair) in zip(sections, newSections).enumerated() {
                let oldIdentifiers = pair.0.identifiers
                let newIdentifiers = pair.1.identifiers
                let oldSet = Set(oldIdentifiers)
                let newSet = Set(newIdentifiers)

                // 位置或元数据变化时让可见单元格重新配置。
                guard pair.0.items.filter({ newSet.contains($0.id) }) == pair.1.items.filter({ oldSet.contains($0.id) }) else {
                    return nil
                }

                insertedIndexPaths.append(contentsOf: newIdentifiers.enumerated().compactMap { index, identifier in
                    oldSet.contains(identifier) ? nil : IndexPath(item: index, section: sectionIndex)
                })
                deletedIndexPaths.append(contentsOf: oldIdentifiers.enumerated().compactMap { index, identifier in
                    newSet.contains(identifier) ? nil : IndexPath(item: index, section: sectionIndex)
                })
            }
            guard !insertedIndexPaths.isEmpty || !deletedIndexPaths.isEmpty else { return nil }
            return IncrementalDataUpdate(
                insertedIndexPaths: insertedIndexPaths,
                deletedIndexPaths: deletedIndexPaths
            )
        }

        func apply(
            _ update: IncrementalDataUpdate,
            in collectionView: UICollectionView,
            preserving anchor: (identifier: String, offsetFromViewportTop: CGFloat)?
        ) {
            collectionView.performBatchUpdates {
                if !update.deletedIndexPaths.isEmpty {
                    collectionView.deleteItems(at: update.deletedIndexPaths)
                }
                if !update.insertedIndexPaths.isEmpty {
                    collectionView.insertItems(at: update.insertedIndexPaths)
                }
            } completion: { [weak self, weak collectionView] _ in
                guard let self, let collectionView else { return }
                self.restoreScrollAnchor(anchor, in: collectionView)
                self.refreshDateHeaders()
            }
        }

        /// 数据重载只协调实际选中的项目，不为只读网格逐张同步数万张照片的选择态。
        func synchronizeAllNativeSelection() {
            guard let collectionView else { return }
            let native = Set(collectionView.indexPathsForSelectedItems ?? [])
            let desired = Set(selected.compactMap { indexPathsByIdentifier[$0] })
            for path in native.subtracting(desired) { collectionView.deselectItem(at: path, animated: false) }
            for path in desired.subtracting(native) { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
        }

        /// 仅同步外部状态变更的标识符。连续拖选由 UICollectionView 自己维护原生选中态，
        /// 不能在每个回调中遍历整个图库并反向同步。
        func synchronizeNativeSelection(changedIdentifiers: Set<String>) {
            guard let collectionView else { return }
            let nativeSelection = Set(collectionView.indexPathsForSelectedItems ?? [])
            for identifier in changedIdentifiers {
                guard let indexPath = indexPathsByIdentifier[identifier] else { continue }
                if selected.contains(identifier) {
                    if !nativeSelection.contains(indexPath) {
                        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                    }
                } else if nativeSelection.contains(indexPath) {
                    collectionView.deselectItem(at: indexPath, animated: false)
                }
            }
        }

        func finishContinuousSelection(commit: Bool, notify: Bool = true) {
            guard continuousSelectionActive else { return }
            continuousSelectionActive = false
            previewCountNeedsPublishing = false
            previewDisplayLink?.invalidate()
            previewDisplayLink = nil
            guard notify else { return }
            if commit {
                onCommitSelection?(selected)
            } else {
                onPreviewSelectionCount?(nil)
            }
        }

        private func schedulePreviewCount() {
            previewCountNeedsPublishing = true
            guard previewDisplayLink == nil else { return }
            let displayLink = CADisplayLink(target: self, selector: #selector(publishPreviewCount))
            displayLink.add(to: .main, forMode: .common)
            previewDisplayLink = displayLink
        }

        @objc private func publishPreviewCount() {
            guard continuousSelectionActive else { return }
            guard previewCountNeedsPublishing else { return }
            previewCountNeedsPublishing = false
            onPreviewSelectionCount?(selected.count)
        }

        func refreshVisibleCells(identifiers changed: Set<String>) {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let item = item(at: indexPath),
                      changed.contains(item.id),
                      let cell = collectionView.cellForItem(at: indexPath) as? Cell
                else { continue }
                cell.setSelected(selected.contains(item.id), selectionMode: selectionMode)
            }
            collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
                .compactMap { $0 as? GridSectionHeader }
                .forEach { $0.refreshSelectionState(selected) }
            refreshStickyHeader(animated: false)
        }

        /// 原生连续多选会先修改 Coordinator 内部选择集，再由 SwiftUI 回传同一结果；
        /// 因而不能只依赖集合差异刷新日期栏的全选状态。
        func refreshDateHeaderSelectionState() {
            guard let collectionView else { return }
            collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
                .compactMap { $0 as? GridSectionHeader }
                .forEach { $0.refreshSelectionState(selected) }
            stickyHeader.refreshSelectionState(selected)
        }

        /// 只更新已实例化的日期栏，避免重载可见缩略图。
        func refreshDateHeaders() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
                guard let header = collectionView.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader,
                    at: indexPath
                ) as? GridSectionHeader
                else { continue }
                configure(header, for: indexPath.section)
            }
            displayedStickySection = nil
            refreshStickyHeader(animated: false)
        }

        func refreshStickyHeader(animated: Bool) {
            guard let collectionView, !sections.isEmpty else {
                displayedStickySection = nil
                stickyHeader.isHidden = true
                return
            }
            guard let sectionIndex = activeSectionIndex(in: collectionView) else { return }
            stickyHeader.isHidden = false
            guard displayedStickySection != sectionIndex else { return }
            displayedStickySection = sectionIndex
            configure(
                stickyHeader,
                for: sectionIndex,
                isSticky: true,
                animated: animated && stickyHeader.window != nil
            )
        }

        private func configure(
            _ header: GridSectionHeader,
            for sectionIndex: Int,
            isSticky: Bool = false,
            animated: Bool = false
        ) {
            guard sections.indices.contains(sectionIndex) else { return }
            let section = sections[sectionIndex]
            let yearKey = section.yearKey
            let monthKey = section.monthKey
            let hasDate = section.key != CameraAlbumDaySection.unknownKey
            header.configure(
                year: hasDate && (isSticky || startsYear(at: sectionIndex)) ? dateGroup(yearKey, title: yearKey) : nil,
                month: hasDate && (isSticky || startsMonth(at: sectionIndex))
                    ? dateGroup(monthKey, title: CameraAlbumDateFormatter.monthTitle(for: monthKey))
                    : nil,
                day: dateGroup(section.key, title: hasDate
                    ? CameraAlbumDateFormatter.dayTitle(for: section.key) : String(localized: "album.date.unknown")),
                selected: selected,
                isSelectionMode: selectionMode,
                onToggle: { [weak self] in self?.onToggleDateGroup?($0) },
                animated: animated
            )
        }

        private func dateGroup(_ key: String, title: String) -> GridSectionHeader.DateGroup {
            guard let range = dateGroupRanges[key] else { return .init(title: title, count: 0, identifiers: []) }
            guard selectionMode else { return .init(title: title, count: range.count, identifiers: []) }
            if let cached = dateGroupIdentifiers[key] {
                return .init(title: title, count: range.count, identifiers: cached)
            }
            let identifiers = Set(identifiers[range].filter(selectableIdentifiers.contains))
            dateGroupIdentifiers[key] = identifiers
            return .init(title: title, count: range.count, identifiers: identifiers)
        }

        private func activeSectionIndex(in collectionView: UICollectionView) -> Int? {
            let anchorY = max(0, collectionView.contentOffset.y + GridSectionHeader.stickyHeight)
            let probe = CGRect(x: 0, y: anchorY, width: collectionView.bounds.width, height: collectionView.bounds.height)
            let cells = collectionView.collectionViewLayout.layoutAttributesForElements(in: probe)?
                .filter { $0.representedElementCategory == .cell }
                .sorted { $0.frame.minY < $1.frame.minY }
            return cells?.first?.indexPath.section ?? sections.indices.first
        }

        private func startsYear(at section: Int) -> Bool {
            section == 0 || sections[section - 1].yearKey != sections[section].yearKey
        }

        private func startsMonth(at section: Int) -> Bool {
            section == 0 || sections[section - 1].monthKey != sections[section].monthKey
        }

        private func item(at indexPath: IndexPath) -> CameraAlbumItem? {
            guard sections.indices.contains(indexPath.section) else { return nil }
            return sections[indexPath.section].item(at: indexPath.item)
        }

        func scrollToNativeOrigin() {
            guard let collectionView else { return }
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(
                CGPoint(x: -collectionView.adjustedContentInset.left, y: -collectionView.adjustedContentInset.top),
                animated: false
            )
        }

        func scrollToAsset(withIdentifier identifier: String) {
            guard let collectionView,
                  let indexPath = indexPathsByIdentifier[identifier] else { return }
            collectionView.layoutIfNeeded()
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
            // 已在可见内容区域内就保持用户原来的浏览位置；固定日期栏覆盖的高度
            // 不计入可见区域，避免目标仅被标题遮住时被误判为可见。
            let visibleContentFrame = CGRect(
                x: collectionView.contentOffset.x,
                y: collectionView.contentOffset.y + GridSectionHeader.stickyHeight,
                width: collectionView.bounds.width,
                height: max(collectionView.bounds.height - GridSectionHeader.stickyHeight, 0)
            )
            guard !attributes.frame.intersects(visibleContentFrame) else {
                refreshStickyHeader(animated: false)
                return
            }
            let scrollPosition: UICollectionView.ScrollPosition = attributes.frame.minY > visibleContentFrame.maxY
                ? .bottom
                : .top
            collectionView.scrollToItem(at: indexPath, at: scrollPosition, animated: true)
            refreshStickyHeader(animated: false)
        }

        /// 宽度变化前记录当前最上方可见照片及其相对视口顶部的偏移。
        func prepareToPreserveTopVisibleItem() {
            guard rotationAnchor == nil, let collectionView else { return }
            rotationAnchor = captureTopVisibleAnchor(in: collectionView)
        }

        /// 尺寸变化的布局事务结束后清掉锚点。偏移已由 targetContentOffset 在同一趟布局里对齐，
        /// 转场完成后再 setContentOffset 会让网格在动画末尾跳一下。
        func finishBoundsSizeChange() {
            if let collectionView, rotationAnchor != nil {
                restoreScrollAnchor(rotationAnchor, in: collectionView)
            }
            rotationAnchor = nil
            (collectionView?.collectionViewLayout as? PhotoGridFlowLayout)?.endBoundsSizeChange()
        }

        /// 布局在旋转事务内询问目标偏移时，用已捕获的上方锚点给出新 contentOffset。
        func contentOffsetForPreservedTopVisibleItem(proposed: CGPoint) -> CGPoint? {
            guard let collectionView else { return nil }
            return contentOffset(preserving: rotationAnchor, proposedX: proposed.x, in: collectionView)
        }

        /// 钉住固定日期栏下方、当前最靠上的那张可见照片。
        private func captureTopVisibleAnchor(
            in collectionView: UICollectionView
        ) -> (identifier: String, offsetFromViewportTop: CGFloat)? {
            let visibleTop = collectionView.contentOffset.y + GridSectionHeader.stickyHeight
            let topItem = collectionView.indexPathsForVisibleItems
                .compactMap { indexPath -> (attributes: UICollectionViewLayoutAttributes, item: CameraAlbumItem)? in
                    guard sections.indices.contains(indexPath.section),
                          let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                          attributes.frame.maxY > visibleTop,
                          let item = item(at: indexPath) else { return nil }
                    return (attributes, item)
                }
                .min { lhs, rhs in
                    if abs(lhs.attributes.frame.minY - rhs.attributes.frame.minY) > 0.5 {
                        return lhs.attributes.frame.minY < rhs.attributes.frame.minY
                    }
                    return lhs.attributes.frame.minX < rhs.attributes.frame.minX
                }
            if let topItem {
                return (topItem.item.id, topItem.attributes.frame.minY - collectionView.contentOffset.y)
            }
            return captureScrollAnchor(in: collectionView)
        }

        /// 重载前捕获锚点：数据顺序中第一个可见资源的标识符及其相对视口顶部的偏移。
        /// 数据变化后据此将同一资源恢复到原来的屏幕位置，新增行自然出现在视口上方。
        func captureScrollAnchor(in collectionView: UICollectionView) -> (identifier: String, offsetFromViewportTop: CGFloat)? {
            let firstVisibleIndexPath = collectionView.indexPathsForVisibleItems
                .filter { sections.indices.contains($0.section) }
                .min { lhs, rhs in
                    lhs.section == rhs.section ? lhs.item < rhs.item : lhs.section < rhs.section
                }
            guard let firstVisibleIndexPath,
                  let attributes = collectionView.layoutAttributesForItem(at: firstVisibleIndexPath),
                  let item = item(at: firstVisibleIndexPath) else { return nil }
            return (item.id, attributes.frame.minY - collectionView.contentOffset.y)
        }

        /// 重载数据并按锚点尽力恢复滚动位置；锚点资源不存在（被删除）时静默保持默认位置。
        func reloadData(in collectionView: UICollectionView, preserving anchor: (identifier: String, offsetFromViewportTop: CGFloat)?) {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            restoreScrollAnchor(anchor, in: collectionView)
        }

        private func restoreScrollAnchor(
            _ anchor: (identifier: String, offsetFromViewportTop: CGFloat)?,
            in collectionView: UICollectionView
        ) {
            guard let offset = contentOffset(
                preserving: anchor,
                proposedX: collectionView.contentOffset.x,
                in: collectionView
            ) else { return }
            collectionView.setContentOffset(offset, animated: false)
        }

        /// 按锚点照片的新布局位置，换算出应保持最上方对齐的 contentOffset。
        private func contentOffset(
            preserving anchor: (identifier: String, offsetFromViewportTop: CGFloat)?,
            proposedX: CGFloat,
            in collectionView: UICollectionView
        ) -> CGPoint? {
            guard let anchor,
                  let indexPath = indexPathsByIdentifier[anchor.identifier],
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
            let proposedY = attributes.frame.minY - anchor.offsetFromViewportTop
            let minY = -collectionView.adjustedContentInset.top
            let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
            return CGPoint(x: proposedX, y: min(max(proposedY, minY), maxY))
        }

        /// 缩小手势（两指收拢）显示更多项目，张开则显示更少项目；范围固定在 3–8 列。
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard !selectionMode, !isInteractionLocked, let collectionView else { return }

            switch gesture.state {
            case .began:
                pinchStartColumns = gridColumnCount
                pinchTargetColumns = gridColumnCount
                pinchAnchor = capturePinchAnchor(in: collectionView, at: gesture.location(in: collectionView))
            case .changed:
                // 单次捏合只跨越一个离散缩放级别，避免幅度较大的手势跳过中间网格。
                if gesture.scale < 0.86 {
                    pinchTargetColumns = min(pinchStartColumns + 1, Self.columnRange.upperBound)
                } else if gesture.scale > 1.18 {
                    pinchTargetColumns = max(pinchStartColumns - 1, Self.columnRange.lowerBound)
                } else {
                    pinchTargetColumns = pinchStartColumns
                }
            case .ended:
                guard pinchTargetColumns != gridColumnCount else { return }
                transitionGrid(collectionView, to: pinchTargetColumns)
            case .cancelled, .failed:
                pinchTargetColumns = gridColumnCount
                pinchAnchor = nil
            default: break
            }
        }

        /// 在手势结束后才使用 UIKit 原生布局动画完成离散列数切换，避免手势期间反复变更布局。
        func transitionGrid(
            _ collectionView: UICollectionView,
            to columns: Int,
            notifiesColumnCountChange: Bool = true,
            animated: Bool = true
        ) {
            if isGridLayoutTransitioning {
                queuedColumnCount = columns
                return
            }
            isGridLayoutTransitioning = true
            gridColumnCount = columns
            if notifiesColumnCountChange {
                onColumnCountChange?(columns)
            }
            let anchor = pinchAnchor
            pinchAnchor = nil
            let layout = PhotoGridFlowLayout(columns: columns)
            layout.coordinator = self
            collectionView.setCollectionViewLayout(layout, animated: animated) { [weak self, weak collectionView] _ in
                guard let self, let collectionView else { return }
                self.restorePinchAnchor(anchor, in: collectionView)
                self.isGridLayoutTransitioning = false
                guard let queuedColumns = self.queuedColumnCount else { return }
                self.queuedColumnCount = nil
                guard queuedColumns != self.gridColumnCount else { return }
                self.transitionGrid(
                    collectionView,
                    to: queuedColumns,
                    notifiesColumnCountChange: notifiesColumnCountChange,
                    animated: animated
                )
            }
        }

        /// 将手势中心绑定到当前单元中的相对位置；列数变化后该内容点仍留在原屏幕位置。
        private func capturePinchAnchor(
            in collectionView: UICollectionView,
            at location: CGPoint
        ) -> (indexPath: IndexPath, offsetInCellY: CGFloat, viewportY: CGFloat)? {
            let indexPath = collectionView.indexPathForItem(at: location)
                ?? collectionView.collectionViewLayout.layoutAttributesForElements(
                    in: CGRect(
                        x: 0,
                        y: location.y + collectionView.contentOffset.y - 1,
                        width: collectionView.bounds.width,
                        height: 2
                    )
                )?.first(where: { $0.representedElementCategory == .cell })?.indexPath
                ?? collectionView.indexPathsForVisibleItems.min { lhs, rhs in
                    let lhsDistance = abs((collectionView.layoutAttributesForItem(at: lhs)?.center.y ?? .greatestFiniteMagnitude)
                        - (location.y + collectionView.contentOffset.y))
                    let rhsDistance = abs((collectionView.layoutAttributesForItem(at: rhs)?.center.y ?? .greatestFiniteMagnitude)
                        - (location.y + collectionView.contentOffset.y))
                    return lhsDistance < rhsDistance
                }
            guard let indexPath,
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
            let contentY = location.y + collectionView.contentOffset.y
            return (indexPath, contentY - attributes.frame.minY, location.y)
        }

        private func restorePinchAnchor(
            _ anchor: (indexPath: IndexPath, offsetInCellY: CGFloat, viewportY: CGFloat)?,
            in collectionView: UICollectionView
        ) {
            guard let anchor,
                  let attributes = collectionView.layoutAttributesForItem(at: anchor.indexPath) else { return }
            let proposedY = attributes.frame.minY + anchor.offsetInCellY - anchor.viewportY
            let minY = -collectionView.adjustedContentInset.top
            let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: min(max(proposedY, minY), maxY)),
                animated: false
            )
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 缩放期间不让 UICollectionView 的 pan 同时改变 contentOffset，
            // 这样位于内容中部时不会因滚动与布局动画竞争而抖动。
            false
        }

    }

    /// 承载网格与置顶日期栏的容器。日期栏是 collection view 的兄弟视图，
    /// 不会被 cell 插入、supplementary 布局或 contentOffset 带着滚动。
    final class PhotoGridContainerView: UIView {
        weak var coordinator: Coordinator?
        private var lastLaidOutSize: CGSize = .zero

        override func layoutSubviews() {
            let sizeChanged = lastLaidOutSize != .zero && lastLaidOutSize != bounds.size
            if sizeChanged {
                coordinator?.prepareToPreserveTopVisibleItem()
                // 旋转时系统会动画 bounds；同步完成新布局，避免 cell 在转场中淡入淡出。
                UIView.performWithoutAnimation {
                    super.layoutSubviews()
                    coordinator?.collectionView?.layoutIfNeeded()
                    coordinator?.finishBoundsSizeChange()
                }
            } else {
                super.layoutSubviews()
            }
            lastLaidOutSize = bounds.size
        }
    }

    /// 将单元尺寸绑定到 collection view 的实时 bounds，而不是 delegate 回调时可能过期的布局缓存。
    /// 这样横竖屏切换完成后一定会按当前宽度恢复三列。
    final class PhotoGridFlowLayout: UICollectionViewFlowLayout {
        weak var coordinator: Coordinator?
        /// 宽度正在变化时禁止插入/删除动画，否则新出现的格子会从透明淡入，看起来像闪一下。
        private var isApplyingBoundsSizeChange = false
        var columns = 3 {
            didSet {
                guard columns != oldValue else { return }
                invalidateLayout()
            }
        }

        init(columns: Int) {
            super.init()
            self.columns = columns
            minimumLineSpacing = 3
            minimumInteritemSpacing = 3
            sectionInset = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func endBoundsSizeChange() {
            isApplyingBoundsSizeChange = false
        }

        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
            guard let collectionView else { return true }
            guard newBounds.size != collectionView.bounds.size else { return false }
            isApplyingBoundsSizeChange = true
            coordinator?.prepareToPreserveTopVisibleItem()
            return true
        }

        override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
            let context = super.invalidationContext(forBoundsChange: newBounds)
            if let flowContext = context as? UICollectionViewFlowLayoutInvalidationContext,
               let collectionView,
               newBounds.size != collectionView.bounds.size {
                flowContext.invalidateFlowLayoutDelegateMetrics = true
            }
            return context
        }

        override func prepare(forAnimatedBoundsChange oldBounds: CGRect) {
            isApplyingBoundsSizeChange = true
            super.prepare(forAnimatedBoundsChange: oldBounds)
        }

        override func finalizeAnimatedBoundsChange() {
            super.finalizeAnimatedBoundsChange()
            isApplyingBoundsSizeChange = false
        }

        override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
            coordinator?.contentOffsetForPreservedTopVisibleItem(proposed: proposedContentOffset)
                ?? super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
        }

        override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            if isApplyingBoundsSizeChange {
                return layoutAttributesForItem(at: itemIndexPath)
            }
            return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        }

        override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            if isApplyingBoundsSizeChange {
                return layoutAttributesForItem(at: itemIndexPath)
            }
            return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
        }

        override func initialLayoutAttributesForAppearingSupplementaryElement(
            ofKind elementKind: String,
            at elementIndexPath: IndexPath
        ) -> UICollectionViewLayoutAttributes? {
            if isApplyingBoundsSizeChange {
                return layoutAttributesForSupplementaryView(ofKind: elementKind, at: elementIndexPath)
            }
            return super.initialLayoutAttributesForAppearingSupplementaryElement(ofKind: elementKind, at: elementIndexPath)
        }

        override func finalLayoutAttributesForDisappearingSupplementaryElement(
            ofKind elementKind: String,
            at elementIndexPath: IndexPath
        ) -> UICollectionViewLayoutAttributes? {
            if isApplyingBoundsSizeChange {
                return layoutAttributesForSupplementaryView(ofKind: elementKind, at: elementIndexPath)
            }
            return super.finalLayoutAttributesForDisappearingSupplementaryElement(ofKind: elementKind, at: elementIndexPath)
        }

        override func prepare() {
            guard let collectionView else {
                super.prepare()
                return
            }

            let horizontalInsets = sectionInset.left + sectionInset.right
            let columnCount = CGFloat(columns)
            let horizontalSpacing = minimumInteritemSpacing * (columnCount - 1)
            let side = floor(max(0, collectionView.bounds.width - horizontalInsets - horizontalSpacing) / columnCount)
            let size = CGSize(width: side, height: side)
            if itemSize != size {
                itemSize = size
            }
            super.prepare()
        }
    }

    /// 日期栏同时用于置顶和网格分隔，内容只在跨日、跨月、跨年时更新。
    final class GridSectionHeader: UICollectionReusableView {
        struct DateGroup {
            let title: String
            let count: Int
            let identifiers: Set<String>
        }

        static let reuseIdentifier = "GridSectionHeader"
        private static let rowHeight: CGFloat = 32
        private static var dividerHeight: CGFloat { 1 / max(2, UITraitCollection.current.displayScale) }
        static var stickyHeight: CGFloat { height(forRows: 3) }

        static func height(forRows count: Int) -> CGFloat {
            rowHeight * CGFloat(count) + dividerHeight * CGFloat(count - 1)
        }

        private let materialBackground = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        private let yearRow = DateRow(textStyle: .headline)
        private let monthRow = DateRow(textStyle: .subheadline)
        private let dayRow = DateRow(textStyle: .subheadline)
        private let yearDivider = UIView()
        private let monthDivider = UIView()
        var isSticky = false {
            didSet { updateAppearance() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear

            materialBackground.translatesAutoresizingMaskIntoConstraints = false
            materialBackground.isUserInteractionEnabled = false
            addSubview(materialBackground)
            NSLayoutConstraint.activate([
                materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
                materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
                materialBackground.topAnchor.constraint(equalTo: topAnchor),
                materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            let stack = UIStackView(arrangedSubviews: [yearRow, yearDivider, monthRow, monthDivider, dayRow])
            stack.axis = .vertical
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            for divider in [yearDivider, monthDivider] {
                divider.backgroundColor = .separator
                let height = divider.heightAnchor.constraint(equalToConstant: Self.dividerHeight)
                height.priority = .defaultHigh
                height.isActive = true
            }
            updateAppearance()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// 置顶实例不走 collection view 复用布局，忽略布局属性，避免被带着滚动。
        override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
            guard !isSticky else { return }
            super.apply(layoutAttributes)
        }

        func configure(
            year: DateGroup?,
            month: DateGroup?,
            day: DateGroup,
            selected: Set<String>,
            isSelectionMode: Bool,
            onToggle: @escaping (Set<String>) -> Void,
            animated: Bool
        ) {
            yearDivider.isHidden = year == nil
            monthDivider.isHidden = month == nil
            yearRow.configure(year, selected: selected, isSelectionMode: isSelectionMode, onToggle: onToggle, animated: false)
            monthRow.configure(month, selected: selected, isSelectionMode: isSelectionMode, onToggle: onToggle, animated: animated)
            dayRow.configure(day, selected: selected, isSelectionMode: isSelectionMode, onToggle: onToggle, animated: animated)
        }

        func refreshSelectionState(_ selected: Set<String>) {
            yearRow.refreshSelectionState(selected)
            monthRow.refreshSelectionState(selected)
            dayRow.refreshSelectionState(selected)
        }

        private func updateAppearance() {
            if isSticky {
                // 置顶栏保持半透明材质，让底下照片轻微透出。
                materialBackground.effect = UIBlurEffect(style: .systemChromeMaterial)
                materialBackground.alpha = 0.92
                materialBackground.contentView.backgroundColor = .clear
                layer.shadowOpacity = 0.06
                layer.shadowRadius = 6
            } else {
                // 网格内 section 日期栏使用更实的背景，提升滚动时的可读性。
                materialBackground.effect = UIBlurEffect(style: .systemThickMaterial)
                materialBackground.alpha = 1
                materialBackground.contentView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.78)
                layer.shadowOpacity = 0
                layer.shadowRadius = 0
            }
            layer.borderColor = UIColor.separator.cgColor
            layer.borderWidth = 1 / max(2, traitCollection.displayScale)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 2)
        }

        private final class DateRow: UIStackView {
            private let label = UILabel()
            private let countLabel = UILabel()
            private let button = UIButton(type: .system)
            private var identifiers: Set<String> = []
            private var onToggle: ((Set<String>) -> Void)?
            private var isGroupSelected: Bool?

            init(textStyle: UIFont.TextStyle) {
                super.init(frame: .zero)
                axis = .horizontal
                alignment = .center
                spacing = 12

                label.font = .preferredFont(forTextStyle: textStyle)
                label.textColor = .label
                label.adjustsFontForContentSizeCategory = true
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                countLabel.font = .monospacedDigitSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .regular
                )
                countLabel.textColor = .secondaryLabel
                countLabel.adjustsFontForContentSizeCategory = true

                addArrangedSubview(label)
                addArrangedSubview(countLabel)
                addArrangedSubview(UIView())
                addArrangedSubview(button)
                button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
                let height = heightAnchor.constraint(equalToConstant: GridSectionHeader.rowHeight)
                height.priority = .defaultHigh
                height.isActive = true
            }

            required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

            func configure(
                _ group: DateGroup?,
                selected: Set<String>,
                isSelectionMode: Bool,
                onToggle: @escaping (Set<String>) -> Void,
                animated: Bool
            ) {
                isHidden = group == nil
                identifiers = group?.identifiers ?? []
                self.onToggle = onToggle
                button.isHidden = !isSelectionMode
                guard let group else { return }

                button.accessibilityLabel = group.title
                button.isEnabled = !identifiers.isEmpty
                refreshSelectionState(selected)
                let updateText = { [self] in
                    label.text = group.title
                    countLabel.text = String(localized: "album.count \(String(group.count))")
                }
                if animated, label.text != nil, label.text != group.title {
                    UIView.transition(with: self, duration: 0.16, options: .transitionCrossDissolve, animations: updateText)
                } else {
                    updateText()
                }
            }

            func refreshSelectionState(_ selected: Set<String>) {
                guard !isHidden, !button.isHidden else { return }
                let isSelected = !identifiers.isEmpty && identifiers.isSubset(of: selected)
                guard isGroupSelected != isSelected else { return }
                isGroupSelected = isSelected

                var configuration = UIButton.Configuration.plain()
                configuration.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                configuration.baseForegroundColor = isSelected ? .systemBlue : .secondaryLabel
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
                button.configuration = configuration
                if isSelected {
                    button.accessibilityTraits.insert(.selected)
                } else {
                    button.accessibilityTraits.remove(.selected)
                }
            }

            @objc private func toggle() { onToggle?(identifiers) }
        }
    }

    final class Cell: UICollectionViewCell {
        static let reuseIdentifier = "cell"

        let image = UIImageView()
        let mark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        private let rawPhotoMark = UIImageView(image: CameraAlbumRawBadge.thumbnail)
        private let livePhotoMark = UIImageView(image: UIImage(systemName: "livephoto"))
        let videoMark = UIImageView(image: UIImage(systemName: "video.fill"))
        let videoDurationLabel = UILabel()
        private var thumbnailTask: Task<Void, Never>?
        private var thumbnailRevision: Int?
        private var isSelectionMode = false
        private var representedAssetIdentifier: String?

        override var isSelected: Bool {
            didSet { setSelected(isSelected, selectionMode: isSelectionMode) }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.frame = bounds
            image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(image)
            contentView.layer.borderColor = UIColor.systemBlue.cgColor
            mark.tintColor = .systemBlue
            mark.frame = CGRect(x: frame.width - 28, y: 4, width: 24, height: 24)
            mark.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
            contentView.addSubview(mark)

            rawPhotoMark.center = CGPoint(x: 6 + rawPhotoMark.bounds.width / 2, y: frame.height - 15)
            rawPhotoMark.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]
            rawPhotoMark.isAccessibilityElement = true
            rawPhotoMark.accessibilityLabel = String(localized: CameraAlbumRawBadge.accessibilityTitle)
            contentView.addSubview(rawPhotoMark)

            livePhotoMark.tintColor = .white
            livePhotoMark.contentMode = .scaleAspectFit
            livePhotoMark.frame = CGRect(x: 4, y: frame.height - 26, width: 20, height: 20)
            livePhotoMark.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]
            livePhotoMark.layer.shadowColor = UIColor.black.cgColor
            livePhotoMark.layer.shadowOpacity = 0.65
            livePhotoMark.layer.shadowRadius = 2
            livePhotoMark.layer.shadowOffset = .zero
            livePhotoMark.isAccessibilityElement = true
            livePhotoMark.accessibilityLabel = String(localized: "album.badge.live")
            contentView.addSubview(livePhotoMark)

            videoMark.tintColor = .white
            videoMark.contentMode = .scaleAspectFit
            videoMark.frame = CGRect(x: frame.width - 28, y: frame.height - 26, width: 22, height: 22)
            videoMark.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin]
            videoMark.layer.shadowColor = UIColor.black.cgColor
            videoMark.layer.shadowOpacity = 0.65
            videoMark.layer.shadowRadius = 2
            videoMark.layer.shadowOffset = .zero
            contentView.addSubview(videoMark)

            videoDurationLabel.textColor = .white
            videoDurationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            videoDurationLabel.textAlignment = .right
            videoDurationLabel.frame = CGRect(x: 4, y: frame.height - 25, width: max(0, frame.width - 34), height: 20)
            videoDurationLabel.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            videoDurationLabel.layer.shadowColor = UIColor.black.cgColor
            videoDurationLabel.layer.shadowOpacity = 0.8
            videoDurationLabel.layer.shadowRadius = 2
            videoDurationLabel.layer.shadowOffset = .zero
            contentView.addSubview(videoDurationLabel)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func prepareForReuse() {
            super.prepareForReuse()
            cancelThumbnailLoad()
            representedAssetIdentifier = nil
            image.image = nil
        }

        func cancelThumbnailLoad() {
            thumbnailTask?.cancel()
            thumbnailTask = nil
            thumbnailRevision = nil
        }

        func configure(
            _ item: CameraAlbumItem, selected: Bool, selectionMode: Bool, thumbnailRevision: Int,
            cachedThumbnail: ((CameraAlbumItem) -> UIImage?)?,
            loadThumbnail: ((CameraAlbumItem) async -> UIImage?)?
        ) {
            isAccessibilityElement = true
            accessibilityLabel = item.filename
            accessibilityIdentifier = "album.cell"
            if item.isSelectable { accessibilityTraits.insert(.button) }
            else { accessibilityTraits.remove(.button) }
            contentView.backgroundColor = .secondarySystemBackground
            rawPhotoMark.isHidden = item.kind != .raw
            livePhotoMark.isHidden = item.kind != .livePhoto
            videoMark.isHidden = item.kind != .video
            videoDurationLabel.text = item.duration.map(Self.durationText(for:))
            videoDurationLabel.isHidden = videoMark.isHidden || videoDurationLabel.text == nil
            setSelected(selected, selectionMode: selectionMode)

            if representedAssetIdentifier != item.id {
                cancelThumbnailLoad()
                representedAssetIdentifier = item.id
                image.image = cachedThumbnail?(item)
            }
            guard image.image == nil, self.thumbnailRevision != thumbnailRevision, let loadThumbnail else { return }
            self.thumbnailRevision = thumbnailRevision
            thumbnailTask?.cancel()
            thumbnailTask = Task { [weak self] in
                let thumbnail = await loadThumbnail(item)
                guard !Task.isCancelled, let self, self.representedAssetIdentifier == item.id else { return }
                if let thumbnail { self.image.image = thumbnail }
            }
        }

        func setSelected(_ selected: Bool, selectionMode: Bool) {
            isSelectionMode = selectionMode
            let showsSelection = selectionMode && selected
            mark.isHidden = !showsSelection
            if showsSelection { accessibilityTraits.insert(.selected) }
            else { accessibilityTraits.remove(.selected) }
            contentView.layer.borderWidth = showsSelection ? 3 : 0
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]) {
                self.image.transform = showsSelection ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
        }

        private nonisolated static func durationText(for duration: TimeInterval) -> String {
            let totalSeconds = max(0, Int(duration.rounded(.down)))
            let seconds = totalSeconds % 60
            let minutes = (totalSeconds / 60) % 60
            let hours = totalSeconds / 3_600
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            }
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
