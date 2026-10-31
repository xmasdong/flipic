# PixDeck

Mac 上的看图工具，只管看图这一件事。双击任意一张图，就能用左右键把同一个文件夹里的图片翻一遍。

![PixDeck 浏览照片](docs/screenshot-browse.jpg)

## 下载

**[下载 PixDeck.dmg](https://github.com/xmasdong/macphoto/releases/latest/download/PixDeck.dmg)**（1.2 MB）

- 系统要求：macOS 13 或更新版本，Apple 芯片和 Intel 芯片的 Mac 都能用
- 已通过 Apple 公证，使用 Developer ID 签名
- 官网：[xmasdong.github.io/macphoto](https://xmasdong.github.io/macphoto/)，国内下载慢可以从官网下
- 历史版本见 [Releases](https://github.com/xmasdong/macphoto/releases)

## 安装

1. 打开下载好的 `PixDeck.dmg`
2. 把 PixDeck 拖进「应用程序」文件夹
3. 第一次打开时，系统会提示这是从互联网下载的 App，点「打开」即可

想把它设成默认看图软件：在 Finder 里右键一张图，选「显示简介」，在「打开方式」里选 PixDeck，再点「全部更改」。jpg、png、heic 等格式各需要设置一次。

## 能做什么

- **连续翻页**：双击一张图，同文件夹的图片按左右键往下翻，可以按文件名、拍摄时间、修改时间、创建时间或文件大小排序
- **空格预览**：按空格，窗口贴合照片比例，整张图铺满窗口，跟访达的空格预览一样；再按一次回到原来的窗口
- **缩放**：触控板双指捏合跟着手指缩放，滚轮也可以；双击在适应窗口和 100% 之间切换，放大后自动换成原图
- **滚轮翻页**：在「显示 › 鼠标滚轮」里改成「切换上一张 / 下一张」，滚一格翻一张，⌘+滚轮缩放
- **清理模式（Beta）**：⌘⇧K 扫描当前文件夹，找出相似连拍、内容完全相同的文件、闭眼和模糊的照片。连拍组里推荐保留最好的一张，其余默认勾选；只有你按下按钮才会移到废纸篓，⌘Z 可撤销。RAW 和同名 JPG 一起处理，全部在本机完成
- **拍摄参数**：左上角显示尺寸、大小、相机、镜头、快门、光圈、ISO 和拍摄时间，按 I 打开完整的照片信息
- **批量处理**：整个文件夹批量转换格式（JPEG / PNG / HEIC），转好的放进子文件夹，原图不动；也支持批量重命名
- **其他**：旋转后写回文件（JPEG、HEIC 只改方向标记，画质无损）、导出压缩副本、幻灯片放映、设为桌面壁纸、移到废纸篓
- 支持 JPEG、PNG、HEIC、WebP、GIF（动图）、TIFF、AVIF、JPEG XL（需 macOS 14 或更新）以及常见相机 RAW 格式
- 界面支持 14 种语言，跟随系统设置

![照片信息面板](docs/screenshot-exif.jpg)

## 常用快捷键

| 按键 | 作用 |
|---|---|
| ← → | 上一张 / 下一张 |
| ↑ ↓ 或滚轮 | 放大 / 缩小（滚轮可改成翻页） |
| 空格 | 窗口贴合图片比例预览（再按一次退出） |
| 双击 | 适应窗口和 100% 来回切 |
| I | 照片信息 |
| T | 缩略图栏 |
| R / L | 向右 / 向左旋转 |
| S | 幻灯片放映 |
| 回车 | 重命名 |
| ⌘S | 导出压缩副本 |
| ⌘⌫ | 移到废纸篓 |
| ⌘⇧K | 清理模式 Beta |

## 隐私

PixDeck 不联网，没有账号，不收集任何数据。只读取你打开的图片，所有处理都在本机完成。

## 反馈

用着有不顺手的地方，欢迎在 [Issues](https://github.com/xmasdong/macphoto/issues) 里告诉我。

## 从源码构建

PixDeck 用 Swift 和 AppKit 写成，没有第三方依赖。需要 macOS 13 或更新版本和 Xcode 15 或更新版本（或 Swift 5.9 命令行工具）。

```bash
git clone https://github.com/xmasdong/macphoto.git
cd macphoto
./build.sh                       # 产出 build/PixDeck.app（本机临时签名）
open build/PixDeck.app
```

想用 Xcode 打开：装好 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后运行 `xcodegen generate`，生成 `PixDeck.xcodeproj`。

带 Developer ID 签名和公证的发布包用 `scripts/build_devid.sh` 构建，签名凭据按 `scripts/devid.env.example` 填在 `scripts/devid.env` 里（不进版本库）。

目录说明：`Sources/Photoview` 是全部源码，`Resources` 是 Info.plist、图标和 14 种语言的文案，`docs` 是官网。

## 开源协议

[GPL-3.0](LICENSE)。可以自由使用、修改和再发布；发布修改后的版本时，也需要以 GPL-3.0 开源。

---

## English

PixDeck is a lightweight image viewer for macOS. Double-click any image and browse the whole folder with the arrow keys: pinch-to-zoom that follows your fingers, 100% view with full-resolution decoding, EXIF details, batch format conversion, a Cleanup Mode (Beta) that finds similar bursts, exact duplicates, closed eyes and blurry shots, and 14 interface languages. No network access, no account, no data collection.

Open source under [GPL-3.0](LICENSE). Build from source with `./build.sh` (macOS 13+, Swift 5.9+, no third-party dependencies).

**[Download PixDeck.dmg](https://github.com/xmasdong/macphoto/releases/latest/download/PixDeck.dmg)** — macOS 13 or later, Apple silicon and Intel, notarized by Apple.

---

截图中的风景照来自 Wikimedia Commons：喀纳斯湖 Muye Ma、那拉提草原 Yoshi Canopus、沙漠星空 thomas shellberg（CC0）；天山天池 David Stanley、库尔德宁 George Lu、博斯腾湖 liuxingy2015（CC BY 2.0）；果子沟大桥 Timothytyy、将军山 Pazakui（CC BY 4.0）。
