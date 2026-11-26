import AVFoundation
import Foundation

/// 录像 / 连拍期间用已声明的 `audio` 后台模式保活进程。
/// 实时活动只负责展示，不能阻止系统挂起；无音频会话时 UIBackgroundTask 约几十秒就会到期。
@MainActor
final class CaptureBackgroundKeepAlive {
    private var player: AVAudioPlayer?
    private var sessionOwned = false
    private var captureActive = false
    private var pipActive = false

    /// 按拍摄与画中画状态同步后台音频保活。
    func sync(captureActive: Bool, pipActive: Bool) {
        self.captureActive = captureActive
        self.pipActive = pipActive
        apply()
    }

    /// 画中画释放音频会话后立刻按当前拍摄态抢回，避免连拍空窗被挂起。
    func reassertAfterAudioRelease() {
        apply()
    }

    private func apply() {
        let needSession = captureActive || pipActive
        if captureActive && !pipActive {
            startSilentPlayer()
        } else {
            stopSilentPlayer()
        }
        if needSession {
            activateSession()
        } else {
            deactivateSession()
        }
    }

    private func activateSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionOwned = true
        } catch {
            AppLog.error(error, context: "capture.background.audio.activate")
        }
    }

    private func deactivateSession() {
        stopSilentPlayer()
        guard sessionOwned else { return }
        sessionOwned = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startSilentPlayer() {
        if let player, player.isPlaying { return }
        stopSilentPlayer()
        do {
            activateSession()
            let player = try AVAudioPlayer(data: Self.silentLoopWAV)
            player.numberOfLoops = -1
            // 极低音量：纯 0 样本可能被系统当成未真正播放而挂起。
            player.volume = 0.01
            player.prepareToPlay()
            guard player.play() else {
                throw NSError(domain: "CaptureBackgroundKeepAlive", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "silent audio failed to start"])
            }
            self.player = player
        } catch {
            AppLog.error(error, context: "capture.background.audio.play")
        }
    }

    private func stopSilentPlayer() {
        player?.stop()
        player = nil
    }

    /// 约 0.25s、8-bit/8kHz 单声道 WAV，含极弱非零采样，避免被当成空缓冲。
    private static let silentLoopWAV: Data = {
        let sampleRate = 8_000
        let sampleCount = sampleRate / 4
        var data = Data()
        func appendUInt32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + sampleCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate))
        appendUInt16(1)
        appendUInt16(8)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(sampleCount))
        for index in 0..<sampleCount {
            // 128 为静音中点；偶发 ±1 保持播放器处于 active。
            let sample: UInt8 = index % 64 == 0 ? 129 : 128
            data.append(sample)
        }
        return data
    }()
}
