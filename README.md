<p align="center">
  <img src="docs/icon-256.png" width="128" height="128" alt="Flipic 图标">
</p>

<h1 align="center">Flipic</h1>

<p align="center"><b>简体中文</b> · <a href="README.en.md">English</a></p>

<p align="center">
  Mac 上的轻量看图工具。双击一张图，用左右键把整个文件夹翻一遍。<br>原名 PixDeck，0.5.0 起改名 Flipic。
</p>

<p align="center">
  <a href="https://github.com/xmasdong/flipic/releases/latest/download/Flipic.dmg"><b>下载 Flipic.dmg</b></a>
  ·
  <a href="https://flipic.app/">官网</a>
  ·
  <a href="https://github.com/xmasdong/flipic/releases">历史版本</a>
</p>

<p align="center">
  <a href="https://github.com/xmasdong/flipic/releases/latest"><img src="https://img.shields.io/github/v/release/xmasdong/flipic?label=%E7%89%88%E6%9C%AC&color=444" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-444" alt="macOS 13 或更新">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-444" alt="MIT"></a>
</p>

![Flipic 浏览照片](docs/screenshot-browse.jpg)

用系统自带的「预览」打开一张图，它就只显示这一张，想看下一张得回访达全选再打开。Flipic 就是为这件事做的：双击任意一张，按 → 就是下一张，同一个文件夹的图片都能翻到。安装包 1.8 MB，默认不联网，不要账号。

## 下载安装

