# LunaScope App Store 素材

- [简体中文上架文案](app-store-zh-Hans.md)
- [英文上架文案](app-store-en.md)
- [中英文截图预览](previews/iphone-6.9-contact-sheet.jpg)（上排中文，下排英文）

| App Store Connect 槽位 | 竖屏尺寸 | 上传图 |
| --- | --- | --- |
| 带灵动岛的 iPhone（中等显示屏） | 1206 × 2622 | [简体中文](screenshots/iphone-6.3/zh-Hans) · [英文](screenshots/iphone-6.3/en) |
| 带灵动岛的 iPhone（大显示屏） | 1320 × 2868 | [简体中文](screenshots/iphone-6.9/zh-Hans) · [英文](screenshots/iphone-6.9/en) |

每个尺寸按云台位置、间隔连拍、参数记忆、实时活动排序。两种语言共用同一组中文 UI 截图，标题和说明按语言分别生成。上传图均为 RGB PNG。[Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

LunaScope 也支持 iPad，提交时需提供 13 英寸 iPad 槽位截图。本次四张原图来自 iPhone，iPad 槽位待补充实际运行画面。

营销、支持和隐私页面位于 `apps-page/luna-scope/`。App Store 链接和 App 内「关于」的版本入口均使用 <https://apps.apple.com/app/id6839451668>。

## 重新生成

脚本从 `source-screenshots/` 读取四张原图，为两个 iPhone 尺寸各生成八张上传图，并生成一张预览拼图。需要 Pillow 及 macOS 自带的 SF Pro、Hiragino Sans GB 字体。

```sh
python3 AppStoreMarketing/generate_app_store_assets.py
```
