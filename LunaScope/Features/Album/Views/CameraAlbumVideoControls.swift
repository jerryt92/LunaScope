import AVFoundation
import SwiftUI

@Observable
final class CameraAlbumVideoControlsState {
    var progress = 0.0
    var duration: TimeInterval = 0
    var animatesProgress = true
    var isPlaying = false
    var isMuted = true
    var onTogglePlayback: () -> Void = {}
    var onToggleMute: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }
    var onSeekingChanged: (Bool) -> Void = { _ in }

    func reset() {
        progress = 0
        duration = 0
        animatesProgress = true
        isPlaying = false
        isMuted = true
        onTogglePlayback = {}
        onToggleMute = {}
        onSeek = { _ in }
        onSeekingChanged = { _ in }
    }
}

/// 视频播放控件：播放/暂停、静音切换、进度条与时间。
struct CameraAlbumVideoControls: View {
    @Bindable var state: CameraAlbumVideoControlsState

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var dragStartValue = 0.0

    init(state: CameraAlbumVideoControlsState) {
        self.state = state
        _sliderValue = State(initialValue: state.progress)
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            controls.glassEffect(.regular, in: Capsule())
        } else {
            controls
                .background(.ultraThinMaterial, in: Capsule())
                .clipShape(Capsule())
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: state.onTogglePlayback) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isPlaying ? "album.preview.pause" : "album.preview.play")

            GeometryReader { proxy in
                Slider(
                    value: $sliderValue,
                    in: 0...1
                )
                .tint(.primary)
                .animation(state.animatesProgress ? .linear(duration: 0.12) : nil, value: sliderValue)
                .contentShape(Rectangle())
                .onChange(of: sliderValue) { _, value in
                    guard isEditing else { return }
                    state.onSeek(value)
                }
                // 高优先级手势盖住 Slider 自带的拖动，按住轨道任意处即可拖；
                // 按拖动位移改变进度，不把进度瞬移到按下的位置。
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isEditing {
                                isEditing = true
                                dragStartValue = sliderValue
                                state.onSeekingChanged(true)
                            }
                            sliderValue = draggedValue(translation: value.translation.width, width: proxy.size.width)
                        }
                        .onEnded { value in
                            sliderValue = draggedValue(translation: value.translation.width, width: proxy.size.width)
                            state.onSeek(sliderValue)
                            isEditing = false
                            state.onSeekingChanged(false)
                        }
                )
            }
            .frame(height: 30)
            .frame(maxWidth: .infinity)

            Button(action: state.onToggleMute) {
                Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isMuted ? "album.preview.unmute" : "album.preview.mute")

            Text(verbatim: timeLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 82, alignment: .trailing)
                .accessibilityLabel(timeLabel)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .onChange(of: state.progress) { _, value in
            guard !isEditing else { return }
            sliderValue = value
        }
    }

    private var displayedProgress: Double {
        isEditing ? sliderValue : state.progress
    }

    /// 进度时间文案，不走本地化目录，避免被提取成格式 key。
    private var timeLabel: String {
        "\(formattedTime(displayedProgress * state.duration)) / \(formattedTime(state.duration))"
    }

    /// 按下时的进度加上本次拖动位移，按住轨道任意处开始拖都以相对位移推进。
    private func draggedValue(translation: CGFloat, width: CGFloat) -> Double {
        min(max(dragStartValue + translation / max(width, 1), 0), 1)
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let roundedTime = Int(time.rounded(.down))
        let hours = roundedTime / 3_600
        let minutes = (roundedTime % 3_600) / 60
        let seconds = roundedTime % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

@MainActor
@Observable
final class CameraAlbumVideoPlayback {
    let controls = CameraAlbumVideoControlsState()
    private(set) var player: AVPlayer?
    private var file: CameraMediaFile?
    private var timeObserver: Any?
    private var durationTask: Task<Void, Never>?
    private var livePlaybackTask: Task<Void, Never>?
    private var livePlaybackObservers: [NSObjectProtocol] = []
    private var seeking = false

    /// - Parameter autoplay: 普通视频默认开播；实况按住播放时先加载停在静帧。
    func start(file: CameraMediaFile, muted: Bool, autoplay: Bool = true, onMute: @escaping (Bool) -> Void) {
        stop()
        self.file = file
        let player = AVPlayer(url: file.url)
        self.player = player
        player.isMuted = muted
        controls.isMuted = muted
        controls.isPlaying = autoplay
        controls.onTogglePlayback = { [weak self, weak player] in
            guard let self, let player else { return }
            if controls.isPlaying {
                pause()
            } else {
                if controls.progress >= 0.999 { seek(to: 0) }
                player.play()
                controls.isPlaying = true
            }
        }
        controls.onToggleMute = { [weak self, weak player] in
            guard let self, let player else { return }
            player.isMuted.toggle()
            controls.isMuted = player.isMuted
            onMute(player.isMuted)
        }
        controls.onSeek = { [weak self] in self?.seek(to: $0) }
        controls.onSeekingChanged = { [weak self] active in
            self?.seeking = active
            self?.controls.animatesProgress = !active
        }
        durationTask = Task { [weak self, weak player] in
            guard let player, let asset = player.currentItem?.asset,
                  let duration = try? await asset.load(.duration).seconds,
                  duration.isFinite, duration > 0,
                  !Task.isCancelled, let self, self.player === player else { return }
            controls.duration = duration
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600), queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, self.player === player, !self.seeking,
                      time.seconds.isFinite, self.controls.duration > 0 else { return }
                self.controls.progress = min(max(time.seconds / self.controls.duration, 0), 1)
                if autoplay, self.controls.progress >= 0.999, player?.timeControlStatus == .paused {
                    self.controls.isPlaying = false
                }
            }
        }
        if autoplay {
            player.play()
        } else if let item = player.currentItem {
            livePlaybackObservers = [
                AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification
            ].map { name in
                NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) {
                    [weak self, weak player] _ in
                    MainActor.assumeIsolated {
                        guard let self, let player, self.player === player, self.livePlaybackTask == nil else { return }
                        self.pause()
                    }
                }
            }
        }
    }

    /// 长按触发一次完整播放，从片头开始，松手后继续。
    func playLivePhoto() {
        guard let player, !controls.isPlaying else { return }
        controls.isPlaying = true
        controls.progress = 0
        livePlaybackTask = Task { [weak self, weak player] in
            guard let player else { return }
            let reachedStart = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, let self, self.player === player else { return }
            self.livePlaybackTask = nil
            guard reachedStart else {
                self.pause()
                return
            }
            let audioSession = AVAudioSession.sharedInstance()
            if audioSession.category != .playback {
                do {
                    try audioSession.setCategory(.playback, options: [.mixWithOthers])
                } catch {
                    AppLog.error(error, context: "album.livePhoto.audio")
                }
            }
            player.play()
        }
    }

    func pause() {
        if let livePlaybackTask {
            livePlaybackTask.cancel()
            self.livePlaybackTask = nil
            player?.currentItem?.cancelPendingSeeks()
        }
        player?.pause()
        controls.isPlaying = false
    }

    func stop() {
        pause()
        durationTask?.cancel()
        durationTask = nil
        for observer in livePlaybackObservers { NotificationCenter.default.removeObserver(observer) }
        livePlaybackObservers.removeAll()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        file = nil
        seeking = false
        controls.reset()
    }

    private func seek(to progress: Double) {
        guard let player, controls.duration > 0 else { return }
        controls.progress = progress
        player.seek(to: CMTime(seconds: progress * controls.duration, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
