import Foundation
import LunaTransportApple
import LunaTransportProtocol

/// 连续写入共用一个已经建立的相机会话；写前校验空闲，确认期只核对模式并可随时取消。
@MainActor
struct ConsoleCameraCommands {
    let session: LunaCameraSession
    let profile: ConsoleCameraProfile
    var firmware: String? = nil
    let checkIdle: () async throws -> Void
    var lastReportedLivePhoto: () -> Bool? = { nil }
    /// 确认会话仍在目标模式；确认轮询期间不应再要求 settled idle。
    let validate: (LunaShootingMode) throws -> Void

    func read(_ mode: LunaShootingMode) async throws -> ConsoleParameters {
        try validate(mode)
        let options = ConsoleParameters.optionTypes.filter { $0 != 25 || (mode == .photo && profile.rawPhoto) }
        return try await read(mode, options: options, requireValues: true)
    }

    /// 首连时优先读取照片规格，允许在拍摄状态尚未到达时进行这次只读请求。
    func readPhotoFormat() async throws -> ConsoleParameters {
        let settings = try await read(.photo, options: [25, 40], requireValues: true)
        guard settings.rawCapture != nil else { throw ControlError.readbackMismatch }
        return settings
    }

    /// 独立回读实况照片，避免不返回 type 85 的固件影响 JPG / RAW 和照片尺寸。
    func readLivePhoto() async throws -> Bool? {
        try validate(.photo)
        let request = try LunaProtocol.getPhotographyOptions([UInt32(ConsoleLivePhoto.option)],
                                                             mode: LunaFunctionMode.normalImage.rawValue)
        let response = try await session.control(request, timeout: .seconds(2))
        try validate(.photo)
        let settings = try LunaPhotographySettings(response: response)
        guard settings.functionMode == nil || settings.functionMode == LunaFunctionMode.normalImage.rawValue else {
            throw ControlError.modeChanged
        }
        var parameters = ConsoleParameters(mode: .photo)
        try parameters.ingestLivePhoto(response: response)
        return parameters.livePhoto
    }

    func writeLivePhoto(_ enabled: Bool, isCurrent: @escaping () -> Bool = { true }) async throws -> ConsoleParameters {
        try await write(ConsoleLivePhoto.request(enabled), in: .photo,
                        options: [UInt32(ConsoleLivePhoto.option)],
                        readsLivePhoto: true, isCurrent: isCurrent) {
            $0.livePhoto == enabled
        }
    }

    /// 先确认 A／M 已切换，再按序写入该模式的参数。
    func apply(_ selection: ConsoleParameters,
               isCurrent: @escaping () -> Bool = { true }) async throws -> LunaIQ3AMode? {
        let mode = selection.mode.native
        let bank = mode.functionMode.rawValue
        let saved = selection.restorable(for: profile, currentFormat: selection.format, firmware: firmware)
        guard saved.hasValues else { return nil }
        try validate(mode)
        try await waitUntilIdle(isCurrent: isCurrent)
        try validate(mode)

        // 规格前先关实况，避免不支持实况的目标规格被拒。
        if mode == .photo, let format = saved.format, !profile.allowsLivePhoto(format: format) {
            try await push(ConsoleLivePhoto.request(false), isCurrent: isCurrent)
        }
        if let format = saved.format {
            try await push(try formatRequest(format, in: mode), isCurrent: isCurrent)
            try await Task.sleep(for: .milliseconds(800))
        }
        if mode == .photo, let raw = saved.rawCapture {
            try await push(ConsoleCaptureFormats.rawRequest(raw), isCurrent: isCurrent)
        }
        if let raw = saved.color, let color = LunaColorMode(rawValue: raw), !mode.isPhoto {
            try await push(try LunaProtocol.setColorMode(color, functionMode: bank), isCurrent: isCurrent)
        }
        if let zoom = saved.zoom {
            try await push(try LunaProtocol.setZoomScale(zoom, functionMode: bank), isCurrent: isCurrent)
        }
        if let exposureMode = saved.exposureControlMode {
            _ = try await writeExposureControlMode(exposureMode, in: mode, isCurrent: isCurrent)
        }
        if let exposure = saved.exposure, exposure.isComplete, mode != .pano {
            try await push(try exposure.request(mode: mode), isCurrent: isCurrent)
        }
        if let bias = saved.exposureBiasTenths {
            try await push(try LunaProtocol.setExposureBias(Double(bias) / 10, functionMode: bank), isCurrent: isCurrent)
        }
        if let enabled = saved.faceMetering {
            try await push(try LunaProtocol.setFaceMetering(enabled, functionMode: bank), isCurrent: isCurrent)
        }
        if let kelvin = saved.whiteBalance {
            let request = try kelvin == 0
                ? LunaProtocol.setWhiteBalanceAuto(functionMode: bank)
                : LunaProtocol.setWhiteBalanceKelvin(kelvin, functionMode: bank)
            try await push(request, isCurrent: isCurrent)
        }
        if let autofocus = saved.autofocus, let focus = LunaAFMode(rawValue: autofocus) {
            try await push(try LunaProtocol.setAFMode(focus, functionMode: bank), isCurrent: isCurrent)
        }
        if mode == .photo, let live = saved.livePhoto {
            try await push(ConsoleLivePhoto.request(live), isCurrent: isCurrent)
        }
        return saved.exposureControlMode
    }

