import Foundation
import LunaTransportApple
import LunaTransportProtocol
import OpenCineCore
import XCTest
@testable import LunaScope

final class ConsoleControlsTests: XCTestCase {
    @MainActor
    private func ultraProfile() throws -> ConsoleCameraProfile {
        try XCTUnwrap(ConsoleCameraProfile.matching("Insta360 Luna Ultra"))
    }

    /// 画面项的模式归属和恢复默认值都来自机型 JSON。
    @MainActor
    func testImageControlsDeclareModeMembershipAndDefaults() throws {
        let ultra = try ultraProfile()
        let pro = try XCTUnwrap(ConsoleCameraProfile.matching("Insta360 Luna Pro"))
        let recording: [LunaShootingMode] = [.video, .pureVideo, .slowMotion, .timelapse, .timeShift]
        let ids = ["metering", "focus", "breathingCompensation", "contrast", "saturation", "sharpness", "color"]
        for profile in [ultra, pro] {
            for mode in recording {
                let controls = profile.imageControls(for: mode)
                XCTAssertEqual(controls.map(\.id), ids)
                XCTAssertTrue(controls.allSatisfy { $0.choices.contains($0.defaultValue) })
                XCTAssertEqual(profile.focusChoices(for: mode).map(\.rawValue), [1, 3, 6])
                XCTAssertEqual(controls.first { $0.id == "breathingCompensation" }?.defaultValue, 0)
                XCTAssertEqual(controls.first { $0.id == "contrast" }?.defaultValue, 3)
                XCTAssertEqual(controls.first { $0.id == "saturation" }?.defaultValue, 3)
                XCTAssertEqual(controls.first { $0.id == "sharpness" }?.defaultValue, 1)
                XCTAssertEqual(controls.first { $0.id == "metering" }?.defaultValue, 1)
                XCTAssertEqual(controls.first { $0.id == "color" }?.defaultValue, 1)
                let contrast = try XCTUnwrap(controls.first { $0.id == "contrast" })
                XCTAssertFalse(contrast.isVisible { $0 == "color" ? 2 : nil })
                XCTAssertTrue(contrast.isVisible { $0 == "color" ? 1 : nil })
            }
            for mode in [LunaShootingMode.photo, .pano] {
                XCTAssertEqual(profile.imageControls(for: mode).map(\.id), mode == .photo ? ["metering", "focus"] : ["focus"])
                if mode == .photo {
                    XCTAssertEqual(profile.imageControls(for: mode).first { $0.id == "metering" }?.defaultValue, 1)
                }
                XCTAssertEqual(profile.focusChoices(for: mode).map(\.rawValue), [1, 3])
                XCTAssertTrue(profile.colorChoices(for: nil, mode: mode).isEmpty)
            }
            var photo = ConsoleParameters(mode: .photo)
            photo.autofocus = LunaAFMode.productShowcase.rawValue
            photo.contrast = 5
            photo.color = 2
            let dropped = photo.restorable(for: profile)
            XCTAssertNil(dropped.autofocus)
            XCTAssertNil(dropped.contrast)
            XCTAssertNil(dropped.color)

            var video = ConsoleParameters(mode: .video)
            video.autofocus = LunaAFMode.productShowcase.rawValue
            video.contrast = 5
            video.color = 1
            let kept = video.restorable(for: profile)
            XCTAssertEqual(kept.autofocus, LunaAFMode.productShowcase.rawValue)
            XCTAssertEqual(kept.contrast, 5)
            XCTAssertEqual(kept.color, 1)
        }
    }

    /// 快门按官方口播刻度，色温 2000–10000、每 200 K 一档。
    @MainActor
    func testExposureRulersMatchOfficialApp() throws {
        let ultra = try ultraProfile()
        let pro = try XCTUnwrap(ConsoleCameraProfile.matching("Insta360 Luna Pro"))
        let photo = ultra.shutterChoices(mode: .photo, format: nil)
        let videoFormat = try XCTUnwrap(ultra.video(for: .video).first { $0.framesPerSecond == 25 })
        let video = ultra.shutterChoices(mode: .video, format: videoFormat.rawValue)
        XCTAssertEqual(photo, video)
        XCTAssertEqual(photo, pro.shutterChoices(mode: .photo, format: nil))
        XCTAssertEqual(try XCTUnwrap(photo.first), 1.0 / 8000, accuracy: 0.000_000_1)
        XCTAssertEqual(try XCTUnwrap(photo.last), 30, accuracy: 0.001)
        XCTAssertTrue(photo.contains { abs($0 - 1.0 / 240) < 0.000_000_1 })
        XCTAssertTrue(photo.contains { abs($0 - 1.0 / 120) < 0.000_000_1 })
        XCTAssertTrue(photo.contains { abs($0 - 1.0 / 12.5) < 0.000_000_1 })
        XCTAssertTrue(photo.contains { abs($0 - 1.0 / 6.25) < 0.000_000_1 })
        XCTAssertTrue(photo.contains { abs($0 - 1.0 / 1.67) < 0.000_01 })
        XCTAssertTrue(photo.contains { abs($0 - 7) < 0.001 })
        XCTAssertTrue(photo.contains { abs($0 - 9) < 0.001 })
        XCTAssertFalse(photo.contains { abs($0 - 0.25) < 0.001 })
        XCTAssertEqual(ConsoleManualExposure.shutterLabel(1.0 / 12.5), "1/12.5")
        XCTAssertEqual(ConsoleManualExposure.shutterLabel(1.0 / 6.25), "1/6.25")
        XCTAssertEqual(ConsoleManualExposure.shutterLabel(1.0 / 2.5), "1/2.5")
        XCTAssertEqual(ConsoleManualExposure.shutterLabel(1.0 / 1.67), "1/1.67")
        XCTAssertEqual(ConsoleManualExposure.shutterLabel(1.0 / 1.25), "1/1.25")
        XCTAssertTrue(ConsoleManualExposure.shutterLabel(1.3).contains("1.3"))
        XCTAssertTrue(ConsoleManualExposure.shutterLabel(3.2).contains("3.2"))
        XCTAssertTrue(ConsoleManualExposure.shutterLabel(7).hasPrefix("7"))
        XCTAssertFalse(ConsoleManualExposure.shutterLabel(7).contains("."))

        let iso: [UInt64] = [100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 6400]
        XCTAssertEqual(ultra.exposure.iso, iso)
        XCTAssertEqual(pro.exposure.iso, iso)
        XCTAssertEqual(ultra.exposure.isoMax, [400, 800, 1600, 3200, 6400])

        XCTAssertEqual(ultra.whiteBalance.choices.first, 2000)
        XCTAssertEqual(ultra.whiteBalance.choices.last, 10000)
        XCTAssertEqual(ultra.whiteBalance.choices, pro.whiteBalance.choices)
        XCTAssertEqual(ultra.whiteBalance.choices.count, 41)
        XCTAssertFalse(ultra.whiteBalance.choices.contains(2100))
    }

