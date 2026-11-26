import AVFoundation
import SwiftUI

struct CameraAlbumPreview: View {
    let model: CameraAlbumModel
    let session: CameraAlbumPreviewSession
    @Binding var videoMuted: Bool
    let onClose: (String) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var current: CameraAlbumItem
    @State private var phase: Phase = .loading
    @State private var request = UUID()
    @State private var immersive = false
    @State private var showsInfo = false
    @State private var showsDeleteFeedback = false
    @State private var confirmsDelete = false
    @State private var dismissProgress = 0.0
    @State private var video = CameraAlbumVideoPlayback()
    @State private var liveStill: UIImage?

    private enum Phase {
        case loading, busy, ready(CameraAlbumPreviewMedia), failed(String)
    }

    init(
        model: CameraAlbumModel, session: CameraAlbumPreviewSession, videoMuted: Binding<Bool>,
        onClose: @escaping (String) -> Void
    ) {
        self.model = model
        self.session = session
        self._videoMuted = videoMuted
        self.onClose = onClose
        _current = State(initialValue: session.items.first { $0.id == session.initialID } ?? session.items[0])
    }

    var body: some View {
        ZStack {
            (immersive ? Color.black : Color(uiColor: .systemBackground))
                .ignoresSafeArea()
            CameraAlbumPager(
                items: session.items, initialID: session.initialID, activeID: current.id,
                image: activeImage,
                // 实况只在播放期间显示视频层，静帧留在视频层下方。
                player: (current.kind != .livePhoto || liveMotionVisible) ? video.player : nil,
                allowsLivePhotoPress: current.kind == .livePhoto && video.player != nil,
                poster: { model.cachedThumbnail($0, in: session) },
                onPageChange: changePage, onTap: handleTap,
                onLivePhotoPress: handleLivePhotoPress,
                onDismissProgress: { dismissProgress = $0 }, onDismiss: close
            )
            .ignoresSafeArea()
            .accessibilityHint(current.kind == .livePhoto ? Text("album.preview.livePressHint") : Text(verbatim: ""))

            status
                .opacity(1 - dismissProgress)

            VStack {
                header
                Spacer()
                footer
            }
            .opacity(immersive ? 0 : 1 - dismissProgress)
            .allowsHitTesting(!immersive && dismissProgress == 0)
            .accessibilityHidden(immersive)
            .animation(.easeInOut(duration: 0.18), value: immersive)
        }
        .statusBarHidden(immersive)
        .task(id: request) { await load(request) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { video.pause() }
        }
        .onChange(of: model.deleting) { _, deleting in
            if !deleting, showsDeleteFeedback, model.notice?.isError != true {
                closeAfterDelete()
            }
        }
        .onDisappear { video.stop() }
        .accessibilityAction(.escape, close)
        .alert("album.delete.confirmTitle", isPresented: $confirmsDelete) {
            Button("album.delete", role: .destructive) {
                showsDeleteFeedback = true
                model.delete(current, in: session)
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("album.delete.confirmOne")
        }
    }

    private var liveMotionVisible: Bool {
        current.kind == .livePhoto && video.controls.isPlaying
    }

    private var activeImage: UIImage? {
        if case .ready(.image(let image)) = phase { return image }
        if case .ready(.livePhoto(let still, _)) = phase {
            return still
        }
        return liveStill
    }

    private var header: some View {
        ZStack(alignment: .top) {
            if let date = current.date {
                Text(CameraAlbumPreviewDate.string(for: date))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 64)
                    .padding(.top, 20)
                    .allowsHitTesting(false)
            }

            HStack(alignment: .top) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("common.close"))
                .accessibilityIdentifier("album.preview.close")
                Spacer()
                HStack(spacing: 8) {
                    if current.kind == .livePhoto {
                        Image(systemName: "livephoto")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.top, 6)
                            .accessibilityLabel(Text("album.badge.live"))
                    }
                    if current.kind == .raw {
                        Image(uiImage: CameraAlbumRawBadge.preview)
                            .renderingMode(.template)
                            .padding(.top, 6)
                            .accessibilityLabel(Text("album.badge.raw"))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .busy:
            VStack(spacing: 10) {
                ProgressView()
                Text("album.preview.busy")
                    .font(.footnote.weight(.semibold))
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("album.preview.busy")
        case .loading:
            ProgressView()
                .padding(14)
                .glassEffect(.regular, in: .circle)
                .allowsHitTesting(false)
                .accessibilityLabel(Text("album.loading"))
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center)
                Button("common.retry", action: reload)
                    .buttonStyle(.bordered)
                    .disabled(!model.opened)
                    .accessibilityIdentifier("album.preview.retry")
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.horizontal, 24)
        case .ready:
            EmptyView()
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if video.player != nil, current.kind == .video {
                CameraAlbumVideoControls(state: video.controls)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            if showsDeleteFeedback, let notice = model.notice, notice.isError {
                Text(notice.text).font(.footnote)
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            Group {
                if showsInfo {
                    infoCard
                        .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
                } else {
                    HStack(spacing: 12) {
                        Button {
                            confirmsDelete = true
                        } label: {
                            Group {
                                if model.deleting { ProgressView() }
                                else { Image(systemName: "trash") }
                            }
                            .previewControl()
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.opened || model.deleting)
                        .accessibilityLabel(Text("album.delete"))
                        .accessibilityIdentifier("album.preview.delete")
                        Button {
                            withAnimation(.smooth(duration: 0.28)) { showsInfo = true }
                        } label: {
                            Image(systemName: "info.circle").previewControl()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("album.preview.info"))
                        .accessibilityIdentifier("album.preview.info")
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    private var infoCard: some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) { showsInfo = false }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(current.filename).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let date = current.date {
                    Text(CameraAlbumPreviewDate.string(for: date))
                }
                HStack(spacing: 8) {
                    Text(verbatim: (current.filename as NSString).pathExtension.uppercased())
                    if let size = current.dimensions { Text(verbatim: "\(size.width) × \(size.height)") }
                    if let count = current.byteCount, let bytes = Int64(exactly: count) {
                        Text(bytes.formatted(.byteCount(style: .file)))
                    }
                }
                if current.kind == .livePhoto {
                    Text("album.badge.live")
                }
                if let duration = current.duration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 268, alignment: .leading)
            .padding(16)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("common.close"))
    }

    private func changePage(_ item: CameraAlbumItem) {
        guard item.id != current.id else { return }
        current = item
        reload()
    }

    private func handleTap() {
        if showsInfo {
            withAnimation(.smooth(duration: 0.28)) { showsInfo = false }
        } else {
            immersive.toggle()
        }
    }

    private func handleLivePhotoPress() {
        guard current.kind == .livePhoto, scenePhase == .active else { return }
        video.playLivePhoto()
    }

    private func reload() {
        video.stop()
        liveStill = nil
        phase = .loading
        request = UUID()
    }

    private func load(_ token: UUID) async {
        do {
            let media = try await model.preview(current, in: session) { busy in
                guard !Task.isCancelled, token == request else { return }
                phase = busy ? .busy : .loading
            }
            guard !Task.isCancelled, token == request else { return }
            switch media {
            case .video(let file):
                video.start(file: file, muted: videoMuted) { muted in videoMuted = muted }
                if scenePhase != .active { video.pause() }
            case .livePhoto(let still, let motion):
                liveStill = still
                if let motion {
                    video.start(file: motion, muted: false, autoplay: false) { _ in }
                }
            case .image:
                break
            }
            phase = .ready(media)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, token == request else { return }
            AppLog.error(error, context: "album.preview")
            if case CameraAlbumError.disconnected = error {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .failed(String(localized: "album.preview.error"))
            }
        }
    }

    private func closeAfterDelete() {
        video.stop()
        request = UUID()
        onClose(current.id)
    }

    private func close() {
        video.stop()
        request = UUID()
        onClose(current.id)
    }
}

private extension View {
    func previewControl() -> some View {
        font(.system(size: 18, weight: .medium))
            .frame(width: 48, height: 48)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

private enum CameraAlbumPreviewDate {
    static func string(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEEjm")
        return formatter.string(from: date)
    }
}