    private func push(_ request: LunaRequest, isCurrent: () -> Bool) async throws {
        guard isCurrent() else { throw CancellationError() }
        _ = try await session.control(request, timeout: .seconds(3))
    }

    private func read(_ mode: LunaShootingMode, options: [UInt32], requireValues: Bool) async throws -> ConsoleParameters {
        try validate(mode)
        let request = try LunaProtocol.getPhotographyOptions(options, mode: mode.functionMode.rawValue)
        let response = try await session.control(request, timeout: .seconds(3))
        try validate(mode)
        let reported = try LunaPhotographySettings(response: response)
        guard reported.functionMode == nil || reported.functionMode == mode.functionMode.rawValue else {
            throw ControlError.modeChanged
        }
        var parameters = ConsoleParameters(mode: mode)
        parameters.ingest(reported)
        try parameters.ingestRAW(response: response)
        try parameters.ingestLivePhoto(response: response)
        if mode == .photo, parameters.livePhoto == nil { parameters.livePhoto = lastReportedLivePhoto() }
        if requireValues { guard parameters.hasValues else { throw ControlError.readbackMismatch } }
        return parameters
    }

    /// 写前空闲检查；短暂 busy 按高级设置重试，避免连调曝光被上一次落盘卡住。
    private func waitUntilIdle(isCurrent: @escaping () -> Bool) async throws {
        var lastError: Error = ControlError.cameraBusy
        let attempts = max(1, ConsoleCommandPreferences.retryLimit + 1)
        for attempt in 0..<attempts {
            guard isCurrent() else { throw CancellationError() }
            do {
                try await checkIdle()
                return
            } catch ControlError.cameraBusy {
                lastError = ControlError.cameraBusy
                try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            } catch {
                throw error
            }
        }
        throw lastError
    }

    /// 下发后按指定 option 定向回读；`settle` 内空包/未匹配继续等，被覆盖则抛出取消。
    func write(_ request: LunaRequest, in mode: LunaShootingMode,
               options: [UInt32]? = nil,
               settle: Duration = ConsoleCommandPreferences.confirmSettle,
               readsLivePhoto: Bool = false,
               confirmsFromSet: Bool = true,
               isCurrent: @escaping () -> Bool = { true },
               confirms: (ConsoleParameters) -> Bool) async throws -> ConsoleParameters {
        try validate(mode)
        try await waitUntilIdle(isCurrent: isCurrent)
        try validate(mode)
        guard isCurrent() else { throw CancellationError() }
        let reply = try await session.control(request, timeout: .seconds(3))
        guard isCurrent() else { throw CancellationError() }

        let readOptions: [UInt32] = options ?? ConsoleParameters.optionTypes.filter {
            $0 != 25 || (mode == .photo && profile.rawPhoto)
        }
        // SET 若已带回可确认字段，跳过一轮 GET。
        if confirmsFromSet, let early = try? acceptedParameters(reply: reply, mode: mode, confirms: confirms) {
            return early
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: settle)
        repeat {
            guard isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
            do {
                var actual = try await read(mode, options: readOptions, requireValues: false)
                if readsLivePhoto && !confirms(actual), let live = try? await readLivePhoto() {
                    actual.livePhoto = live
                }
                try validate(mode)
                if confirms(actual) { return actual }
            } catch ControlError.readbackMismatch {
                // 切换编码时可能先回空包，等到结算窗口截止再失败。
            } catch ControlError.cameraBusy {
                // 确认期短暂 busy 不整次判死。
            }
            try await Task.sleep(for: .milliseconds(150))
        } while clock.now < deadline
        guard isCurrent() else { throw CancellationError() }
        throw ControlError.readbackMismatch
    }

    func writeExposureControlMode(_ exposureMode: LunaIQ3AMode, in mode: LunaShootingMode,
                                  isCurrent: @escaping () -> Bool) async throws -> ConsoleParameters {
        let request = try LunaProtocol.setIQ3AMode(exposureMode, functionMode: mode.functionMode.rawValue)
        return try await write(request, in: mode, options: [7, 20, 21, 24, 39, 46, 93, 100],
                               confirmsFromSet: false, isCurrent: isCurrent) {
            $0.exposureControlMode == exposureMode
        }
    }

