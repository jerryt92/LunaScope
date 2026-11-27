import SwiftUI

/// 每次打开 App 都进入连接页；连接成功后自动进入拍摄。
struct RootView: View {
    private enum RootTab: String, Hashable { case connection, shooting, album, settings }

    let camera: CameraController
    @State private var tab: RootTab = .connection
    @State private var isShowingAnnouncement = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                CameraConnectionView(camera: camera)
            }
            .environment(\.horizontalSizeClass, sizeClass)
            .tabItem { Label("tab.connection", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(RootTab.connection)

            NavigationStack {
                ConsoleView(camera: camera, openConnection: { tab = .connection })
            }
            .environment(\.horizontalSizeClass, sizeClass)
            .tabItem { Label("feature.console.title", systemImage: "camera.fill") }
            .tag(RootTab.shooting)

            NavigationStack {
                CameraAlbumView(camera: camera, isActive: tab == .album, openConnection: { tab = .connection })
                .navigationTitle("album.title")
                .navigationBarTitleDisplayMode(.inline)
            }
            .environment(\.horizontalSizeClass, sizeClass)
            .tabItem { Label("tab.album", systemImage: "photo.on.rectangle") }
            .tag(RootTab.album)

            SettingsView { isShowingAnnouncement = true }
                .environment(\.horizontalSizeClass, sizeClass)
                .tabItem { Label("tab.settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .tabViewStyle(.tabBarOnly)
        // iPad 也使用底部页签，每页仍按窗口的实际宽度布局。
        .environment(\.horizontalSizeClass, .compact)
        .sheet(isPresented: $isShowingAnnouncement) {
            AppAnnouncementView()
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled()
        }
        .onChange(of: scenePhase, initial: true) { previous, phase in
            if previous == .active && phase != .active { camera.releaseGimbal() }
            if phase == .active { showAnnouncementIfNeeded() }
        }
        .onChange(of: camera.connected) { _, connected in
            // 仅在连接页等待时跳转，避免相册/设置页被重连打断。
            if connected, tab == .connection { tab = .shooting }
        }
        .onChange(of: camera.previewRestoreRequest) { _, request in
            if request != nil { tab = .shooting }
        }
    }

    /// 标识与上次展示的不同时自动弹出，并记下本次标识。
    private func showAnnouncementIfNeeded() {
        let defaults = UserDefaults.standard
        let announcementID = AppAnnouncementView.announcementID
        guard defaults.string(forKey: AppAnnouncementView.lastShownDefaultsKey) != announcementID else { return }
        defaults.set(announcementID, forKey: AppAnnouncementView.lastShownDefaultsKey)
        isShowingAnnouncement = true
    }
}

#Preview { RootView(camera: CameraController()) }