    @MainActor
    func testPresetStoreRoundTripsMultipleNamedSetsAndOnlyTheLatestPosition() throws {
        let suite = "ConsoleControlsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConsoleMemoryStore(defaults: defaults)
        let cameraID = UUID()
        var video = ConsoleParameters(mode: .video)
        video.format = 24
        video.exposure = .init(program: .manual, iso: 800, shutter: 1.0 / 60)
        var photo = ConsoleParameters(mode: .photo)
        photo.format = 33
        photo.whiteBalance = 5600
        let first = ConsoleMemory.Preset(id: UUID(), name: "Video", savedAt: .now, parameters: video)
        let second = ConsoleMemory.Preset(id: UUID(), name: "Photo", savedAt: .now, parameters: photo)
        let a = try XCTUnwrap(ConsoleGimbalPosition(cameraID: cameraID, yaw: 20, pitch: -10))
        let b = try XCTUnwrap(ConsoleGimbalPosition(cameraID: cameraID, yaw: -178, pitch: 15, isFlipped: true))

        try store.save(.init(lastPosition: a, presets: [first]))
        XCTAssertNil(try store.load().lastPosition?.isFlipped)
        try store.save(.init(lastPosition: b, presets: [second, first]))
        let controller = CameraController(memoryStore: store)
        XCTAssertEqual(controller.memory.lastPosition, b)
        XCTAssertEqual(controller.memory.presets, [second, first])
        controller.deletePreset(first.id)
        let reopened = try store.load()
        XCTAssertEqual(reopened.presets, [second])
        XCTAssertEqual(reopened.lastPosition, b)
    }