    func writeExposureBias(_ tenths: Int32, in mode: LunaShootingMode,
                           isCurrent: @escaping () -> Bool) async throws -> ConsoleParameters {
        let request = try LunaProtocol.setExposureBias(Double(tenths) / 10, functionMode: mode.functionMode.rawValue)
        return try await write(request, in: mode, options: [7], confirmsFromSet: false, isCurrent: isCurrent) {
            $0.exposureBiasTenths == tenths
        }
    }

    func writeMetering(_ facePriority: Bool, in mode: LunaShootingMode,
                       isCurrent: @escaping () -> Bool) async throws -> ConsoleParameters {
        let request = try LunaProtocol.setFaceMetering(facePriority, functionMode: mode.functionMode.rawValue)
        return try await write(request, in: mode, options: [46], confirmsFromSet: false, isCurrent: isCurrent) {
            $0.faceMetering == facePriority
        }
    }

    /// 曝光专用确认：still / video 任一路匹配即成功，并把匹配结果写回参数。
    func writeExposure(_ exposure: ConsoleExposure, in mode: LunaShootingMode,
                       isCurrent: @escaping () -> Bool = { true }) async throws -> ConsoleParameters {
        let request = try exposure.request(mode: mode)
        try validate(mode)
        try await waitUntilIdle(isCurrent: isCurrent)
        try validate(mode)
        guard isCurrent() else { throw CancellationError() }
        let reply = try await session.control(request, timeout: .seconds(3))
        guard isCurrent() else { throw CancellationError() }

        let clock = ContinuousClock()
        // 确认窗口由高级设置控制；机身落盘 ISO/快门常见需数秒。
        let deadline = clock.now.advanced(by: ConsoleCommandPreferences.confirmSettle)
        if let early = try? exposureParameters(from: reply, mode: mode, expected: exposure) {
            return early
        }
        repeat {
            guard isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
            do {
                try validate(mode)
                let get = try LunaProtocol.getPhotographyOptions([20, 21, 24, 100], mode: mode.functionMode.rawValue)
                let response = try await session.control(get, timeout: .seconds(3))
                try validate(mode)
                if let actual = try exposureParameters(from: response, mode: mode, expected: exposure) {
                    return actual
                }
            } catch ControlError.cameraBusy {
            } catch ControlError.readbackMismatch {
            }
            try await Task.sleep(for: .milliseconds(150))
        } while clock.now < deadline
        guard isCurrent() else { throw CancellationError() }
        throw ControlError.readbackMismatch
    }

    private func acceptedParameters(
        reply: Data, mode: LunaShootingMode, confirms: (ConsoleParameters) -> Bool
    ) throws -> ConsoleParameters? {
        let reported = try LunaPhotographySettings(response: reply)
        guard reported.functionMode == nil || reported.functionMode == mode.functionMode.rawValue else {
            throw ControlError.modeChanged
        }
        var parameters = ConsoleParameters(mode: mode)
        parameters.ingest(reported)
        try parameters.ingestRAW(response: reply)
        try parameters.ingestLivePhoto(response: reply)
        return confirms(parameters) ? parameters : nil
    }

    private func exposureParameters(
        from response: Data, mode: LunaShootingMode, expected: ConsoleExposure
    ) throws -> ConsoleParameters? {
        let reported = try LunaPhotographySettings(response: response)
        guard reported.functionMode == nil || reported.functionMode == mode.functionMode.rawValue else {
            throw ControlError.modeChanged
        }
        guard expected.matchedReport(in: reported) != nil else { return nil }
        var parameters = ConsoleParameters(mode: mode)
        parameters.ingest(reported)
        // 确认成功后以写入意图为准，避免机身残留 Max 把 Auto 显示打回 3200Max。
        parameters.exposure = expected
        return parameters
    }

    func formatRequest(_ code: UInt64, in mode: LunaShootingMode) throws -> LunaRequest {
        guard profile.supports(code, in: mode) else { throw ControlError.settingUnavailable }
        if mode == .photo, let format = profile.photoFormats.first(where: { $0.id == code }) {
            return try format.request()
        }
        return try LunaProtocol.setRecordResolution(code, functionMode: mode.functionMode.rawValue,
                                                    requiredColor: profile.requiredColor(for: code))
    }

