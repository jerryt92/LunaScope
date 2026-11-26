# 开发与验证

## 环境与命令

Xcode 27.1、Swift 6 工具链以及 iOS 27 模拟器。App 使用 Swift 5 语言模式。实机调试需 Xcode 自动签名与影石360 Luna 系列相机。

```sh
xcodebuild -project LunaScope.xcodeproj -scheme LunaScope \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project LunaScope.xcodeproj -scheme LunaScope \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=27.0' \
  -derivedDataPath build/DerivedData -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

可将测试目的地换为 `iPad Pro 11-inch (M5)`。Scheme 包含 App 替身测试和 UI 冒烟测试。UI 验证英语、简体中文、页面导航、相机连接入口、拍摄页旋转与全屏。

## 实现

- App 持有共享相机控制器，各窗口独立恢复当前页签。首次打开进入相机连接；连接成功后自动进入拍摄页，底部页签仍可手动切换。
- 设置页可生成诊断归档。最近 7 个自然日的日志记录事件类型和运行标识，归档由用户从系统分享面板选择目的地。

## 连接与实时活动

- 选择相机后，ActivityKit 在锁屏和支持的灵动岛上展示连接进度；录像与连续拍摄也会反映在同一实时活动上，并以主题色与 App logo 展示。主动断开结束活动，点按活动由系统激活 App，保留当前窗口的页签。
- 实时活动只负责锁屏 / 灵动岛展示，**不能**阻止进程被挂起。录像与连续拍摄进行中会激活已声明的 `audio` 后台模式（极低音量循环）并续约 `UIBackgroundTask`，让控制链路继续跑；画中画释放音频会话时会立刻按拍摄态抢回。空闲后台时实时活动约 30 秒后标为需打开 App 核实。系统仍可能在极端省电策略下中断 Wi-Fi。空闲时回前台先查询拍摄状态；连续查询失败且期间没有实况或拍摄状态回报，才沿已选相机的路由重连。 [Apple 后台执行时间](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)

## 拍摄布局与设置

- 页面分别维护用户设置和相机读数。拍摄模式、组合规格、ISO、快门、白平衡、对焦、色彩、实况、RAW、变焦和云台模式都先更新界面，再由相机会话串行写入。收到旧读数时保留用户选择。连接和拍摄状态仍来自设备。
- 拍照、写卡和全景合成期间保留上一帧并显示处理中。操作结束后给预览留出恢复时间，底层检测到连接断开时按原流程重连。
- 快捷参数包括拍摄模式、规格、A／M 参数面板和色彩；变焦刻度放在取景画面正下方。照片模式另提供 App 侧「连续拍摄」：底层仍写单张照片，参数菜单下方出现「拍摄间隔」（预设秒数与自定义秒/分钟）。连续拍摄时下一张必须等上一张完成反馈后才触发；间隔从开拍时刻起算，长曝光超过间隔则完成后立即拍下一张。主控制面板提供拍照、录像、云台操作及休眠唤醒。竖屏将参数菜单放在取景上方、主控制面板放在取景与变焦下方；参数记忆作为顶部配置栏中的一项。配置栏横竖屏都最多两行，同行等宽；槽位过多时加宽每行列数，保证全部可见。连续拍摄间隔紧跟拍摄模式。横屏左侧为取景加变焦，右侧是唯一的滚动区，主控制面板排在最上方，参数设置排在下面。拍摄页隐藏导航栏，避免顶部空白。取景区右上角切换全屏，全屏保留原视频比例，只在画幅外放置退出和画中画按钮。点按画面可隐藏或恢复这些按钮，隐藏时让画面使用全部可用空间。
- 拍摄面板使用一个快门。照片和全景模式拍照，录像模式开始或停止录制。预览坐标按实际收到的 HEVC 画幅计算。点按执行对焦，双击或拖出矩形启动机身追踪，追踪框使用机身回报。点测光的坐标协议尚未确认。 [影石追踪指南](https://onlinemanual.insta360.com/lunaultra/zh-cn/operation-tutorials/shooting-preview/shooting-function/smart-tracking)
- 全屏画幅外可以开启 iOS 画中画，画中画与内嵌取景共用同一个视频层。画中画开启时，App 内取景显示黑底和画中画图标。系统的恢复按钮回到拍摄页。 [Apple AVKit 画中画](https://developer.apple.com/videos/play/wwdc2021/10290/)
- 预览使用相机实际发送的分辨率和帧率。持续卡顿时，先请求关键帧，空闲时才尝试同画幅的低分辨率档。低档无画面时回退默认档，链路恢复稳定后重新尝试默认档。低档是否接受取决于机型和固件。
- A／M 面板按机身回读切换普通与专业模式。普通模式显示 A，在面板内调 EV。专业模式显示 M，横向切换快门、ISO、EV、白平衡、测光和对焦。数值用横向刻度调节。ISO 上限档写入 photography option 24，与固定感光度互斥。对焦可选连续或单次，全景模式通过配置栏的单独入口调整。模式字段与配置档位见[相机型号配置说明](camera-profile.md)。
- 取景区分别显示机身和可拆卸屏幕的电量。机身使用现有电源读数，屏幕使用独立的电量回读和通知。缺少读数时显示「—」。 [电量协议记录](https://opencapture.org/openinstacine/docs/devices/luna-ultra/media/#battery-storage-and-remaining-time)
- 变焦档位和限制来自机型配置。Ultra 的快捷档位为 1×、2×、3×、6×、12×、15×，Pro 为 1×、2×、4×。8K 和竖屏 4K 的上限分别为 6× 和 3×，Ultra 录制时还限制在当前镜头范围内。慢动作、定点延时、移动延时及高帧率录像中，Ultra 只提供 1× 和 3×，Pro 隐藏变焦。常用倍率与细调共用一条刻度尺。点按切换焦段，横向拖动以 0.025× 细调。按住期间保留界面选定的刻度，后台合并待发送的变焦指令，松手后确认最终倍率。 [官方变焦功能](https://onlinemanual.insta360.com/lunaultra/zh-cn/operation-tutorials/shooting-preview/shooting-function/zoom) [官方拍摄规格](https://onlinemanual.insta360.com/lunaultra/zh-cn/specs/shooting)
- 单张照片模式将实况照片图标开关放在取景画面左侧居中，不可用时隐藏。标准照片发送照片库 cmd 9、type 85，字段 2 为 1（关）或 2（开）。以独立 GET 或成功的 8298 通知确认状态。切换中的值 3 不作确认。实况与超清互斥时自动切到标准规格或关掉实况，并以控制区轻提示告知，无需点确认。预设保存当前界面选择。 [官方实况照片指南](https://onlinemanual.insta360.com/lunaultra/zh-cn/operation-tutorials/shooting-preview/shooting-function/live-photo)

- 激活的拍摄模式决定可用的比例、分辨率和帧率。视频三项对应同一相机格式枚举。「照片尺寸」将照片比例、标准或超清画质和对应分辨率集中到同一个菜单，每个选项一次写入比例和规格。照片格式 JPG 与 JPG+RAW 以 type 25 写入（开启 1，关闭按官方做法省略字段），随预设保存并按回读确认；RAW 以 DNG 保存。后端设置刷新不含 type 25，进入或切换照片模式后由控制台补一次完整回读，保证照片格式菜单首次进入即有读数。录像、自动、手动、优先曝光和全景快门沿用 OpenCine 的协议读写。规格列表依据 [OpenInstaCine 探测结果](https://opencapture.org/openinstacine/docs/devices/luna-ultra/modes/) 和 [影石规格](https://www.insta360.com/specs/luna-ultra)。
- 首次连接、重连或进入单张照片模式后，单独读取照片尺寸与 JPG / RAW。首个回复缺失时短暂重试，连接期间无需等待拍摄状态先到达。
- 参数预设统一保存 M 档参数。在 A 档保存时优先使用当前拍摄模式上次的 M 档参数。尚无读数时，相机会短暂切到 M 档读取，再恢复 A 档。只有保存为 M 档的预设可以应用。应用时先确认机身已切到 M 档，再写入曝光参数。全景模式在控制台没有 A／M 入口，因此不参与此流程。
- 云台记忆绑定保存时的相机，保存机柄坐标和相机回报的翻转状态。恢复时先比较翻转状态，必要时执行翻转，再调整角度，并分别回读确认。旧记录和未回报翻转状态时保存的记录仅恢复角度，页面会提示。 [云台角度协议](https://opencapture.org/openinstacine/docs/devices/luna-ultra/controls/#absolute-angle) [设备选项协议定义](https://github.com/iliakonnov/insta360-nas/blob/b78dddb9cd9bc2cf632871646c6f5af238e582d4/insta360-server/insta360_messages.proto#L6259)
- 底部「相册」页签的照片墙交互参考 PhotoAssistant。照片按拍摄日期分组，新日期在前，支持勾选、整组全选与全选/取消全选，以及预览与从相机删除（不写入手机相册）。内置与 SD 卡分段切换，SD 可用性按相机回读。列表用 cmd 13 分页和 cmd 38 元数据，缩略图用 cmd 11 NV12 经 OpenCine 公共编码器转 JPEG，按 URI 合并请求并缓存。预览时流式下载 JPG/DNG/MP4 并校验魔数；`LIV_` 实况照片解析尾部嵌入的运动视频并支持播放。标准画质照片显示「弱」角标，RAW 与实况另有角标。删除走 cmd 12。浏览期间持有控制独占锁，保持实况和拍摄状态。官方 App 切入相册时发送 cmd 118 {1:1}，相机会收起云台。LunaScope 在原连接上读取列表、缩略图和原片，关闭时释放锁。不同固件对拍摄状态下 HTTP 原片的访问仍需真机验证。 [媒体协议实测](https://opencapture.org/openinstacine/docs/devices/luna-ultra/media/)
- 连接健壮性沿用 OpenCine 后端：BLE 引导唤醒相机 Wi-Fi、2 秒心跳、热点加入重试与串口校验。意外断线后 App 在约 45 秒预算内沿上次路由自动重连，保留已选相机与记忆；超预算显示"重试连接"，回到前台自动再试；用户主动断开不重连。云台休眠按官方做法发 cmd 118 {1:5} 唤醒并回读确认：拍摄视图内自动唤醒，相册独占期间不打断，控制台另有手动唤醒按钮。参见 [连接与重连](https://opencapture.org/openinstacine/docs/devices/luna-ultra/connection/) 和 [云台唤醒](https://opencapture.org/openinstacine/docs/devices/luna-ultra/controls/#gimbal-wake)。
- 真机回归需核对普通视频与各种照片组合的回读，确认模式切换和拍照结果。JPG+RAW 拍照应同时得到 DNG 与 JPEG，切回 JPG 后回读省略 type 25。保存两组不同参数并分别套用，验证左滑只删除选中预设。保存两次云台位置，确认恢复使用后一次位置。核对断线、写卡和相机更换时的状态。打开相机相册核对内置/SD 列表与缩略图、日期分组、RAW 角标与 `LIV_` 实况预览，勾选后删除 JPG、RAW、实况与视频并确认机内文件消失；打开和关闭相册前确认云台偏离中心，期间姿态应保持，返回后实况可继续使用。验证浏览中断线后恢复实况。关闭相机 Wi-Fi 或走远触发断线，确认自动重连恢复实况、重试入口可用、主动断开不重连；云台休眠后确认自动或手动唤醒成功且摇杆恢复可用。

## 新增 Luna 机型

在 [CameraProfiles](../LunaScope/Resources/CameraProfiles) 复制一份 `CameraProfile-*.json` 并替换机型数据。App 会发现所有同前缀的内置 JSON。沿用现有 Luna 握手、命令和拍摄模式的机型只需新增配置文件。

| 字段 | 用途 |
| --- | --- |
| `schemaVersion`、`id`、`displayName` | 当前版本为 `1`。使用唯一且稳定的机型 ID。 |
| `deviceModels`、`bluetoothPrefixes` | 填入设备信息中的完整型号及蓝牙广播名称前缀。连接以相机实际回报的型号为准。 |
| `modes`、`videoDefinitions` | 每个启用的模式列出可写入的 `videoFormats` 协议编号。`tracking` 控制该模式下的画面追踪手势。共享表没有的编号可用可选的 `videoDefinitions` 补充 `width`、`height` 和 `framesPerSecond`。 |
| `photoFormats`、`rawPhoto`、`livePhotoFormatIDs` | 定义照片的编号、比例和比例码、画质、宽高，以及 RAW 和允许开启实况照片的规格。 |
| `exposure`、`whiteBalance`、`focusModes`、`colors`、`colorOverrides` | 定义 ISO、可选的 `isoMax` 上限档、快门倒数与照片长曝光秒数、色温范围和步长，以及对焦和色彩选项。某规格只允许一种色彩时，切换规格的命令会同时写入该色彩。 |
| `zoomStops`、`modes.*.zoom`、`modes.*.zoomOverrides` | 定义快捷档位、模式范围和视频规格例外。用 `maximum` 表示连续变焦，`fixedStops` 表示仅可选固定档位，`null` 表示关闭。多镜头连续变焦可用按升序排列的 `recordingLensStarts` 限制录制中的镜头切换。 |
| `gimbalModes`、`detachableScreen` | 定义可用的云台模式与独立屏幕电量显示。空云台列表会隐藏云台控制。 |

蓝牙广播名用于发现阶段显示。蓝牙授权和 Wi-Fi 握手从同一组 JSON 取得支持名单，配对时仍校验加密身份和 Wi-Fi 接力的机身序列号。预设记录来源机型，应用前按当前机型限制筛选可写入的设置。

影石360 Luna 系列相机的公开能力以官方规格为依据。Pro 的固件型号字符串和控制编号沿用现有 Luna 协议适配假设，待真机确认。Pro 超清竖幅照片的协议编号尚未取得，配置先列出有协议编号依据的规格。 [官方拍摄规格](https://onlinemanual.insta360.com/lunaultra/zh-cn/specs/shooting) [OpenInstaCine 规格记录](https://opencapture.org/openinstacine/docs/devices/luna-ultra/modes/)

## 真机回归

1. 逐台连接影石360 Luna 系列相机，确认界面显示正确机型，并核对内置存储与插卡状态分别可读取。
2. 在慢门拍照、全景合成和停止录像写卡时观察预览，确认忙碌提示以及相机空闲后的画面恢复。分别在拍摄中和空闲时切到后台再返回。
3. 锁屏核对实时活动，点按回到 App 后保留原页签。主动断开后确认实时活动结束。
4. 拍摄页旋转至横屏与竖屏，在预览和全屏间来回切换，确认画面与变焦、云台和快门操作恢复正常。选择标准照片后开关实况照片，核对机身状态、`LIV_` 原片和预设恢复，再验证关闭后可以设置超清照片。
5. 用机身翻转到自拍朝向，用摇杆偏离回中位置后记忆云台。翻回另一侧后恢复，确认预览朝向和构图都一致。再交换两侧重复，确认连续恢复同一记录只在需要时翻转。
