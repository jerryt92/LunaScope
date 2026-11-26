import XCTest

final class ConsoleNavigationTests: XCTestCase {
    @MainActor
    func testCameraDiscoveryHasItsOwnMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let connection = app.tabBars.buttons["连接"]
        XCTAssertTrue(connection.waitForExistence(timeout: 8))
        let shooting = app.tabBars.buttons["拍摄"]
        let album = app.tabBars.buttons["相册"]
        let settings = app.tabBars.buttons["设置"]
        XCTAssertLessThan(connection.frame.midX, shooting.frame.midX)
        XCTAssertLessThan(shooting.frame.midX, album.frame.midX)
        XCTAssertLessThan(album.frame.midX, settings.frame.midX)
        XCTAssertGreaterThan(connection.frame.midY, app.frame.midY)
        connection.tap()
        XCTAssertTrue(app.navigationBars["相机连接"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未连接"].exists)

        app.buttons["connection.scan"].tap()
        XCTAssertTrue(app.staticTexts["请在 iPhone 或 iPad 真机上搜索并配对 Luna 相机。"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAlbumTabRemainsAccessibleFromShooting() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let album = app.tabBars.buttons["相册"]
        XCTAssertTrue(album.waitForExistence(timeout: 8))
        album.tap()
        XCTAssertTrue(app.navigationBars["相机相册"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["album.connection.open"].exists)

        app.tabBars.buttons["拍摄"].tap()
        XCTAssertTrue(app.buttons["console.preview.fullscreen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["console.album.open"].exists)
        XCTAssertFalse(app.navigationBars["拍摄"].exists)
        album.tap()
        XCTAssertTrue(app.navigationBars["相机相册"].waitForExistence(timeout: 5))
        XCTAssertTrue(album.isSelected)
        app.buttons["album.connection.open"].tap()
        XCTAssertTrue(app.navigationBars["相机连接"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLegacyCameraActivityLinkKeepsSelectedTab() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "lunascope://camera-connection")))

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isSelected)
    }

    @MainActor
    func testSettingsSubpagesShowDiagnosticsAndBundledLicenses() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()

        app.buttons["settings.advanced"].tap()
        XCTAssertTrue(app.navigationBars["高级设置"].waitForExistence(timeout: 5))
        app.buttons["生成诊断归档"].tap()
        XCTAssertTrue(app.buttons["分享归档"].waitForExistence(timeout: 5))
        app.navigationBars["高级设置"].buttons.firstMatch.tap()

        app.buttons["settings.about"].tap()
        XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["LunaScope"].exists)
        XCTAssertTrue(app.staticTexts["© 2026 jerryt92."].exists)
        let version = app.descendants(matching: .any)["settings.about.version"].firstMatch
        XCTAssertTrue(version.exists)
        XCTAssertEqual(version.label, "版本")
        XCTAssertFalse((version.value as? String ?? "").isEmpty)
        app.buttons["settings.about.licenses"].tap()
        XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings.licenses.source.openCine"].firstMatch.exists)
        let openCineUsage = NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            "实时取景和相册缩略图处理", "接入影石360 Luna 系列相机"
        )
        XCTAssertTrue(app.staticTexts.containing(openCineUsage).firstMatch.exists)

        for (resource, excerpt) in [
            ("OpenCine-License", "Version 2.0, January 2004"),
            ("OpenCine-Notice", "Copyright 2026 Erik Sutton and OpenCine contributors"),
            ("OpenCine-Third-Party-Notices", "# Third-party notices"),
            ("KCP-License", "Copyright (c) 2017 Lin Wei")
        ] {
            let license = app.buttons["settings.license.\(resource)"]
            if !license.isHittable { app.swipeUp() }
            if resource == "KCP-License" {
                XCTAssertTrue(app.descendants(matching: .any)["settings.licenses.source.kcp"].firstMatch.exists)
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "UDP 可靠传输")).firstMatch.exists)
            }
            license.tap()
            let contents = app.staticTexts["settings.license.contents"]
            XCTAssertTrue(contents.waitForExistence(timeout: 5), resource)
            XCTAssertTrue(contents.label.contains(excerpt), resource)
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
        }
    }

    @MainActor
    func testOfflineConsoleExposesModesAndMemoryWithoutSendingCommands() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let entry = app.tabBars.buttons["拍摄"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()

        let modes = app.buttons["console.mode.menu"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertFalse(modes.isEnabled)
        let preview = app.buttons["console.preview.fullscreen"]
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(app.buttons["console.exposure.program"].exists)
        let exposure = app.buttons["console.exposure.controls"]
        XCTAssertTrue(exposure.exists)
        XCTAssertFalse(exposure.isEnabled)
        XCTAssertLessThan(exposure.frame.midY, preview.frame.midY)
        XCTAssertFalse(app.buttons["console.settings.focus"].exists)
        for identifier in ["console.gimbal.center", "console.gimbal.flip", "console.gimbal.savePosition",
                           "console.gimbal.restorePosition", "console.gimbal.mode.menu"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.exists, identifier)
            XCTAssertFalse(control.isEnabled, identifier)
            XCTAssertGreaterThan(control.frame.midY, preview.frame.midY, identifier)
        }
        let presets = app.buttons["console.presets.open"]
        XCTAssertTrue(presets.isHittable)
        presets.tap()
        XCTAssertTrue(app.staticTexts["暂无参数预设"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["console.presets.save"].isEnabled)
        app.buttons["drawer.close"].tap()
        XCTAssertTrue(presets.waitForExistence(timeout: 5))
    }

    @MainActor
    func testShootingRotatesAndExpandsTheViewfinder() {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let entry = app.tabBars.buttons["拍摄"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        let expand = app.buttons["console.preview.fullscreen"]
        let mode = app.buttons["console.mode.menu"]
        let shutter = app.buttons["console.capture.shutter"]
        let sidebar = app.scrollViews["console.landscape.controls"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let pip = app.buttons["console.preview.pip"]
        XCTAssertTrue(pip.exists)
        XCTAssertLessThan(pip.frame.maxX, expand.frame.minX + 1)
        XCTAssertEqual(pip.frame.midY, expand.frame.midY, accuracy: 2)
        XCTAssertLessThan(mode.frame.midY, expand.frame.midY)

        device.orientation = .landscapeLeft
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        let previewButtonFrame = expand.frame
        XCTAssertGreaterThan(sidebar.frame.minX, previewButtonFrame.maxX)
        XCTAssertTrue(sidebar.buttons["console.capture.shutter"].exists)
        for _ in 0..<3 where !mode.isHittable { sidebar.swipeUp() }
        XCTAssertTrue(sidebar.buttons["console.mode.menu"].exists)
        XCTAssertGreaterThan(mode.frame.midY, shutter.frame.midY)
        sidebar.swipeUp()
        XCTAssertEqual(expand.frame, previewButtonFrame)
        expand.tap()
        let close = app.buttons["console.preview.exitFullscreen"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["拍摄"].isHittable)
        XCTAssertFalse(mode.exists)
        XCTAssertFalse(sidebar.exists)
        let picture = app.buttons["console.preview.toggleFullscreenControls"]
        XCTAssertTrue(picture.exists)
        XCTAssertFalse(picture.frame.intersects(close.frame))
        picture.tap()
        XCTAssertFalse(close.exists)
        picture.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    }
}