1. 下载 [Flipic.dmg](https://github.com/xmasdong/flipic/releases/latest/download/Flipic.dmg)，国内下载慢可以从[官网](https://flipic.app/)下
2. 打开 dmg，把 Flipic 拖进「应用程序」
3. 第一次打开时系统会提示这是从互联网下载的 App，点「打开」

需要 macOS 13 或更新版本，Apple 芯片和 Intel 芯片都能用。安装包用 Developer ID 签名并通过了 Apple 公证。历史版本在 [Releases](https://github.com/xmasdong/flipic/releases)。

想设成默认看图软件：打开设置（⌘,），在「通用」里点「设为默认看图软件」，常见图片格式和相机 RAW 会一次设好。也可以在访达里右键一张图，按住 ⌥ 键，选「始终以此方式打开」› Flipic。

设好之后可以当「快速查看」用：在访达里选中照片按 ⌘↓ 打开，左右翻看，按 Esc 关闭（先在设置里打开「按 Esc 关闭窗口」）。访达里的空格键是系统的快速查看，第三方 app 接管不了。

## 功能

**看图**

- 同一个文件夹里左右翻页，可以按文件名、拍摄时间、修改时间、创建时间或文件大小排序，会记住上次的选择
- 按空格，窗口贴合照片比例预览，跟访达的空格预览一样，再按一次回到原窗口
- 触控板双指捏合缩放；鼠标停在想看的地方按 0，就在那里放大到 100%，再按一次恢复；双击也能在适应窗口和 100% 之间切换，放大到需要时才解码原图
- 翻页默认直接切换，没有渐变；喜欢淡入淡出可以在设置里打开「翻页渐变」
- 鼠标滚轮默认缩放，也可以在设置里改成翻页，翻页方向也能反过来（像刷手机一样往下滑回到上一张）；用 Mos 之类的工具改过滚轮方向的，可以把缩放方向反过来
- 放大后拖到照片边缘就停，不会拖出黑边；底部缩略图有小、中、大、特大四档
- HDR 照片（iPhone 拍的 HEIC、带增益图的 JPEG 等）可以按 HDR 显示，亮部比普通白更亮，和系统「预览」一样；在设置里打开，默认关，需要 macOS 14 和支持 HDR 的屏幕
- 界面默认只有照片，不显示任何信息；按 I 在右上角看相机、镜头、快门、光圈、ISO、拍摄时间和尺寸，按 Esc 关掉

**打星**

按 1 到 5 给照片打 1 到 5 星，右键菜单「评分」里可以改成「未评分」。评过分的照片在底部正中常驻显示星级。评分按 XMP 标准写入：JPEG、HEIC、TIFF 写进文件本身，只改元数据不重新压缩；索尼、佳能、尼康等专有 RAW 写在同名 .xmp 文件里，原始文件不动。Lightroom、Bridge、Capture One 都能读到。同名的 RAW 和 JPG 一起打分。

**挑片（清理模式，Beta）**

活动、会议一拍几百张时，按 ⇧⌘K 进入清理模式。Flipic 在本机检查整个文件夹，分成相似连拍、内容完全相同的文件、闭眼、模糊或虚焦四类。连拍组里推荐保留最清楚、没人闭眼的那张，其余默认勾上，闭眼的照片会框出是哪张脸。

删除只在你按下「移到废纸篓」时发生，⌘Z 可以撤销。RAW 和同名 JPG 算一张，一起处理。检测会有误判，删之前过一眼。

![清理模式](docs/shots/cleanup.webp)

**批量处理和其他**

- 整个文件夹批量转换格式（JPEG、PNG、HEIC），输出到子文件夹，原图不动
- 批量重命名
- 旋转后写回文件，JPEG 和 HEIC 只改方向标记，画质无损
- 幻灯片放映，每张停留 1、2、3、5 或 10 秒，切换时渐变 0.5 到 3 秒可调，和手动翻页的渐变分开设置；放映时单击照片暂停、再单击继续，暂停时可以翻看和打星；不动鼠标时缩略图栏和工具条一起隐藏
- 导出压缩副本、设为桌面壁纸、移到废纸篓

**交给后期软件**

在设置里选好 Photoshop、Lightroom、Capture One 之类的软件，之后看到想修的照片按 ⌘E 就用它打开。同名的 RAW 文件也在时，打开的是 RAW。右键菜单和「文件 › 打开方式」里能临时换别的软件。

在后期软件和 Flipic 之间来回切，可以在设置 › 快捷键里录一个全局快捷键：在别的软件里按一下，Flipic 回到最前面；再按一下收起来。

**设置和快捷键**

所有设置都在一个窗口里（⌘,）：排序、翻页渐变、幻灯片间隔、Esc 行为、后期软件、滚轮、默认看图软件。快捷键都可以自己改，带 ⌘ 的组合会同步显示在菜单上。

**格式和语言**

JPEG、PNG、HEIC、WebP、GIF 动图、TIFF、AVIF、JPEG XL（需 macOS 14 或更新），以及常见相机 RAW（ARW、CR2、CR3、NEF、RAF、DNG 等）。界面有 14 种语言，跟随系统设置。

## 快捷键

| 按键 | 作用 |
|---|---|
| ← → | 上一张 / 下一张 |
| ↑ ↓、滚轮 | 放大 / 缩小（滚轮可改成翻页） |
| 空格 | 贴合图片比例预览，再按一次退出 |
| 0 | 在鼠标位置放大到 100%，再按一次恢复 |
| 双击 | 适应窗口 / 100% |
| 1–5 | 打 1 到 5 星 |
| I | 照片信息（右上角面板，Esc 也能关） |
| Esc | 回到适应窗口；在设置里打开「按 Esc 关闭窗口」后，适应窗口时直接关闭 |
| T | 缩略图栏 |
| R / L | 向右 / 向左旋转 |
| S | 幻灯片放映 |
| 回车 | 重命名 |
| ⌘S | 导出压缩副本 |
| ⌘⌫ | 移到废纸篓 |
| ⌘E | 在后期软件中编辑 |
| ⇧⌘K | 清理模式 |
| ⇧⌘C / ⇧⌘B | 批量转换 / 批量重命名 |
| ⌘, | 设置（快捷键都能在这里改） |

## 隐私

Flipic 默认不联网，没有账号，不收集任何数据，只读取你打开的图片。只有你点「检查更新…」或在设置里打开「自动检查更新」时，才会向官网请求一个版本号文件（version.json），不发送任何数据。清理模式的检测结果存在 `~/Library/Caches/Flipic`，不会往你的照片文件夹里写文件。只有你打星时，才会把评分写进照片的元数据或同名 .xmp 文件。代码都在这个仓库里，可以自己查。

## 从源码构建

用 Swift 和 AppKit 写成，没有第三方依赖。需要 macOS 13 或更新版本，以及 Xcode 15 或 Swift 5.9 命令行工具。

```bash
git clone https://github.com/xmasdong/flipic.git
cd flipic
./build.sh                 # 产出 build/Flipic.app，本机临时签名
open build/Flipic.app
```

想用 Xcode 打开，先装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，再运行 `xcodegen generate` 生成工程。

要出带签名和公证的安装包，用 `scripts/build_devid.sh`。签名凭据照 `scripts/devid.env.example` 填进 `scripts/devid.env`，这个文件不进版本库。

### 代码结构

```
Sources/Photoview/
  AppDelegate.swift            菜单栏与启动参数
  ViewerViewController.swift   看图主界面：翻页、预取、HUD、工具条、导出与批量处理
  ZoomableImageView.swift      缩放、拖动、手势、键盘与滚轮
  ImageLoader.swift            ImageIO 降采样解码与按内存分档的缓存
  FolderModel.swift            文件列表与排序
  Filmstrip.swift              底部缩略图栏
  ExifReader.swift             照片信息
  CleanupScanner.swift         清理模式的逐张检测：清晰度、人脸与闭眼、画面特征、哈希
  CleanupResult.swift          分组、推荐保留与默认勾选
  CleanupController.swift      清理模式界面
  SettingsWindowController.swift  设置窗口
  Shortcuts.swift              可自定义的快捷键
  HotKey.swift                 全局快捷键（显示 / 隐藏 Flipic）
  Rating.swift                 星级评分（XMP）
  UpdateChecker.swift          检查更新（默认关，只请求官网的 version.json）
Resources/                     Info.plist、图标、14 种语言的文案
docs/                          官网（GitHub Pages）
scripts/                       签名打包、测试图生成等脚本
scripts/icon/                  图标底稿脚本、山形取材的原图和成品图标
```

调试时可以用这些启动参数，不需要点界面：

```bash
Flipic=build/Flipic.app/Contents/MacOS/Flipic
$Flipic --bench <文件夹>            # 翻页延迟、内存、主线程卡顿
$Flipic --cleanup-report <文件夹>   # 清理模式逐张指标与分类结果
```

## 参与

用着不顺手、发现 bug，或者想要什么功能，都可以开 [Issue](https://github.com/xmasdong/flipic/issues)。PR 也欢迎，尤其是翻译：除了简体中文，其他语言的文案都有改进空间。

## 协议

[MIT](LICENSE)。个人和商业项目都可以自由使用、修改和再发布，保留原作者的版权声明即可。

---

图标先用 `scripts/icon/make_icon.py` 从桂林阳朔的一张照片（Wikimedia Commons，CC0）里提取真实山脊线画成底稿，再照底稿绘制成插画。

截图中的照片来自 Wikimedia Commons，均为 CC0：圣托里尼 Aidan Meyer、Anthony Delanoix，布莱德湖 Aleš Krivec，哈尔施塔特 Fineas Anton、Martin Horák，冰岛 Alexandre Godreau，优胜美地 John Salzarulo，阳朔 Manon Boyer。桌面是 macOS 自带壁纸。
