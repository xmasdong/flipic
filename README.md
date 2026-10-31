<p align="center">
  <img src="docs/icon-256.png" width="128" height="128" alt="PixDeck 图标">
</p>

<h1 align="center">PixDeck</h1>

<p align="center"><b>简体中文</b> · <a href="README.en.md">English</a></p>

<p align="center">
  Mac 上的轻量看图工具。双击一张图，用左右键把整个文件夹翻一遍。
</p>

<p align="center">
  <a href="https://github.com/xmasdong/macphoto/releases/latest/download/PixDeck.dmg"><b>下载 PixDeck.dmg</b></a>
  ·
  <a href="https://xmasdong.github.io/macphoto/">官网</a>
  ·
  <a href="https://github.com/xmasdong/macphoto/releases">历史版本</a>
</p>

<p align="center">
  <a href="https://github.com/xmasdong/macphoto/releases/latest"><img src="https://img.shields.io/github/v/release/xmasdong/macphoto?label=%E7%89%88%E6%9C%AC&color=444" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-444" alt="macOS 13 或更新">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-444" alt="MIT"></a>
</p>

![PixDeck 浏览照片](docs/screenshot-browse.jpg)

用系统自带的「预览」打开一张图，它就只显示这一张，想看下一张得回访达全选再打开。PixDeck 就是为这件事做的：双击任意一张，按 → 就是下一张，同一个文件夹的图片都能翻到。安装包 1.2 MB，不联网，不要账号。

## 下载安装

1. 下载 [PixDeck.dmg](https://github.com/xmasdong/macphoto/releases/latest/download/PixDeck.dmg)，国内下载慢可以从[官网](https://xmasdong.github.io/macphoto/)下
2. 打开 dmg，把 PixDeck 拖进「应用程序」
3. 第一次打开时系统会提示这是从互联网下载的 App，点「打开」

需要 macOS 13 或更新版本，Apple 芯片和 Intel 芯片都能用。安装包用 Developer ID 签名并通过了 Apple 公证。历史版本在 [Releases](https://github.com/xmasdong/macphoto/releases)。

想设成默认看图软件：在访达里右键一张图，选「显示简介」，「打开方式」选 PixDeck，再点「全部更改」。jpg、png、heic 这些格式要各设一次。

## 功能

**看图**

- 同一个文件夹里左右翻页，可以按文件名、拍摄时间、修改时间、创建时间或文件大小排序，会记住上次的选择
- 按空格，窗口贴合照片比例预览，跟访达的空格预览一样，再按一次回到原窗口
- 触控板双指捏合缩放；双击在适应窗口和 100% 之间切换，放大到需要时才解码原图
- 鼠标滚轮默认缩放，也可以在「显示 › 鼠标滚轮」改成翻页
- 左上角显示尺寸、文件大小、相机、镜头、快门、光圈、ISO 和拍摄时间，按 I 看完整的照片信息

**挑片（清理模式，Beta）**

活动、会议一拍几百张时，按 ⇧⌘K 进入清理模式。PixDeck 在本机检查整个文件夹，分成相似连拍、内容完全相同的文件、闭眼、模糊或虚焦四类。连拍组里推荐保留最清楚、没人闭眼的那张，其余默认勾上，闭眼的照片会框出是哪张脸。

删除只在你按下「移到废纸篓」时发生，⌘Z 可以撤销。RAW 和同名 JPG 算一张，一起处理。检测会有误判，删之前过一眼。

![清理模式](docs/shots/cleanup.webp)

**批量处理和其他**

- 整个文件夹批量转换格式（JPEG、PNG、HEIC），输出到子文件夹，原图不动
- 批量重命名
- 旋转后写回文件，JPEG 和 HEIC 只改方向标记，画质无损
- 导出压缩副本、幻灯片放映、设为桌面壁纸、移到废纸篓

**格式和语言**

JPEG、PNG、HEIC、WebP、GIF 动图、TIFF、AVIF、JPEG XL（需 macOS 14 或更新），以及常见相机 RAW（ARW、CR2、CR3、NEF、RAF、DNG 等）。界面有 14 种语言，跟随系统设置。

## 快捷键

| 按键 | 作用 |
|---|---|
| ← → | 上一张 / 下一张 |
| ↑ ↓、滚轮 | 放大 / 缩小（滚轮可改成翻页） |
| 空格 | 贴合图片比例预览，再按一次退出 |
| 双击 | 适应窗口 / 100% |
| I | 照片信息 |
| T | 缩略图栏 |
| R / L | 向右 / 向左旋转 |
| S | 幻灯片放映 |
| 回车 | 重命名 |
| ⌘S | 导出压缩副本 |
| ⌘⌫ | 移到废纸篓 |
| ⇧⌘K | 清理模式 |
| ⇧⌘C / ⇧⌘B | 批量转换 / 批量重命名 |

## 隐私

PixDeck 不联网，没有账号，不收集任何数据，只读取你打开的图片。清理模式的检测结果存在 `~/Library/Caches/PixDeck`，不会往你的照片文件夹里写文件。代码都在这个仓库里，可以自己查。

## 从源码构建

用 Swift 和 AppKit 写成，没有第三方依赖。需要 macOS 13 或更新版本，以及 Xcode 15 或 Swift 5.9 命令行工具。

```bash
git clone https://github.com/xmasdong/macphoto.git
cd macphoto
./build.sh                 # 产出 build/PixDeck.app，本机临时签名
open build/PixDeck.app
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
Resources/                     Info.plist、图标、14 种语言的文案
docs/                          官网（GitHub Pages）
scripts/                       签名打包、测试图生成等脚本
scripts/icon/                  图标底稿脚本、山形取材的原图和成品图标
```

调试时可以用这些启动参数，不需要点界面：

```bash
PixDeck=build/PixDeck.app/Contents/MacOS/PixDeck
$PixDeck --bench <文件夹>            # 翻页延迟、内存、主线程卡顿
$PixDeck --cleanup-report <文件夹>   # 清理模式逐张指标与分类结果
```

## 参与

用着不顺手、发现 bug，或者想要什么功能，都可以开 [Issue](https://github.com/xmasdong/macphoto/issues)。PR 也欢迎，尤其是翻译：除了简体中文，其他语言的文案都有改进空间。

## 协议

[MIT](LICENSE)。个人和商业项目都可以自由使用、修改和再发布，保留原作者的版权声明即可。

---

图标先用 `scripts/icon/make_icon.py` 从桂林阳朔的一张照片（Wikimedia Commons，CC0）里提取真实山脊线画成底稿，再照底稿绘制成插画。

截图中的风景照来自 Wikimedia Commons：喀纳斯湖 Muye Ma、那拉提草原 Yoshi Canopus、沙漠星空 thomas shellberg（CC0）；天山天池 David Stanley、库尔德宁 George Lu、博斯腾湖 liuxingy2015（CC BY 2.0）；果子沟大桥 Timothytyy、将军山 Pazakui（CC BY 4.0）。
