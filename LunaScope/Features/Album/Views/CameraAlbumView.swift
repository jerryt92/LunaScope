import LunaTransportApple
import SwiftUI

struct CameraAlbumView: View {
    @State private var model: CameraAlbumModel
    let isActive: Bool
    let openConnection: () -> Void

    @AppStorage("photo.grid.columnCount") private var columnCount = 5
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var preview: CameraAlbumPreviewSession?
    @State private var returnTarget: (id: String, storageRevision: Int)?
    @State private var returnRequest = 0
    @State private var videoMuted = true
    @State private var confirmsDelete = false

    init(camera: CameraController, isActive: Bool, openConnection: @escaping () -> Void) {
        _model = State(initialValue: CameraAlbumModel(camera: camera))
        self.isActive = isActive
        self.openConnection = openConnection
    }

    private struct Context: Equatable {
        let cameraID: UUID?
        let connected: Bool
        let active: Bool
    }

    private var context: Context {
        .init(cameraID: model.camera.selectedCamera?.id, connected: model.camera.connected, active: isActive)
    }

    private var floatingSize: CGFloat { verticalSizeClass == .compact ? 44 : 52 }
    private var showsFloatingControls: Bool { model.isSelecting || model.deleting || model.notice != nil }
    private var gridInset: CGFloat {
        guard showsFloatingControls else { return 16 }
        return floatingSize + (verticalSizeClass == .compact ? 38 : 34)
    }

    var body: some View {
        Group {
            if isActive {
                if context.connected || model.hasSnapshot {
                    album
                } else {
                    ContentUnavailableView {
                        Label("console.state.idle", systemImage: "camera.badge.ellipsis")
                    } actions: {
                        Button("feature.connection.title", action: openConnection)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("album.connection.open")
                    }
                }
            }
        }
        .onChange(of: context, initial: true) { old, new in
            model.updateContext(cameraID: new.cameraID, connected: new.connected, active: new.active)
            if old.cameraID != new.cameraID || !new.active { preview = nil }
        }
        .fullScreenCover(item: $preview) { session in
            CameraAlbumPreview(model: model, session: session, videoMuted: $videoMuted) { id in
                returnTarget = (id, model.storageRevision)
                returnRequest &+= 1
                preview = nil
            }
        }
        .alert("album.delete.confirmTitle", isPresented: $confirmsDelete) {
            Button("album.delete", role: .destructive, action: model.deleteSelected)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("album.delete.confirmMessage \(String(model.selection.count))")
        }
    }

    private var album: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .bottom) {
                content
                if showsFloatingControls {
                    VStack(spacing: 10) {
                        if model.deleting {
                            Text("album.deleting.media")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                                .accessibilityIdentifier("album.deleting.media")
                        }
                        if let notice = model.notice { feedback(notice) }
                        if model.isSelecting || model.deleting { deleteButton }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("album.storage", selection: Binding(get: { model.storage }, set: model.selectStorage)) {
                ForEach(CameraAlbumStorage.allCases) { storage in
                    Text(storage.title).tag(storage)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 174)
            .disabled(model.deleting || (model.loading && !model.hasSnapshot) || !model.opened || !model.sdAvailable)
            .accessibilityIdentifier("album.storage")

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text("album.count \(String(model.itemCount))")
                if model.isSelecting {
                    Text("album.selected \(String(model.selectionPreviewCount ?? model.selection.count))")
                        .accessibilityIdentifier("album.selection.count")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()

            HStack(spacing: 12) {
                if model.isSelecting {
                    Button(model.isAllSelected ? "album.deselectAll" : "album.selectAll") {
                        model.toggleGroup(model.selectableIdentifiers)
                    }
                    .disabled(model.selectableIdentifiers.isEmpty || model.deleting)
                    .accessibilityIdentifier("album.selectAll")
                }

                Button(model.isSelecting ? "album.cancelSelection" : "album.select", action: model.toggleSelectionMode)
                    .disabled(model.deleting || (!model.isSelecting && model.selectableIdentifiers.isEmpty))
                    .accessibilityIdentifier("album.selection.mode")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .fixedSize()
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 16)
        .overlay(alignment: .bottomLeading) {
            if !model.sdAvailable {
                Text("album.storage.noSD")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.sections.isEmpty {
            let cameraID = model.cameraID
            let storage = model.storage
            CameraAlbumGrid(
                sections: model.sections,
                selected: model.selection,
                selectionMode: model.isSelecting,
                isInteractionLocked: model.deleting || preview != nil,
                dataVersion: model.dataVersion,
                gridColumnCount: min(max(columnCount, 3), 8),
                bottomContentInset: gridInset,
                scrollRequest: model.storageRevision,
                scrollToAssetIdentifier: returnTarget?.storageRevision == model.storageRevision ? returnTarget?.id : nil,
                scrollToAssetRequest: returnRequest,
                onCommitSelection: model.commitSelection,
                onPreviewSelectionCount: model.previewSelectionCount,
                onColumnCountChange: { columnCount = $0 },
                onToggleDateGroup: model.toggleGroup,
                onPreview: { preview = model.previewSession(startingAt: $0) },
                thumbnailRevision: model.thumbnailRevision,
                cachedThumbnail: { model.cachedThumbnail($0, cameraID: cameraID, storage: storage) },
                loadThumbnail: { await model.thumbnail($0, cameraID: cameraID, storage: storage) }
            )
            .id(model.storageRevision)
            .ignoresSafeArea(.container, edges: .bottom)
        } else if !model.hasSnapshot && (model.loading || model.notice == nil) {
            VStack(spacing: 10) {
                ProgressView()
                Text("album.loading").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("album.empty", systemImage: "photo.on.rectangle.angled")
            } actions: {
                if model.notice?.isError == true {
                    Button("common.retry", action: model.retry)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var deleteButton: some View {
        Button {
            confirmsDelete = true
        } label: {
            Group {
                if model.deleting {
                    ProgressView().tint(.white)
                        .accessibilityLabel(Text("album.deleting.media"))
                } else {
                    Image(systemName: "trash")
                        .font(verticalSizeClass == .compact ? .body.weight(.semibold) : .title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: floatingSize, height: floatingSize)
            .glassEffect(.regular.tint(.red).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(model.deleting || model.selection.isEmpty || !model.opened)
        .accessibilityLabel(Text("album.delete"))
        .accessibilityIdentifier("album.delete")
    }

    private func feedback(_ notice: CameraController.Notice) -> some View {
        VStack(spacing: 6) {
            Text(notice.text)
                .font(.footnote)
                .multilineTextAlignment(.center)
            if notice.isError && model.hasSnapshot {
                Button("common.retry", action: model.retry)
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