    @MainActor
    func testMovePresetsPersistsReorderedList() throws {
        let suite = "ConsoleControlsTests.move." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConsoleMemoryStore(defaults: defaults)
        let first = ConsoleMemory.Preset(id: UUID(), name: "A", savedAt: .now, parameters: ConsoleParameters(mode: .video))
        let second = ConsoleMemory.Preset(id: UUID(), name: "B", savedAt: .now, parameters: ConsoleParameters(mode: .photo))
        try store.save(.init(presets: [first, second]))
        let controller = CameraController(memoryStore: store)
        controller.movePresets(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(controller.memory.presets.map(\.id), [second.id, first.id])
        XCTAssertEqual(try store.load().presets.map(\.id), [second.id, first.id])
    }

    @MainActor
    func testPresetDetailSummaryIncludesExposureWhiteBalanceAndFrameRate() throws {
        let profile = try ultraProfile()
        let videoCode = try XCTUnwrap(profile.video(for: .video).first?.rawValue)
        var video = ConsoleParameters(mode: .video)
        video.format = videoCode
        video.exposure = .init(program: .manual, iso: 800, shutter: 1.0 / 60)
        video.whiteBalance = 5600
        video.color = LunaColorMode.standard.rawValue
        video.zoom = 1.5
        let summary = video.detailSummary(profile: profile)
        XCTAssertTrue(summary.contains(LunaShootingMode.video.label), summary)
        XCTAssertTrue(summary.contains("ISO 800"), summary)
        XCTAssertTrue(summary.contains("1/60"), summary)
        XCTAssertTrue(summary.contains("5600 K"), summary)
        XCTAssertTrue(summary.contains("1.5×") || summary.contains("1.5x"), summary)
        XCTAssertTrue(summary.contains("fps") || summary.contains("帧"), summary)

        var photo = ConsoleParameters(mode: .photo)
        photo.format = try XCTUnwrap(profile.photoFormats.first?.id)
        photo.exposure = .init(iso: nil, shutter: nil, isoTopLimit: 1600)
        photo.rawCapture = true
        photo.livePhoto = true
        photo.autofocus = LunaAFMode.continuous.rawValue
        let photoSummary = photo.detailSummary(profile: profile)
        XCTAssertTrue(photoSummary.contains("ISO"), photoSummary)
        XCTAssertTrue(photoSummary.contains("RAW"), photoSummary)
        XCTAssertTrue(photoSummary.contains(String(localized: "console.livePhoto.title")), photoSummary)
        XCTAssertTrue(photoSummary.contains(String(localized: "console.settings.continuousAF")), photoSummary)

        var unknown = ConsoleParameters(mode: .video)
        unknown.format = 9_999_999
        unknown.exposure = .init(iso: 400, shutter: nil)
        let fallback = unknown.detailSummary(profile: profile)
        XCTAssertTrue(fallback.contains("9999999") || fallback.contains("9,999,999"), fallback)
        XCTAssertTrue(fallback.contains("ISO 400"), fallback)

        var continuous = ConsoleParameters(mode: .photo)
        continuous.format = try XCTUnwrap(profile.livePhotoFormatIDs.first)
        continuous.continuousPhoto = true
        continuous.continuousInterval = ConsoleShootInterval(selection: .preset(5))
        continuous.livePhoto = true
        let continuousSummary = continuous.detailSummary(profile: profile)
        XCTAssertTrue(
            continuousSummary.hasPrefix(String(localized: "console.mode.continuousPhoto")),
            continuousSummary
        )
        XCTAssertTrue(continuousSummary.contains(String(localized: "console.interval.seconds \(5)")), continuousSummary)
        XCTAssertTrue(continuousSummary.contains(String(localized: "console.livePhoto.title")), continuousSummary)
        let restored = continuous.restorable(for: profile)
        XCTAssertEqual(restored.continuousPhoto, true)
        XCTAssertEqual(restored.continuousInterval?.seconds, 5)
        XCTAssertEqual(restored.livePhoto, true)
    }

    @MainActor
    func testContinuousPhotoPresetRoundTripsThroughMemoryStore() throws {
        let suite = "ConsoleControlsTests.continuousPreset." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConsoleMemoryStore(defaults: defaults)
        var photo = ConsoleParameters(mode: .photo)
        photo.format = 34
        photo.continuousPhoto = true
        photo.continuousInterval = ConsoleShootInterval(selection: .preset(10))
        let preset = ConsoleMemory.Preset(id: UUID(), name: "连拍", savedAt: .now, parameters: photo)
        try store.save(.init(presets: [preset]))
        let loaded = try XCTUnwrap(store.load().presets.first)
        XCTAssertEqual(loaded.parameters.continuousPhoto, true)
        XCTAssertEqual(loaded.parameters.continuousInterval?.seconds, 10)
    }

    @MainActor
    func testContinuousPreferenceDecodesWhenMissingFromOlderMemory() throws {
        let suite = "ConsoleControlsTests.continuousPreference." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConsoleMemoryStore(defaults: defaults)
        let legacy = try JSONEncoder().encode(LegacyConsoleMemory(presets: []))
        defaults.set(legacy, forKey: "feature.console.memory")
        let loaded = try store.load()
        XCTAssertFalse(loaded.continuousPhoto)
        XCTAssertNil(loaded.continuousInterval)
        XCTAssertTrue(loaded.continuousGimbalReturn)

        var saved = loaded
        saved.continuousPhoto = true
        saved.continuousInterval = ConsoleShootInterval(selection: .preset(30))
        saved.continuousGimbalReturn = false
        let remembered = ConsoleGimbalPosition(cameraID: UUID(), yaw: 12, pitch: -3, isFlipped: false)
        saved.lastPosition = remembered
        try store.save(saved)
        let restored = try store.load()
        XCTAssertTrue(restored.continuousPhoto)
        XCTAssertEqual(restored.continuousInterval?.seconds, 30)
        XCTAssertFalse(restored.continuousGimbalReturn)
        XCTAssertEqual(restored.lastPosition, remembered)
    }

    @MainActor
    func testRenamePresetPersistsNewName() throws {
        let suite = "ConsoleControlsTests.rename." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConsoleMemoryStore(defaults: defaults)
        let preset = ConsoleMemory.Preset(id: UUID(), name: "旧名", savedAt: .now, parameters: ConsoleParameters(mode: .video))
        try store.save(.init(presets: [preset]))
        let controller = CameraController(memoryStore: store)
        controller.renamePreset(preset.id, name: "  夜景  ")
        XCTAssertEqual(controller.memory.presets.first?.name, "夜景")
        XCTAssertEqual(try store.load().presets.first?.name, "夜景")
        controller.renamePreset(preset.id, name: "   ")
        XCTAssertEqual(try store.load().presets.first?.name, "")
    }

    @MainActor
    func testGimbalPositionRejectsLimitsAndUsesNativeReadbackAcrossWrap() throws {
        let camera = UUID()
        XCTAssertNil(ConsoleGimbalPosition(cameraID: camera, yaw: -90, pitch: 0))
        XCTAssertNil(ConsoleGimbalPosition(cameraID: camera, yaw: 20, pitch: 91))
        XCTAssertNil(ConsoleGimbalPosition(cameraID: camera, yaw: .nan, pitch: 0))
        let position = try XCTUnwrap(ConsoleGimbalPosition(cameraID: camera, yaw: 179.9, pitch: 12))
        XCTAssertTrue(position.matchesAngles(.init(pitch: 12.1, yaw: -179.9)))
        // 只比角度：贴着行程尽头的记忆点，相机到了也可能一直回 grf = 1。
        XCTAssertTrue(position.matchesAngles(.init(grf: 1, pitch: 12.1, yaw: -179.9)))
        XCTAssertFalse(position.matchesAngles(.init(pitch: 14, yaw: -179.9)))
    }

    @MainActor
    func testGimbalRestoreOnlyHomesAndReportsFlipMismatch() async throws {
        let wire = GimbalWire()
        let commands = wire.commands()
        let cameraID = UUID()
        let forward = try XCTUnwrap(ConsoleGimbalPosition(cameraID: cameraID, yaw: 20, pitch: 10, isFlipped: false))

        // 本会话还没确认朝向：不因为记忆里的翻转标记就拒绝定位。
        wire.angle = .init(pitch: 10, yaw: 20)
        let rememberedFlip = try XCTUnwrap(ConsoleGimbalPosition(cameraID: cameraID, yaw: 20, pitch: 10, isFlipped: true))
        let unknown = try await commands.restore(rememberedFlip, currentFlip: nil)
        XCTAssertEqual(unknown, .arrived)
        XCTAssertTrue(wire.moves.isEmpty)

        // 不一致：只提示，不归位、不自动翻转。
        wire.angle = .init(pitch: 0, yaw: 180)
        let mismatched = try await commands.restore(forward, currentFlip: true)
        XCTAssertEqual(mismatched, .flipMismatch)
        XCTAssertTrue(wire.moves.isEmpty)

        // 一致：只归位。
        wire.angle = .init(pitch: 1, yaw: 5)
        let matched = try await commands.restore(forward, currentFlip: false)
        XCTAssertEqual(matched, .arrived)
        XCTAssertEqual(wire.moves, [.setAngle])
        XCTAssertTrue(forward.matchesAngles(wire.angle))

        // 记忆没写翻转、当前已翻转：提示不一致，不转动。
        wire.moves = []
        wire.angle = .init(pitch: 0, yaw: 0)
        let anglesOnly = try XCTUnwrap(ConsoleGimbalPosition(cameraID: cameraID, yaw: 30, pitch: 6))
        let flippedNow = try await commands.restore(anglesOnly, currentFlip: true)
        XCTAssertEqual(flippedNow, .flipMismatch)
        XCTAssertTrue(wire.moves.isEmpty)

        // 记忆没写翻转、当前正向：只归位。
        let noFlip = try await commands.restore(anglesOnly, currentFlip: false)
        XCTAssertEqual(noFlip, .arrived)
        XCTAssertEqual(wire.moves, [.setAngle])
    }

    /// 记忆点够不着：云台停在行程尽头、相机一直回 grf = 1。定位要很快结束，并把目标改到当前角度。
    @MainActor
    func testGimbalRestoreStopsAtTheEdgeAndClearsThePendingTarget() async throws {
        let wire = GimbalWire()
        wire.yawStop = 60
        wire.angle = .init(pitch: 1, yaw: 5)
        let commands = wire.commands()
        let cameraID = UUID()
        let beyond = try XCTUnwrap(ConsoleGimbalPosition(cameraID: cameraID, yaw: 100, pitch: 10))

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await commands.restore(beyond, currentFlip: nil)
        XCTAssertEqual(result, .axisLimit)
        XCTAssertLessThan(clock.now - started, .seconds(3))
        // 第二次 SET 是当前角度，相机不再挂着够不着的目标，之后松开摇杆。
        XCTAssertEqual(wire.moves, [.setAngle, .setAngle, .move])
        XCTAssertEqual(wire.angle, .init(pitch: 10, yaw: 60))

        // 停在尽头后仍能记忆位置，下一次定位也不会卡在等待上。
        let saved = try await commands.readPosition(cameraID: cameraID)
        XCTAssertEqual(saved.yaw, 60, accuracy: 0.01)
        wire.moves = []
        let again = try await commands.restore(saved, currentFlip: nil)
        XCTAssertEqual(again, .arrived)
        XCTAssertTrue(wire.moves.isEmpty)
    }

    /// 贴着尽头的记忆点：角度到了但相机不报完成，也算到位，并清掉挂着的目标。
    @MainActor
    func testGimbalRestoreArrivesAtAnEdgePointThatNeverReportsDone() async throws {
        let wire = GimbalWire()
        wire.yawStop = 60
        wire.angle = .init(pitch: 1, yaw: 5)
        let edge = try XCTUnwrap(ConsoleGimbalPosition(cameraID: UUID(), yaw: 60.3, pitch: 10))
        let result = try await wire.commands().restore(edge, currentFlip: nil)
        XCTAssertEqual(result, .arrived)
        XCTAssertEqual(wire.moves, [.setAngle, .setAngle, .move])
        XCTAssertEqual(wire.angle.grf, 0)
    }

    /// 延时摄影的归位：0.5° 以内普通定位不动，精确归位要把这点偏差也对回去。
    @MainActor
    func testExactGimbalRestoreCorrectsDriftInsideTheNormalTolerance() async throws {
        let wire = GimbalWire()
        let commands = wire.commands()
        let start = try XCTUnwrap(ConsoleGimbalPosition(cameraID: UUID(), yaw: 20, pitch: 10))

        wire.angle = .init(pitch: 10.2, yaw: 20.3)
        let coarse = try await commands.restore(start, currentFlip: nil)
        XCTAssertEqual(coarse, .arrived)
        XCTAssertTrue(wire.moves.isEmpty)
        XCTAssertEqual(wire.angle, .init(pitch: 10.2, yaw: 20.3))

        let exact = try await commands.restore(start, currentFlip: nil, exact: true)
        XCTAssertEqual(exact, .arrived)
        XCTAssertEqual(wire.moves, [.setAngle])
        XCTAssertEqual(wire.angle, .init(pitch: 10, yaw: 20))

        // 已经分毫不差时不再发转角。
        wire.moves = []
        let again = try await commands.restore(start, currentFlip: nil, exact: true)
        XCTAssertEqual(again, .arrived)
        XCTAssertTrue(wire.moves.isEmpty)

        // 偏得远：先转到附近，再对准。两步落在同一个角度上。
        wire.angle = .init(pitch: 1, yaw: 5)
        let far = try await commands.restore(start, currentFlip: nil, exact: true)
        XCTAssertEqual(far, .arrived)
        XCTAssertEqual(wire.angle, .init(pitch: 10, yaw: 20))
    }

    /// 精确归位的目标贴着行程尽头、相机一直不报完成：不能每张都等满超时，挂着的目标也要清掉。
    @MainActor
    func testExactGimbalRestoreGivesUpAtAnEdgePoint() async throws {
        let wire = GimbalWire()
        wire.yawStop = 60
        wire.angle = .init(pitch: 10, yaw: 60)
        let edge = try XCTUnwrap(ConsoleGimbalPosition(cameraID: UUID(), yaw: 60.3, pitch: 10))
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await wire.commands().restore(edge, currentFlip: nil, exact: true)
        XCTAssertEqual(result, .arrived)
        XCTAssertLessThan(clock.now - started, .seconds(3))
        XCTAssertEqual(wire.moves, [.setAngle, .setAngle, .move])
        XCTAssertEqual(wire.angle.grf, 0)
    }

    /// 相机报限位时立刻结束，不等云台停转。
    @MainActor
    func testGimbalRestoreEndsAsSoonAsTheLimitIsReported() async throws {
        let wire = GimbalWire()
        wire.yawStop = 60
        wire.angle = .init(pitch: 1, yaw: 5)
        var commands = wire.commands()
        commands.atAxisLimit = { wire.angle.grf != 0 }
        let beyond = try XCTUnwrap(ConsoleGimbalPosition(cameraID: UUID(), yaw: 100, pitch: 10))
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await commands.restore(beyond, currentFlip: nil)
        XCTAssertEqual(result, .axisLimit)
        XCTAssertLessThan(clock.now - started, .seconds(1))
        XCTAssertEqual(wire.moves, [.setAngle, .setAngle, .move])
    }

    @MainActor
    func testStatusRequestPollsCameraPostureForVerticalShoot() throws {
        let request = try LunaProtocol.statusRequest()
        XCTAssertEqual(request.command, .getOptions)
        let types = try ProtoMessage(request.body).repeatedUnsigned(1, maximumValues: 16)
        XCTAssertEqual(types, [11, 20, 85, 93, 180])
        let posture = try LunaProtocol.postureRequest()
        XCTAssertEqual(try ProtoMessage(posture.body).repeatedUnsigned(1, maximumValues: 8), [93])
    }

    func testCameraPostureMapsUprightToLandscapeAndTiltsToPortrait() {
        // 实测：0 左横 -90°；1 竖立；2 右横 +90°；3 倒立 180°（左横与倒立勿对调）。
        XCTAssertEqual(LunaCameraPosture(wire: 0)?.rotationDegrees, -90)
        XCTAssertEqual(LunaCameraPosture(wire: 1)?.rotationDegrees, 0)
        XCTAssertEqual(LunaCameraPosture(wire: 2)?.rotationDegrees, 90)
        XCTAssertEqual(LunaCameraPosture(wire: 3)?.rotationDegrees, 180)
        XCTAssertFalse(LunaCameraPosture.upright.swapsAspect)
        XCTAssertFalse(LunaCameraPosture.upsideDown.swapsAspect)
        XCTAssertTrue(LunaCameraPosture.tiltLeft.swapsAspect)
        XCTAssertTrue(LunaCameraPosture.tiltRight.swapsAspect)
    }

    @MainActor
    func testFormatChoicesKeepCadenceAndWritePhotoGeometryTogether() throws {
        let landscape = try XCTUnwrap(LunaVideoResolution(rawValue: 48))
        let all = try ultraProfile().video(for: .video)
        let portrait = ConsoleCaptureFormats.closestVideo(all.filter { $0.aspectLabel == "9:16" }, to: landscape)
        XCTAssertEqual(portrait?.rawValue, 125)
        XCTAssertFalse(try ultraProfile().supports(211, in: .pureVideo))
        XCTAssertFalse(try ultraProfile().supports(125, in: .pureVideo))
        XCTAssertFalse(try ultraProfile().supports(48, in: .slowMotion))
        XCTAssertTrue(try ultraProfile().supports(214, in: .slowMotion))

        let photo = try XCTUnwrap(try ultraProfile().photoFormats.first { $0.id == 33 })
        let request = try photo.request()
        let outer = try ProtoMessage(request.body)
        XCTAssertEqual(try outer.repeatedUnsigned(1, maximumValues: 8), [40, 63, 30])
        XCTAssertEqual(try outer.unsigned(3), 6)
        let nested = try ProtoMessage(try XCTUnwrap(outer.optionalBytes(2)))
        XCTAssertEqual(try nested.unsigned(30), 4)
        XCTAssertEqual(try nested.unsigned(40), 33)
    }

    @MainActor
    func testLunaUltraZoomUsesOfficialStopsAndModeLimits() throws {
        let domain = SettingDomain(range: 1...15)
        let standard = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: 48, domain: domain))
        XCTAssertEqual(standard.stops, [1, 2, 3, 6, 12, 15])
        XCTAssertEqual(standard.fineRange, 1...15)
        XCTAssertEqual(ConsoleZoom.quantize(2.974), 2.975)

