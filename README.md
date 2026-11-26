# LunaScope

LunaScope 适配 Insta360 Luna 系列相机，提供 iPhone 和 iPad 相机控制台。连接相机后可查看实时画面、调整 ISO 和快门、切换拍摄规格、拍照、录制并手动控制云台。控制台支持多组参数预设，以及最近一个云台位置的保存和恢复。

首次打开进入「相机连接」，连接成功后自动进入「拍摄」。底部依次是「相机连接」「拍摄」「相册」「设置」。锁屏和支持的 iPhone 灵动岛会显示连接、录像与连拍状态的实时活动，点按返回 App。

点按底部相机图标直接进入「拍摄」，支持横屏、竖屏及全屏预览。横屏左侧固定取景，右侧可滚动，上方放拍摄与云台控制，下方放变焦和拍摄设置。竖屏的拍摄设置位于取景区上方。照片尺寸菜单按比例列出标准与超清规格。标准照片模式可在取景画面左侧打开实况照片。

用 Xcode 27.1 或更新版本打开 [LunaScope.xcodeproj](LunaScope.xcodeproj)，运行 LunaScope scheme。连接和拍摄需要 Insta360 Luna 系列相机，以及 iPhone 或 iPad。

机型参数保存在 [CameraProfiles](LunaScope/Resources/CameraProfiles)。开发说明包含 [新增机型的配置方法](docs/development.md#新增-luna-机型)。