    /// 先处理可能影响曝光或镜头的规格和变焦，再写曝光，最后确认整组设置。
    func restore(_ selection: ConsoleParameters, isCurrent: @escaping () -> Bool = { true }) async throws -> ConsoleParameters {
        let mode = selection.mode.native
        let bank = mode.functionMode.rawValue
        var current = try await read(mode)
        let saved = selection.restorable(for: profile, currentFormat: current.format, firmware: firmware)
        if mode == .photo, !profile.livePhotoFormatIDs.isEmpty,
           saved.livePhoto == false || saved.format.map({ !profile.allowsLivePhoto(format: $0) }) == true {
            if current.livePhoto == nil { current.livePhoto = try? await readLivePhoto() }
            if current.livePhoto == true {
                current = try await writeLivePhoto(false, isCurrent: isCurrent)
            }
        }
        if let format = saved.format, format != current.format {
            let options: [UInt32] = mode.isPhoto ? [40] : [31, 35]
            _ = try await write(formatRequest(format, in: mode), in: mode, options: options,
                                isCurrent: isCurrent) { $0.format == format }
            // 规格会重新配置预览和编码，等待相机结束切换再写其他设置。
            try await Task.sleep(for: .seconds(2))
            guard isCurrent() else { throw CancellationError() }
            current = try await read(mode)
        }
        if mode == .photo, let raw = saved.rawCapture, raw != (current.rawCapture ?? false) {
            current = try await write(ConsoleCaptureFormats.rawRequest(raw), in: mode, options: [25],
                                      isCurrent: isCurrent) {
                ($0.rawCapture ?? false) == raw
            }
        }
        if let raw = saved.color, raw != current.color {
            guard let color = LunaColorMode(rawValue: raw), profile.colorChoices(for: current.format).contains(color) else {
                throw ControlError.settingUnavailable
            }
            current = try await write(LunaProtocol.setColorMode(color, functionMode: bank), in: mode,
                                      options: [35], isCurrent: isCurrent) {
                $0.color == raw
            }
        }
        if let zoom = saved.zoom, abs((current.zoom ?? 0) - zoom) > 0.03 {
            current = try await write(LunaProtocol.setZoomScale(zoom, functionMode: bank), in: mode,
                                      options: [53], isCurrent: isCurrent) {
                $0.zoom.map { abs($0 - zoom) <= 0.03 } ?? false
            }
        }
        if let exposureMode = saved.exposureControlMode, exposureMode != current.exposureControlMode {
            current.merge(try await writeExposureControlMode(exposureMode, in: mode, isCurrent: isCurrent))
        }
        // 用 matchesIntent：无上限 Auto 相对当前 Max 不能跳过，否则预设/套用清不掉上限。
        if let exposure = saved.exposure, !exposure.matchesIntent(current.exposure) {
            guard exposure.isComplete, mode != .pano else { throw ControlError.settingUnavailable }
            current.merge(try await writeExposure(exposure, in: mode, isCurrent: isCurrent))
        }
        if let bias = saved.exposureBiasTenths, bias != current.exposureBiasTenths {
            current.merge(try await writeExposureBias(bias, in: mode, isCurrent: isCurrent))
        }
        if let enabled = saved.faceMetering, enabled != current.faceMetering {
            current.merge(try await writeMetering(enabled, in: mode, isCurrent: isCurrent))
        }
        if let kelvin = saved.whiteBalance, kelvin != current.whiteBalance {
            let request = try kelvin == 0 ? LunaProtocol.setWhiteBalanceAuto(functionMode: bank)
                : LunaProtocol.setWhiteBalanceKelvin(kelvin, functionMode: bank)
            current.merge(try await write(request, in: mode, options: [39],
                                          isCurrent: isCurrent) { $0.whiteBalance == kelvin })
        }
        if let autofocus = saved.autofocus, autofocus != current.autofocus {
            guard let focus = LunaAFMode(rawValue: autofocus) else { throw ControlError.settingUnavailable }
            current.merge(try await write(LunaProtocol.setAFMode(focus, functionMode: bank), in: mode,
                                          options: [93], isCurrent: isCurrent) {
                $0.autofocus == autofocus
            })
        }
        if let live = saved.livePhoto {
            guard mode == .photo, !live || profile.allowsLivePhoto(format: current.format) else {
                throw ControlError.settingUnavailable
            }
            if current.livePhoto == nil { current.livePhoto = try? await readLivePhoto() }
            if current.livePhoto != live {
                // 实况回读只有 type 85，合并进 current，避免冲掉规格/RAW。
                let updated = try await writeLivePhoto(live, isCurrent: isCurrent)
                current.livePhoto = updated.livePhoto
            }
        }
        guard isCurrent() else { throw CancellationError() }
        // 逐项写入已各自确认；不再做整组终检（残留 Max 等会导致 Auto 套用误失败）。
        return current
    }
}
