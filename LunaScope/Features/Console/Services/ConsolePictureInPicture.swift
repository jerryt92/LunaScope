import AVFoundation
import AVKit
import Observation

/// The inline and floating previews share one retained sample-buffer layer.
@MainActor
@Observable
final class ConsolePictureInPicture: NSObject, @preconcurrency AVPictureInPictureControllerDelegate,
    @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var isActive = false
    private(set) var isTransitioning = false
    private(set) var isPaused = false
    private(set) var startError: String?
    @ObservationIgnored var onResume: (() -> Void)?
    @ObservationIgnored var onRestore: (() -> Void)?
    @ObservationIgnored var onStartRequested: (() -> Void)?
    /// 画中画释放 AVAudioSession 后回调，供连拍/录像保活立刻抢回。
    @ObservationIgnored var onAudioSessionReleased: (() -> Void)?
    @ObservationIgnored private let layer: AVSampleBufferDisplayLayer
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var startupTimeout: Task<Void, Never>?
    @ObservationIgnored private var waitingForAvailability = false
    @ObservationIgnored private var audioActive = false
    @ObservationIgnored private var stopWhenStarted = false

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        super.init()
    }

    /// Install the content source after the full-screen layer is attached to its window.
    func sourceDidAttach() {
        guard isSupported, controller == nil else { return }
        if layer.controlTimebase == nil {
            var timebase: CMTimebase?
            if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                               timebaseOut: &timebase) == noErr, let timebase {
                CMTimebaseSetTime(timebase, time: .zero)
                CMTimebaseSetRate(timebase, rate: 1)
                layer.controlTimebase = timebase
            }
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        self.controller = controller
        controller.delegate = self
        controller.requiresLinearPlayback = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.startWhenPossible()
            }
        }
    }

    func toggle() {
        guard isSupported, !isTransitioning else { return }
        if isActive {
            stop()
            return
        }
        startError = nil
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audio.setActive(true)
            audioActive = true
        } catch {
            reportFailure(error)
            return
        }
        isTransitioning = true
        waitingForAvailability = true
        controller?.invalidatePlaybackState()
        onStartRequested?()
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, waitingForAvailability else { return }
            finish()
            startError = String(localized: "console.preview.pipUnavailable")
        }
        startWhenPossible()
    }

    private func startWhenPossible() {
        guard waitingForAvailability, let controller, controller.isPictureInPicturePossible else { return }
        waitingForAvailability = false
        startupTimeout?.cancel()
        startupTimeout = nil
        controller.startPictureInPicture()
    }

    func cancelPendingStart() {
        if !isActive && isTransitioning {
            stop()
        }
    }

    func dismissError() { startError = nil }

    func stop() {
        if waitingForAvailability {
            finish()
        } else if isActive {
            if !isTransitioning {
                isTransitioning = true
                controller?.stopPictureInPicture()
            }
        } else if isTransitioning {
            stopWhenStarted = true
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
        isTransitioning = false
        if stopWhenStarted { stop() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        finish()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isTransitioning = true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        finish()
        reportFailure(error)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onRestore?()
        completionHandler(true)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        let paused = !playing
        guard isPaused != paused else { return }
        isPaused = paused
        if playing { onResume?() }
        controller.invalidatePlaybackState()
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        isPaused
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize size: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime,
                                    completion: @escaping () -> Void) {
        completion()
    }

    private func finish() {
        startupTimeout?.cancel()
        startupTimeout = nil
        waitingForAvailability = false
        isActive = false
        isTransitioning = false
        stopWhenStarted = false
        if isPaused {
            isPaused = false
            onResume?()
        }
        if audioActive {
            audioActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            onAudioSessionReleased?()
        }
    }

    private func reportFailure(_ error: Error) {
        AppLog.error(error, context: "console.preview.pip")
        startError = error.localizedDescription
    }
}