        let fast = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: 214, domain: domain))
        XCTAssertEqual(fast.stops, [1, 3])
        XCTAssertNil(fast.fineRange)
        XCTAssertFalse(fast.allows(2))
        for mode: LunaShootingMode in [.slowMotion, .timelapse, .timeShift] {
            let zoom = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: mode, format: nil, domain: domain))
            XCTAssertEqual(zoom.stops, [1, 3])
            XCTAssertNil(zoom.fineRange)
        }
        let limited = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .photo, format: nil, domain: SettingDomain(range: 1...12)))
        XCTAssertEqual(limited.stops, [1, 2, 3, 6, 12])
        XCTAssertFalse(limited.allows(15))
        XCTAssertNil(ConsoleZoom(profile: try ultraProfile(), mode: .pano, format: nil, domain: domain))
        XCTAssertNil(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: nil, domain: domain))
    }

    @MainActor
    func testZoomLogPositionSpacesDoublingsEvenlyAndStaysInsideRange() throws {
        let domain = SettingDomain(range: 1...15)
        let zoom = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: 48, domain: domain))
        let one = try XCTUnwrap(zoom.unitPosition(of: 1))
        let two = try XCTUnwrap(zoom.unitPosition(of: 2))
        let four = try XCTUnwrap(zoom.unitPosition(of: 4))
        let six = try XCTUnwrap(zoom.unitPosition(of: 6))
        let twelve = try XCTUnwrap(zoom.unitPosition(of: 12))
        XCTAssertEqual(one, 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(zoom.unitPosition(of: 15)), 1, accuracy: 0.0001)
        XCTAssertEqual(two, (one + four) / 2, accuracy: 0.0001)
        XCTAssertEqual(two - one, twelve - six, accuracy: 0.0001)

        XCTAssertEqual(zoom.factor(atUnitPosition: -1), zoom.fineRange?.lowerBound)
        XCTAssertEqual(zoom.factor(atUnitPosition: 2), zoom.fineRange?.upperBound)
        var previous = -1.0
        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
            let factor = try XCTUnwrap(zoom.factor(atUnitPosition: position))
            XCTAssertGreaterThanOrEqual(factor, previous)
            XCTAssertTrue(try XCTUnwrap(zoom.fineRange).contains(factor))
            previous = factor
        }

        let fixed = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: 214, domain: domain))
        XCTAssertNil(fixed.unitPosition(of: 1))
        XCTAssertNil(fixed.factor(atUnitPosition: 0.5))
        XCTAssertTrue(fixed.offersChoice)
    }

    @MainActor
    func testLunaUltraZoomKeepsCurrentLensWhenRecording8KOrPortrait4K() throws {
        let domain = SettingDomain(range: 1...15)
        let portrait = try XCTUnwrap(LunaVideoResolution.rawValue(width: 2160, height: 3840, framesPerSecond: 30))
        for format in [211, portrait] {
            let preview = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: format, domain: domain))
            XCTAssertEqual(preview.stops, [1, 2, 3, 6])
            XCTAssertEqual(preview.fineRange, 1...6)
            let main = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: format, domain: domain,
                                                 recording: true, reportedZoom: 2.9))
            XCTAssertEqual(main.stops, [1, 2])
            XCTAssertEqual(main.fineRange, 1...2.975)
            XCTAssertTrue(main.allows(2.975))
            XCTAssertFalse(main.allows(3))
            let tele = try XCTUnwrap(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: format, domain: domain,
                                                 recording: true, reportedZoom: 3))
            XCTAssertEqual(tele.stops, [3, 6])
            XCTAssertEqual(tele.fineRange, 3...6)
            XCTAssertFalse(tele.allows(2.975))
            XCTAssertNil(ConsoleZoom(profile: try ultraProfile(), mode: .video, format: format, domain: domain, recording: true))
        }
    }

    func testISOAndShutterAutomaticSelectionsDetermineExposureProgram() {
        let shutter = 1.0 / 60
        XCTAssertEqual(ConsoleExposure(iso: nil, shutter: nil).program, .automatic)
        XCTAssertEqual(ConsoleExposure(iso: 400, shutter: nil).program, .isoPriority)
        XCTAssertEqual(ConsoleExposure(iso: nil, shutter: shutter).program, .shutterPriority)
        XCTAssertEqual(ConsoleExposure(iso: 400, shutter: shutter).program, .manual)
        let capped = ConsoleExposure(iso: nil, shutter: nil, isoTopLimit: 800)
        XCTAssertEqual(capped.program, .automatic)
        XCTAssertEqual(capped.isoTopLimit, 800)
        XCTAssertNil(ConsoleExposure(iso: 400, shutter: nil, isoTopLimit: 800).isoTopLimit)
    }

    func testContinuousIntervalPresetsAndCustomParsing() {
        XCTAssertEqual(ConsoleShootInterval.presets.first, 1)
        XCTAssertEqual(ConsoleShootInterval().seconds, 5)
        XCTAssertEqual(ConsoleShootInterval(selection: .preset(1)).seconds, 1)
        XCTAssertEqual(ConsoleShootInterval(selection: .preset(30)).seconds, 30)
        XCTAssertEqual(ConsoleShootInterval.custom(amount: 2, unit: .minutes), .custom(120))
        XCTAssertEqual(ConsoleShootInterval.custom(amount: 1.5, unit: .seconds), .custom(1.5))
        XCTAssertNil(ConsoleShootInterval.custom(amount: 0, unit: .seconds))
        XCTAssertNil(ConsoleShootInterval.custom(amount: 61, unit: .minutes))
        XCTAssertTrue(ConsoleShootInterval(selection: .custom(12)).isCustom)
        XCTAssertFalse(ConsoleShootInterval(selection: .preset(10)).isCustom)
    }

    func testContinuousCaptureUsesFixedInterval() {
        let fired = Date(timeIntervalSince1970: 1_000)
        let next = ConsoleContinuousCapture.nextTrigger(firedAt: fired, interval: 10)
        XCTAssertEqual(next.timeIntervalSince(fired), 10, accuracy: 0.001)
        let invalid = ConsoleContinuousCapture.nextTrigger(firedAt: fired, interval: .nan)
        XCTAssertEqual(invalid, fired)
    }

    @MainActor
    func testExposureBiasAndMeteringReadbackDistinguishDefaultsFromOmittedOptions() throws {
        let biasRequest = try LunaProtocol.setExposureBias(-0.7, functionMode: LunaFunctionMode.normalImage.rawValue)
        let faceRequest = try LunaProtocol.setFaceMetering(true)
        var parameters = ConsoleParameters(mode: .photo)
        parameters.ingest(try LunaPhotographySettings(response: biasRequest.body))
        parameters.ingest(try LunaPhotographySettings(response: faceRequest.body))
        XCTAssertEqual(parameters.exposureBiasTenths, -7)
        XCTAssertEqual(parameters.faceMetering, true)

        let defaults = try ProtoMessage.integer(field: 1, value: 7) + ProtoMessage.integer(field: 1, value: 46)
        parameters.ingest(try LunaPhotographySettings(response: defaults))
        XCTAssertEqual(parameters.exposureBiasTenths, 0)
        XCTAssertEqual(parameters.faceMetering, false)

        let unrelated = try LunaPhotographySettings(response: Data())
        XCTAssertNil(unrelated.exposureBiasTenths)
        XCTAssertNil(unrelated.faceMetering)
        let decoded = try JSONDecoder().decode(ConsoleParameters.self, from: JSONEncoder().encode(parameters))
        XCTAssertEqual(decoded.exposureBiasTenths, 0)
        XCTAssertEqual(decoded.faceMetering, false)
        XCTAssertTrue(decoded.isConfirmed(by: parameters))
    }

    @MainActor
    func testManualExposureWritesBothStillAndVideoFields() throws {
        let exposure = ConsoleExposure(program: .manual, iso: 400, shutter: 1.0 / 60)
        let request = try exposure.request(mode: .photo)
        let body = try ProtoMessage(request.body)
        let options = try ProtoMessage(try XCTUnwrap(body.optionalBytes(2)))
        let still = try XCTUnwrap(options.optionalBytes(20))
        let video = try XCTUnwrap(options.optionalBytes(21))
        let value = try ProtoMessage(still)
        XCTAssertEqual(video, still)
        XCTAssertEqual(try value.unsigned(1), 3)
        XCTAssertEqual(try value.unsigned(2), 400)
        XCTAssertEqual(try value.double(3), 1.0 / 60, accuracy: 1e-8)

        let snapshot = try LunaPhotographySettings(response: request.body)
        var photo = ConsoleParameters(mode: .photo)
        photo.ingest(snapshot)
        XCTAssertTrue(exposure.matches(photo.exposure))
        photo.autofocus = 7
        photo.format = 99
        let remembered = photo.restorable(for: try ultraProfile())
        XCTAssertNil(remembered.autofocus)
        XCTAssertNil(remembered.format)
        XCTAssertEqual(remembered.exposure, exposure)
    }

    @MainActor
    func testISOMaxWritesTopLimitAndReadsBack() throws {
        let profile = try ultraProfile()
        XCTAssertEqual(profile.exposure.isoMax, [400, 800, 1600, 3200, 6400])
        let exposure = ConsoleExposure(iso: nil, shutter: nil, isoTopLimit: 1600)
        let request = try exposure.request(mode: .video)
        let types = try ProtoMessage(request.body).repeatedUnsigned(1, maximumValues: 8)
        XCTAssertEqual(types.map(UInt32.init(truncatingIfNeeded:)), [21, 24, 100])
        let options = try ProtoMessage(try XCTUnwrap(ProtoMessage(request.body).optionalBytes(2)))
        XCTAssertEqual(try options.unsigned(24), 1600)
        let video = try ProtoMessage(try XCTUnwrap(options.optionalBytes(21)))
        XCTAssertEqual(try video.unsigned(1, default: 0), 0)

        let snapshot = try LunaPhotographySettings(response: request.body)
        var parameters = ConsoleParameters(mode: .video)
        parameters.ingest(snapshot)
        XCTAssertTrue(exposure.matches(parameters.exposure))
        XCTAssertEqual(parameters.restorable(for: profile).exposure?.isoTopLimit, 1600)
    }

    /// 照片回读若 still 仍是空默认包，应回退到已更新的 video 曝光再确认。
    @MainActor
    func testPhotoIngestFallsBackFromEmptyStillToVideoExposure() throws {
        let exposure = ConsoleExposure(program: .manual, iso: 800, shutter: 1.0 / 125)
        let videoBody = try ProtoMessage.integer(field: 1, value: 3)
            + ProtoMessage.integer(field: 2, value: 800)
            + ProtoMessage.double(field: 3, value: 1.0 / 125)
        let nested = try ProtoMessage.blob(field: 20, value: Data())
            + ProtoMessage.blob(field: 21, value: videoBody)
        let response = try ProtoMessage.blob(field: 2, value: nested)
            + ProtoMessage.integer(field: 3, value: 6)
        let snapshot = try LunaPhotographySettings(response: response)
        var photo = ConsoleParameters(mode: .photo)
        photo.ingest(snapshot)
        XCTAssertTrue(exposure.matches(photo.exposure))
    }

    /// still 还是旧值、video 已更新时，确认应认 video，不能被旧 still 误杀。
    @MainActor
    func testExposureConfirmAcceptsUpdatedVideoWhileStillIsStale() throws {
        let expected = ConsoleExposure(program: .isoPriority, iso: 800, shutter: nil)
        let staleStill = try ProtoMessage.integer(field: 1, value: 1)
            + ProtoMessage.integer(field: 2, value: 200)
        let freshVideo = try ProtoMessage.integer(field: 1, value: 1)
            + ProtoMessage.integer(field: 2, value: 800)
        let nested = try ProtoMessage.blob(field: 20, value: staleStill)
            + ProtoMessage.blob(field: 21, value: freshVideo)
        let response = try ProtoMessage.blob(field: 2, value: nested)
            + ProtoMessage.integer(field: 3, value: 6)
        let settings = try LunaPhotographySettings(response: response)
        let matched = try XCTUnwrap(expected.matchedReport(in: settings))
        XCTAssertEqual(matched.iso, 800)
        XCTAssertTrue(expected.matches(matched))
    }

    @MainActor
    func testShutterMatchAcceptsNearbyDenominatorReadback() {
        let expected = ConsoleExposure(iso: 400, shutter: 1.0 / 60)
        let observed = ConsoleExposure(iso: 400, shutter: 1.0 / 59.8)
        XCTAssertTrue(expected.matches(observed))
        XCTAssertFalse(expected.matches(ConsoleExposure(iso: 400, shutter: 1.0 / 50)))
    }

    /// 无上限 Auto 必须写 24=0 清残留 Max；旧 -3200 sentinel 机身常忽略，回读仍 3200 会确认失败。
    @MainActor
    func testUncappedAutomaticClearsISOTopLimit() throws {
        let exposure = ConsoleExposure(iso: nil, shutter: nil)
        let request = try exposure.request(mode: .video)
        let types = try ProtoMessage(request.body).repeatedUnsigned(1, maximumValues: 8)
        XCTAssertEqual(types.map(UInt32.init(truncatingIfNeeded:)), [21, 24, 100])
        let options = try ProtoMessage(try XCTUnwrap(ProtoMessage(request.body).optionalBytes(2)))
        XCTAssertEqual(try options.unsigned(24), 0)
        XCTAssertEqual(try options.optionalBytes(21), Data())

        let snapshot = try LunaPhotographySettings(response: request.body)
        var parameters = ConsoleParameters(mode: .video)
        parameters.ingest(snapshot)
        XCTAssertTrue(exposure.matches(parameters.exposure))
        XCTAssertNil(parameters.exposure?.isoTopLimit)
    }

    /// 快门优先且无上限时不带 24，避免误发 sentinel；确认不因机身仍有 Max 失败。
    @MainActor
    func testShutterPriorityWithoutCeilingOmitsISOTopLimit() throws {
        let exposure = ConsoleExposure(iso: nil, shutter: 1.0 / 60)
        let request = try exposure.request(mode: .video)
        let types = try ProtoMessage(request.body).repeatedUnsigned(1, maximumValues: 8)
        XCTAssertEqual(types.map(UInt32.init(truncatingIfNeeded:)), [21, 100])
        let options = try ProtoMessage(try XCTUnwrap(ProtoMessage(request.body).optionalBytes(2)))
        XCTAssertFalse(options.fields.contains { $0.number == 24 })
        let video = try ProtoMessage(try XCTUnwrap(options.optionalBytes(21)))
        XCTAssertEqual(try video.unsigned(1), 2)
        XCTAssertEqual(try video.double(3), 1.0 / 60, accuracy: 1e-8)

        let withResidualMax = ConsoleExposure(iso: nil, shutter: 1.0 / 60, isoTopLimit: 3200)
        XCTAssertTrue(exposure.matches(withResidualMax))
        // 无上限 Auto 也容忍残留 Max，避免套用/切自动被回读卡死。
        let uncapped = ConsoleExposure(iso: nil, shutter: nil)
        let capped = ConsoleExposure(iso: nil, shutter: nil, isoTopLimit: 3200)
        XCTAssertTrue(uncapped.matches(capped))
        // 但用户意图必须区分：否则 Max→Auto 会在 setExposure 里被当成「已是目标」跳过。
        XCTAssertFalse(uncapped.matchesIntent(capped))
        XCTAssertTrue(uncapped.matchesIntent(uncapped))
        XCTAssertTrue(capped.matchesIntent(capped))
    }

    @MainActor
    func testWriteWaitsForCameraReadbackAndStopsWhenModeChanges() async throws {
        let wire = Wire()
        let session = LunaCameraSession(send: { try await wire.send($0) }, functionMode: { 7 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let commands = ConsoleCameraCommands(session: session, profile: try ultraProfile(), checkIdle: { wire.idleChecks += 1 }) { mode in
            guard mode == wire.mode else { throw ControlError.modeChanged }
        }
        let request = try commands.formatRequest(48, in: .video)
        let actual = try await commands.write(request, in: .video, options: [31], settle: .seconds(4)) { $0.format == 48 }
        XCTAssertEqual(actual.format, 48)
        XCTAssertEqual(wire.idleChecks, 1)
        XCTAssertEqual(wire.writes, 1)
        XCTAssertEqual(wire.reads, 2)
        wire.mode = .photo
        do {
            _ = try await commands.write(request, in: .video, options: [31], settle: .seconds(1)) { _ in true }
            XCTFail("A retired mode accepted a write")
        } catch ControlError.modeChanged {
            XCTAssertEqual(wire.writes, 1)
        }
    }

    @MainActor
    func testWriteKeepsPollingThroughEmptyReadbacks() async throws {
        let wire = Wire(emptyReadsBeforeReady: 2)
        let session = LunaCameraSession(send: { try await wire.send($0) }, functionMode: { 7 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let commands = ConsoleCameraCommands(session: session, profile: try ultraProfile(), checkIdle: {}) { _ in }
        let request = try commands.formatRequest(48, in: .video)
        let actual = try await commands.write(request, in: .video, options: [31], settle: .seconds(4)) { $0.format == 48 }
        XCTAssertEqual(actual.format, 48)
        XCTAssertGreaterThanOrEqual(wire.reads, 3)
    }

    @MainActor
    func testWriteCancelsQuietlyWhenSupersededDuringConfirm() async throws {
        let wire = Wire(emptyReadsBeforeReady: 8)
        let session = LunaCameraSession(send: { try await wire.send($0) }, functionMode: { 7 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let commands = ConsoleCameraCommands(session: session, profile: try ultraProfile(), checkIdle: {}) { _ in }
        let request = try commands.formatRequest(48, in: .video)
        var current = true
        let task = Task {
            try await commands.write(request, in: .video, options: [31], settle: .seconds(4),
                                     isCurrent: { current }) { $0.format == 48 }
        }
        try await Task.sleep(for: .milliseconds(350))
        current = false
        do {
            _ = try await task.value
            XCTFail("Superseded write should cancel")
        } catch is CancellationError {
        }
    }

    @MainActor
    func testRAWRequestAndReadbackFollowOfficialWire() throws {
        let on = try ConsoleCaptureFormats.rawRequest(true)
        let outer = try ProtoMessage(on.body)
        XCTAssertEqual(try outer.repeatedUnsigned(1, maximumValues: 8), [25])
        XCTAssertEqual(try outer.unsigned(3), 6)
        let nested = try ProtoMessage(try XCTUnwrap(outer.optionalBytes(2)))
        XCTAssertEqual(try nested.unsigned(25), 1)

        let off = try ConsoleCaptureFormats.rawRequest(false)
        let offNested = try ProtoMessage(try XCTUnwrap(ProtoMessage(off.body).optionalBytes(2)))
        XCTAssertFalse(offNested.fields.contains { $0.number == 25 })

        let types = ProtoMessage.varint(25)
        let jpg = try ProtoMessage.blob(field: 1, value: types)
            + ProtoMessage.blob(field: 2, value: Data())
            + ProtoMessage.integer(field: 3, value: 6)
        var photo = ConsoleParameters(mode: .photo)
        try photo.ingestRAW(response: jpg)
        XCTAssertEqual(photo.rawCapture, false)

        let rawOn = try ProtoMessage.blob(field: 1, value: types)
            + ProtoMessage.blob(field: 2, value: ProtoMessage.integer(field: 25, value: 1))
            + ProtoMessage.integer(field: 3, value: 6)
        try photo.ingestRAW(response: rawOn)
        XCTAssertEqual(photo.rawCapture, true)
        XCTAssertEqual(photo.restorable(for: try ultraProfile()).rawCapture, true)

        var video = ConsoleParameters(mode: .video)
        try video.ingestRAW(response: rawOn)
        XCTAssertNil(video.rawCapture)
        video.rawCapture = true
        XCTAssertNil(video.restorable(for: try ultraProfile()).rawCapture)
    }

    @MainActor
    func testLivePhotoUsesPhotoOption85AndOnlyReportsConfirmedStates() throws {
        for enabled in [false, true] {
            let request = try ConsoleLivePhoto.request(enabled)
            let outer = try ProtoMessage(request.body)
            XCTAssertEqual(try outer.repeatedUnsigned(1, maximumValues: 8), [85])
            XCTAssertEqual(try outer.unsigned(3), 6)
            let settings = try ProtoMessage(try XCTUnwrap(outer.optionalBytes(2)))
            let live = try ProtoMessage(try XCTUnwrap(settings.optionalBytes(85)))
            XCTAssertEqual(try live.unsigned(2), enabled ? 2 : 1)
            var photo = ConsoleParameters(mode: .photo)
            try photo.ingestLivePhoto(response: request.body)
            XCTAssertEqual(photo.livePhoto, enabled)
        }
        XCTAssertNil(ConsoleLivePhoto.enabled(mode: 3))
        XCTAssertTrue(try ultraProfile().allowsLivePhoto(format: 34))
        XCTAssertFalse(try ultraProfile().allowsLivePhoto(format: 33))
        XCTAssertFalse(try ultraProfile().allowsLivePhoto(format: nil))
        var photo = ConsoleParameters(mode: .photo)
        try photo.ingestLivePhoto(response: Data())
        XCTAssertNil(photo.livePhoto)
    }

    @MainActor
    func testPhotoPresetRestoresFormatAndRAWBeforeLivePhoto() async throws {
        let wire = PhotoWire()
        let session = LunaCameraSession(send: { try await wire.send($0) }, functionMode: { 6 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let commands = ConsoleCameraCommands(session: session, profile: try ultraProfile(), checkIdle: {}) { _ in }
        var preset = ConsoleParameters(mode: .photo)
        preset.format = 34
        preset.rawCapture = true
        preset.livePhoto = true
        let settings = try await commands.restore(preset)
        XCTAssertTrue(preset.isConfirmed(by: settings))
        XCTAssertEqual(wire.writes, [[40, 63, 30], [25], [85]])
    }

    @MainActor
    func testInitialPhotoFormatReadsWithoutIdleAndRejectsAnEmptyReply() async throws {
        var count = 0
        let session = LunaCameraSession(send: { request in
            XCTAssertEqual(request.command, .getPhotographyOptions)
            let query = try ProtoMessage(request.body)
            XCTAssertEqual(try query.repeatedUnsigned(1, maximumValues: 8), [25, 40])
            XCTAssertEqual(try query.unsigned(2), 6)
            count += 1
            if count == 1 { return Data() }
            var nested = try ProtoMessage.integer(field: 40, value: 34)
            if count == 3 { nested += try ProtoMessage.integer(field: 25, value: 1) }
            return try ProtoMessage.blob(field: 2, value: nested)
                + ProtoMessage.integer(field: 3, value: 6)
        }, functionMode: { 6 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let commands = ConsoleCameraCommands(session: session, profile: try ultraProfile(), checkIdle: {
            XCTFail("Initial read should not require capture telemetry")
        }) { XCTAssertEqual($0, .photo) }
        do {
            _ = try await commands.readPhotoFormat()
            XCTFail("Empty settings must leave the format unknown")
        } catch ControlError.readbackMismatch {}
        let jpeg = try await commands.readPhotoFormat()
        XCTAssertEqual(jpeg.format, 34)
        XCTAssertEqual(jpeg.rawCapture, false)
        let raw = try await commands.readPhotoFormat()
        XCTAssertEqual(raw.rawCapture, true)
    }

    @MainActor
    func testPresetRestoresSettingsInOrderWithoutMovement() async throws {
        let wire = PresetWire()
        let session = LunaCameraSession(send: { try await wire.send($0) }, functionMode: { 7 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let commands = ConsoleCameraCommands(session: session, profile: try ultraProfile(), checkIdle: {}) { _ in }
        var preset = ConsoleParameters(mode: .video)
        preset.format = 24
        preset.color = 2
        preset.zoom = 3
        preset.exposure = .init(program: .manual, iso: 800, shutter: 1.0 / 60)
        preset.whiteBalance = 5500
        preset.autofocus = 1
        let settings = try await commands.restore(preset)
        XCTAssertTrue(preset.isConfirmed(by: settings))
        XCTAssertEqual(wire.writes, [[35], [53], [21, 100], [39], [93]])
    }

    /// Auto 套用：即使回读仍带残留 Max，也应确认成功并以写入意图保留无上限 Auto。
    @MainActor
    func testWriteExposureAutoSucceedsWithResidualISOTopLimit() async throws {
        let exposure = ConsoleExposure(iso: nil, shutter: nil)
        let request = try exposure.request(mode: .video)
        XCTAssertEqual(try ProtoMessage(request.body).repeatedUnsigned(1, maximumValues: 8).map(UInt32.init(truncatingIfNeeded:)),
                       [21, 24, 100])

        let residual = try ProtoMessage.blob(field: 21, value: Data())
            + ProtoMessage.integer(field: 24, value: 3200)
        let response = try ProtoMessage.blob(field: 2, value: residual)
            + ProtoMessage.integer(field: 3, value: 7)
        let wire = ExposureConfirmWire(response: response)
        let session = LunaCameraSession(send: { try await wire.send($0) }, functionMode: { 7 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let commands = ConsoleCameraCommands(session: session, profile: try ultraProfile(), checkIdle: {}) { _ in }
        let confirmed = try await commands.writeExposure(exposure, in: .video)
        XCTAssertEqual(confirmed.exposure, exposure)
        XCTAssertNil(confirmed.exposure?.isoTopLimit)
    }

}

@MainActor
private final class GimbalWire {
    var isFlipped = false
    var angle = LunaGimbalAngle(pitch: 10, yaw: 20)
    var moves: [LunaGimbalAction] = []
    /// 偏航行程尽头。目标超过它时云台停在这里，GET 一直回 grf = 1，和真机够不着目标时一样。
    var yawStop: Float?

    func commands() -> ConsoleGimbalCommands {
        let session = LunaCameraSession(send: { try self.send($0) }, functionMode: { 7 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        return ConsoleGimbalCommands(session: session, checkIdle: {}, validate: {})
    }

    private func send(_ request: LunaRequest) throws -> Data {
        XCTAssertEqual(request.command, .gimbalControl)
        let body = try ProtoMessage(request.body)
        let action = try XCTUnwrap(LunaGimbalAction(rawValue: body.unsigned(1)))
        switch action {
        case .getAngle:
            let pose = try ProtoMessage.float(field: 3, value: angle.pitch) + ProtoMessage.float(field: 4, value: angle.yaw)
            return try angle.grf == 0 ? pose : ProtoMessage.integer(field: 1, value: UInt64(angle.grf)) + pose
        case .flip:
            isFlipped.toggle()
            angle = .init(pitch: 0, yaw: isFlipped ? 180 : 0)
            moves.append(action)
            return Data()
        case .setAngle:
            let target = try ProtoMessage(body.bytes(5))
            let yaw = try target.float(3)
            let reachable = yawStop.map { yaw <= $0 } ?? true
            angle = try .init(grf: reachable ? 0 : 1, pitch: target.float(2), yaw: reachable ? yaw : yawStop ?? yaw)
            moves.append(action)
            return try ProtoMessage.integer(field: 1, value: 1)
        case .move:
            moves.append(action)
            return Data()
        default:
            XCTFail("Unexpected gimbal action \(action)")
            throw LunaProtocolError.cameraRejectedRequest
        }
    }
}

@MainActor
private final class Wire {
    var mode: LunaShootingMode = .video
    var reads = 0
    var writes = 0
    var idleChecks = 0
    /// 前几次 GET 回空包，之后再给出目标规格，用于验证确认期不会被空包提前打死。
    var emptyReadsBeforeReady = 0

    init(emptyReadsBeforeReady: Int = 0) {
        self.emptyReadsBeforeReady = emptyReadsBeforeReady
    }

    func send(_ request: LunaRequest) async throws -> Data {
        if request.command == .setPhotographyOptions { writes += 1; return Data() }
        reads += 1
        if reads <= emptyReadsBeforeReady {
            return try ProtoMessage.blob(field: 2, value: Data())
                + ProtoMessage.integer(field: 3, value: 7)
        }
        let value = try ProtoMessage.integer(field: 31, value: emptyReadsBeforeReady == 0 && reads == 1 ? 24 : 48)
        return try ProtoMessage.blob(field: 2, value: value)
            + ProtoMessage.integer(field: 3, value: 7)
    }
}


@MainActor
private final class ExposureConfirmWire {
    let response: Data

    init(response: Data) { self.response = response }

    func send(_ request: LunaRequest) async throws -> Data {
        switch request.command {
        case .setPhotographyOptions, .getPhotographyOptions:
            return response
        default:
            XCTFail("Unexpected command \(request.command)")
            throw LunaProtocolError.cameraRejectedRequest
        }
    }
}

@MainActor
private final class PresetWire {
    var writes: [[UInt64]] = []
    private var fields: [UInt64: Data] = [:]

    init() {
        fields = [
            21: try? ProtoMessage.blob(field: 21, value: Data()),
            31: try? ProtoMessage.integer(field: 31, value: 24),
            35: try? ProtoMessage.integer(field: 35, value: 1),
            39: try? ProtoMessage.integer(field: 39, value: 0),
            53: try? ProtoMessage.double(field: 53, value: 1),
            93: try? ProtoMessage.integer(field: 93, value: 3),
        ].compactMapValues { $0 }
    }

    func send(_ request: LunaRequest) async throws -> Data {
        switch request.command {
        case .getPhotographyOptions:
            let values = fields.keys.sorted().compactMap { fields[$0] }
            return try ProtoMessage.blob(field: 2, value: values.reduce(into: Data()) { $0 += $1 })
                + ProtoMessage.integer(field: 3, value: 7)
        case .setPhotographyOptions:
            let body = try ProtoMessage(request.body)
            let ids = try body.repeatedUnsigned(1, maximumValues: 16)
            writes.append(ids)
            let options = try ProtoMessage(try XCTUnwrap(body.optionalBytes(2)))
            for id in ids {
                let field = Int(id)
                switch id {
                case 21:
                    fields[id] = try ProtoMessage.blob(field: field, value: XCTUnwrap(options.optionalBytes(field)))
                case 53:
                    fields[id] = try ProtoMessage.double(field: field, value: options.double(field))
                case 35, 39, 93:
                    fields[id] = try ProtoMessage.integer(field: field, value: options.unsigned(field))
                case 100:
                    break
                default:
                    XCTFail("Unexpected setting field \(id)")
                }
            }
            return Data()
        default:
            XCTFail("Unexpected command during preset restore")
            throw LunaProtocolError.cameraRejectedRequest
        }
    }
}

@MainActor
private final class PhotoWire {
    var writes: [[UInt64]] = []
    private var format: UInt64 = 29
    private var raw: UInt64?
    private var livePhoto = false

    func send(_ request: LunaRequest) async throws -> Data {
        switch request.command {
        case .getPhotographyOptions:
            let types = try ProtoMessage(request.body).repeatedUnsigned(1, maximumValues: 32)
            if types == [85] { return try ConsoleLivePhoto.request(livePhoto).body }
            var nested = try ProtoMessage.integer(field: 40, value: format)
            if let raw { nested += try ProtoMessage.integer(field: 25, value: raw) }
            let reportedTypes = ProtoMessage.varint(25) + ProtoMessage.varint(40)
            return try ProtoMessage.blob(field: 1, value: reportedTypes)
                + ProtoMessage.blob(field: 2, value: nested)
                + ProtoMessage.integer(field: 3, value: 6)
        case .setPhotographyOptions:
            let body = try ProtoMessage(request.body)
            let ids = try body.repeatedUnsigned(1, maximumValues: 16)
            writes.append(ids)
            let options = try ProtoMessage(try XCTUnwrap(body.optionalBytes(2)))
            for id in ids {
                switch id {
                case 40: format = try options.unsigned(40)
                case 25:
                    if options.fields.contains(where: { $0.number == 25 }) { raw = try options.unsigned(25) }
                    else { raw = nil }
                case 85:
                    let state = try ProtoMessage(try XCTUnwrap(options.optionalBytes(85)))
                    livePhoto = try state.unsigned(2) == 2
                case 63, 30: break
                default: XCTFail("Unexpected setting field \(id)")
                }
            }
            return Data()
        default:
            XCTFail("Unexpected command during photo preset restore")
            throw LunaProtocolError.cameraRejectedRequest
        }
    }
}

/// 没有连续拍摄字段的旧存档，用来确认解码仍能读出预设。
private struct LegacyConsoleMemory: Encodable {
    var presets: [ConsoleMemory.Preset]
}
