#!/usr/bin/env python3
"""生成 flipic.app 官网：中文在根目录，英文在 /en/。
用法：python3 site/build.py   产出到 site/public，再 wrangler pages deploy site/public --project-name flipic
截图、图标、安装包从 docs/ 复制（docs/ 继续给 GitHub Pages 上的旧地址用）。"""
import html, json, re, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
DOCS = REPO / "docs"
OUT = ROOT / "public"
BASE = "https://flipic.app"
UPDATED = "2026-10-31"
VERSION = json.loads((DOCS / "version.json").read_text())["version"]
SIZE = "1.8 MB"
GITHUB = "https://github.com/xmasdong/macphoto"

# 中英页面一一对应，用来写 hreflang 和语言切换
PAIRS = {
    "/": "/en/",
    "/guides/mac-next-image/": "/en/guides/mac-preview-next-image/",
    "/guides/heic-to-jpg-mac/": "/en/guides/batch-convert-heic-to-jpg-mac/",
    "/guides/windows-image-viewer-for-mac/": "/en/guides/irfanview-for-mac/",
    "/guides/cull-event-photos/": "/en/guides/cull-photos-on-mac/",
}
PAIRS_REV = {v: k for k, v in PAIRS.items()}

DOWNLOAD_ICON = ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
                 'stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/></svg>')

T = {
    "zh": {
        "lang": "zh-CN", "home": "/", "features": "功能", "guides": "指南", "faq": "常见问题",
        "other": "English", "download": "免费下载 Mac 版", "github_alt": "也可以从 <a href=\"{gh}/releases/latest\">GitHub</a> 下载",
        "facts": ["免费开源", "安装包 " + SIZE, "macOS 13 或更新", "Apple 芯片与 Intel 通用", "已通过 Apple 公证", "默认不联网"],
        "phone": "Flipic 是 Mac 软件，手机上装不了。复制网址，到 Mac 的浏览器里打开就能下载。",
        "phone_btn": "复制网址 flipic.app", "phone_done": "已复制，到 Mac 上粘贴打开",
        "crumbs_home": "Flipic", "crumbs_guides": "指南", "updated": "更新于 " + UPDATED,
        "cta": "Flipic 是一款免费开源的 Mac 看图软件，双击一张图，左右键就能翻完整个文件夹。",
        "related": "相关指南",
        "footer_credit": "截图中的照片来自 Wikimedia Commons，均为 CC0：圣托里尼 Aidan Meyer、Anthony Delanoix，布莱德湖 Aleš Krivec，哈尔施塔特 Fineas Anton、Martin Horák，冰岛 Alexandre Godreau，优胜美地 John Salzarulo，阳朔 Manon Boyer。",
        "footer_line": "Flipic {v} · MIT 开源 · 原名 PixDeck",
        "src": "源代码", "feedback": "反馈问题", "releases": "历史版本",
    },
    "en": {
        "lang": "en", "home": "/en/", "features": "Features", "guides": "Guides", "faq": "FAQ",
        "other": "中文", "download": "Download for Mac, free", "github_alt": "or get it from <a href=\"{gh}/releases/latest\">GitHub</a>",
        "facts": ["Free and open source", SIZE + " download", "macOS 13 or later", "Apple silicon and Intel", "Notarized by Apple", "Offline by default"],
        "phone": "Flipic is a Mac app and can't be installed on a phone. Copy the address and open it in a browser on your Mac.",
        "phone_btn": "Copy flipic.app", "phone_done": "Copied. Paste it on your Mac.",
        "crumbs_home": "Flipic", "crumbs_guides": "Guides", "updated": "Updated " + UPDATED,
        "cta": "Flipic is a free, open-source image viewer for Mac: double-click one photo and page through the whole folder with the arrow keys.",
        "related": "More guides",
        "footer_credit": "Photos in the screenshots are from Wikimedia Commons, all CC0: Santorini by Aidan Meyer and Anthony Delanoix, Lake Bled by Aleš Krivec, Hallstatt by Fineas Anton and Martin Horák, Iceland by Alexandre Godreau, Yosemite by John Salzarulo, Yangshuo by Manon Boyer.",
        "footer_line": "Flipic {v} · MIT licensed · formerly PixDeck",
        "src": "Source code", "feedback": "Feedback", "releases": "All releases",
    },
}


def esc(s):
    return html.escape(s, quote=True)


def head(lang, path, title, desc, schema, og_type="website"):
    t = T[lang]
    zh = path if lang == "zh" else PAIRS_REV.get(path)
    en = PAIRS.get(path) if lang == "zh" else path
    alts = ""
    if zh and en:
        alts = (f'<link rel="alternate" hreflang="zh-CN" href="{BASE}{zh}">\n'
                f'<link rel="alternate" hreflang="en" href="{BASE}{en}">\n'
                f'<link rel="alternate" hreflang="x-default" href="{BASE}{en}">\n')
    ld = "\n".join(f'<script type="application/ld+json">{json.dumps(s, ensure_ascii=False)}</script>' for s in schema)
    return f"""<!doctype html>
<html lang="{t['lang']}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(desc)}">
<link rel="canonical" href="{BASE}{path}">
{alts}<link rel="icon" type="image/png" href="/favicon.png">
<link rel="apple-touch-icon" href="/icon-256.png">
<meta name="theme-color" content="#151413">
<meta property="og:type" content="{og_type}">
<meta property="og:site_name" content="Flipic">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:image" content="{BASE}/og.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:url" content="{BASE}{path}">
<meta property="og:locale" content="{'zh_CN' if lang == 'zh' else 'en_US'}">
<meta name="twitter:card" content="summary_large_image">
<link rel="stylesheet" href="/site.css?v={VERSION}">
{ld}
</head>
<body>
<a class="skip" href="#main">{'跳到正文' if lang == 'zh' else 'Skip to content'}</a>
"""


def header(lang, path):
    t = T[lang]
    other = PAIRS.get(path) if lang == "zh" else PAIRS_REV.get(path)
    other = other or ("/en/" if lang == "zh" else "/")
    home = t["home"]
    return f"""<header class="wrap top">
  <a class="brand" href="{home}"><img src="/icon-256.png" alt="" width="30" height="30">Flipic</a>
  <nav>
    <a href="{home}#features">{t['features']}</a>
    <a href="{home}#guides">{t['guides']}</a>
    <a href="{home}#faq">{t['faq']}</a>
    <a class="lang" href="{other}" hreflang="{'en' if lang == 'zh' else 'zh-CN'}">{t['other']}</a>
  </nav>
</header>
"""


def download_block(lang, big=True):
    t = T[lang]
    facts = "".join(f"<li>{f}</li>" for f in t["facts"])
    return f"""<div class="get">
  <a class="btn" href="/download/Flipic.dmg" download>{DOWNLOAD_ICON}{t['download']}</a>
  <span class="alt">{t['github_alt'].format(gh=GITHUB)}</span>
</div>
<ul class="facts">{facts}</ul>
<div class="on-phone"><p>{t['phone']}</p><button class="copy" type="button" data-url="https://flipic.app" data-done="{t['phone_done']}">{t['phone_btn']}</button></div>"""


def footer(lang):
    t = T[lang]
    links = [(g["path"], g["short"]) for g in GUIDES[lang]]
    nav = "".join(f'<a href="{p}">{esc(n)}</a>' for p, n in links)
    return f"""<footer class="wrap">
  <nav>{nav}</nav>
  <p>{t['footer_line'].format(v=VERSION)} · <a href="{GITHUB}">{t['src']}</a> · <a href="{GITHUB}/issues">{t['feedback']}</a> · <a href="{GITHUB}/releases">{t['releases']}</a></p>
  <p>{t['footer_credit']}</p>
</footer>
<script src="/site.js?v={VERSION}" defer></script>
</body>
</html>
"""


def app_schema(lang, desc):
    return {
        "@context": "https://schema.org", "@type": "SoftwareApplication", "name": "Flipic",
        "operatingSystem": "macOS 13+", "applicationCategory": "MultimediaApplication",
        "softwareVersion": VERSION, "fileSize": SIZE.replace(" ", ""),
        "downloadUrl": f"{BASE}/download/Flipic.dmg", "installUrl": f"{BASE}/download/Flipic.dmg",
        "image": f"{BASE}/og.jpg", "screenshot": f"{BASE}/shots/browse-01.webp",
        "url": f"{BASE}{T[lang]['home']}", "inLanguage": T[lang]["lang"],
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "license": "https://opensource.org/licenses/MIT", "isAccessibleForFree": True,
        "codeRepository": GITHUB, "description": desc,
    }


def faq_schema(items):
    return {"@context": "https://schema.org", "@type": "FAQPage",
            "mainEntity": [{"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": re.sub("<[^>]+>", "", a)}} for q, a in items]}


def crumbs_schema(lang, title, path):
    t = T[lang]
    return {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": 1, "name": "Flipic", "item": f"{BASE}{t['home']}"},
        {"@type": "ListItem", "position": 2, "name": t["crumbs_guides"], "item": f"{BASE}{t['home']}#guides"},
        {"@type": "ListItem", "position": 3, "name": title, "item": f"{BASE}{path}"}]}


def shot(name, alt, w=1440, h=900, eager=False):
    load = 'fetchpriority="high"' if eager else 'loading="lazy" decoding="async"'
    return f'<img class="shot" src="/shots/{name}" alt="{esc(alt)}" width="{w}" height="{h}" {load}>'


# ---------------------------------------------------------------- 首页内容

HOME = {
    "zh": {
        "title": "Flipic：免费开源的 Mac 看图软件，双击图片用左右键看下一张",
        "desc": "Flipic 是免费开源的 Mac 看图软件。双击任意图片，用左右方向键翻完整个文件夹；在鼠标处放大到 100%、打星、挑废片、HEIC 批量转 JPG。安装包 1.8 MB，已通过 Apple 公证。",
        "eyebrow": "免费开源的 Mac 看图软件",
        "h1": "双击一张图，<br>左右键翻完整个文件夹",
        "lede": "系统自带的「预览」打开一张图，就只给你看这一张。Flipic 只管看图这件事：往下翻、放大看细节、给照片打星，按键和手感照着 Windows 上顺手的看图软件来做。",
        "deck_hint": "在键盘上按 <kbd>←</kbd><kbd>→</kbd> 试试，这是 Flipic 的真实运行画面",
        "deck_alt": "Flipic 浏览文件夹中的第 {n} 张照片", "prev": "上一张", "next": "下一张",
        "features": [
            ("browse-06.webp", "Flipic 底部缩略图栏与左右翻页按钮", "Mac 上怎么看下一张图片",
             "<p>双击任意一张照片，按 <kbd>→</kbd> 就是下一张，同一个文件夹里的图片都能翻到。可以按文件名、拍摄时间、修改时间、创建时间或大小排序。</p>"
             "<p>按 <kbd>空格</kbd>，窗口会收成照片的比例，竖图就是一个窄窗口，和访达里按空格预览一样。前后几张会提前在后台解码好，4800 万像素的照片按住方向键连翻也跟得上。</p>"),
            ("zoom.webp", "Flipic 在鼠标位置放大到 100% 查看细节", "鼠标指哪，按 0 就在哪放大",
             "<p>鼠标停在想看的地方，按 <kbd>0</kbd> 就在那里放大到 100%，再按一次回到全图。触控板捏合、滚轮缩放都以光标为中心。</p>"
             "<p>平时只解码屏幕需要的尺寸，放大到看得出差别时才换成原图，所以几十张大图翻下来内存也不高。</p>"),
            ("exif.webp", "Flipic 照片信息面板显示相机、镜头与拍摄参数", "平时只有照片，想看参数按 I",
             "<p>界面默认不显示任何信息。按 <kbd>I</kbd> 在右上角看相机、镜头、快门、光圈、ISO、拍摄时间和尺寸，按 <kbd>Esc</kbd> 关掉。</p>"
             "<p>iPhone 拍的 HDR 照片可以按 HDR 显示，亮部比普通白更亮，和系统「预览」一样（设置里打开，需要支持 HDR 的屏幕）。</p>"),
            ("cleanup.webp", "Flipic 清理模式：相似连拍分组与推荐保留", "活动照片太多，先把废片挑出来",
             "<p>按 <kbd>⇧⌘K</kbd> 进入清理模式（Beta）。Flipic 在本机检查整个文件夹，分出相似连拍、内容完全相同、闭眼、模糊四类，每组推荐保留最清楚的一张。</p>"
             "<p>删不删由你决定，只有按「移到废纸篓」才会删除，<kbd>⌘Z</kbd> 可以撤销。RAW 和同名 JPG 一起处理。</p>"),
            ("settings.webp", "Flipic 设置窗口：快捷键可以自己改", "打星、改键，按你的习惯来",
             "<p>按 <kbd>1</kbd> 到 <kbd>5</kbd> 打星。评分按 XMP 标准写入，Lightroom、Bridge、Capture One 都能读到：JPEG、HEIC 只改元数据不重新压缩，专有 RAW 写在同名 .xmp 文件里。</p>"
             "<p>所有设置收在一个窗口里（<kbd>⌘,</kbd>），每个快捷键都能改。还能录一个全局快捷键，在 Photoshop 里按一下 Flipic 就出来，再按一下收回去。</p>"),
        ],
        "more_title": "其他你可能用得上的",
        "more": [
            ("交给后期软件", "按 ⌘E 用 Photoshop、Lightroom 或 Capture One 打开当前照片，同名 RAW 在时打开 RAW。"),
            ("幻灯片放映", "每张 1 到 10 秒，渐变时长可调；单击暂停，再单击继续，暂停时能翻看和打星。"),
            ("HEIC 批量转 JPG", "整个文件夹一次转成 JPEG、PNG 或 HEIC，放进子文件夹，原图不动。"),
            ("旋转写回文件", "JPEG、HEIC 只改方向标记，画质无损。"),
            ("批量重命名、导出压缩副本", "按序号批量改名；导出时能选格式和质量，先看预计大小。"),
            ("14 种界面语言", "跟随系统设置，中文、英文、日文、韩文、德文、法文等。"),
        ],
        "vs_title": "和系统自带的「预览」比",
        "vs_head": ("", "预览", "Flipic"),
        "vs": [
            ("打开一张后看下一张", "要回访达全选再打开", "直接按 ← →"),
            ("在鼠标处放大到 100%", "没有单键操作", "按 0"),
            ("打星（Lightroom 能读）", "不支持", "按 1–5"),
            ("挑出连拍、闭眼、模糊", "不支持", "清理模式"),
            ("HEIC 批量转 JPG", "可以，要逐步导出", "整个文件夹一次转完"),
        ],
        "keys_title": "常用快捷键",
        "keys": [("← →", "上一张 / 下一张"), ("空格", "窗口贴合照片比例"), ("0", "在鼠标处放大到 100%，再按恢复"),
                 ("I", "照片信息"), ("1–5", "打 1 到 5 星"), ("S", "幻灯片放映"), ("⌘E", "在后期软件中编辑"),
                 ("⇧⌘K", "清理模式"), ("⌘⌫", "移到废纸篓"), ("⌘,", "设置，快捷键都能改")],
        "guides_title": "指南",
        "faq": [
            ("Flipic 收费吗？", "免费，没有内购、没有广告，也不用注册账号。代码以 MIT 协议开源在 GitHub。"),
            ("从网上下载的安全吗？", "安装包用 Developer ID 签名，并通过了 Apple 公证，macOS 安装时会自动校验。Flipic 默认不联网，不收集任何数据。"),
            ("Mac 上怎么看下一张图片？", "用 Flipic 双击任意一张图片，按右方向键就是下一张，左方向键是上一张，同一个文件夹里的图片都能翻到。"),
            ("怎么设为默认看图软件？", "打开 Flipic 的设置（⌘,），在「通用」里点「设为默认看图软件」，常见图片格式和相机 RAW 一次设好。"),
            ("支持哪些格式？", "JPEG、PNG、HEIC、WebP、GIF 动图、TIFF、AVIF、JPEG XL（macOS 14 起），以及索尼、佳能、尼康、富士等相机 RAW。"),
            ("Intel 芯片的 Mac 能用吗？", "能。Flipic 同时支持 Apple 芯片和 Intel 芯片，需要 macOS 13 或更新版本。"),
            ("以前装过 PixDeck 怎么办？", "Flipic 就是改名后的 PixDeck。把「应用程序」里的 PixDeck 拖进废纸篓，再装 Flipic，原来的设置都会保留。"),
        ],
        "end": "下载 Flipic",
    },
    "en": {
        "title": "Flipic: free image viewer for Mac with arrow-key browsing",
        "desc": "Free, open-source image viewer for Mac. Double-click a photo and page through the folder with the arrow keys; zoom at the pointer, rate, cull and convert HEIC.",
        "eyebrow": "Free, open-source image viewer for Mac",
        "h1": "Double-click one photo,<br>page through the whole folder",
        "lede": "Open a single image in Preview and that is all you see. Flipic does one job well: next photo, zoom into detail, rate as you go, with the keys and feel of the viewers people loved on Windows.",
        "deck_hint": "Press <kbd>←</kbd><kbd>→</kbd> on your keyboard. These are real Flipic screenshots",
        "deck_alt": "Flipic showing photo {n} in a folder", "prev": "Previous", "next": "Next",
        "features": [
            ("browse-06.webp", "Flipic thumbnail strip and navigation arrows", "The next image, one key away",
             "<p>Double-click any photo and press <kbd>→</kbd> for the next one, across the whole folder. Sort by name, date taken, date modified, date created or size.</p>"
             "<p>Press <kbd>Space</kbd> and the window wraps to the photo's shape, a narrow window for a portrait shot, just like Quick Look. Nearby photos are decoded ahead of time, so even 48-megapixel images keep up when you hold an arrow key.</p>"),
            ("zoom.webp", "Flipic zooming to 100% at the pointer", "Point, press 0, see every pixel",
             "<p>Rest the pointer on a detail and press <kbd>0</kbd> to zoom to 100% right there; press it again to go back. Pinch and scroll zoom around the pointer too.</p>"
             "<p>Flipic decodes only what the screen needs and loads the original when you zoom in far enough to tell, so memory stays low across a big folder.</p>"),
            ("exif.webp", "Flipic photo info panel", "Just the photo. EXIF on I",
             "<p>Nothing but the photo by default. Press <kbd>I</kbd> for camera, lens, shutter speed, aperture, ISO, date taken and size; <kbd>Esc</kbd> closes it.</p>"
             "<p>HDR photos from iPhone can be shown in HDR, with highlights brighter than regular white, as in Preview (turn it on in Settings; needs an HDR display).</p>"),
            ("cleanup-en.webp", "Flipic Cleanup Mode grouping similar bursts", "Cull an event shoot fast",
             "<p>Press <kbd>⇧⌘K</kbd> for Cleanup Mode (Beta). Flipic checks the folder on your Mac and sorts out similar bursts, exact duplicates, closed eyes and blurry shots, suggesting the sharpest frame of each burst.</p>"
             "<p>Nothing is deleted until you press Move to Trash, and <kbd>⌘Z</kbd> brings files back. RAW+JPG pairs are handled together.</p>"),
            ("settings-en.webp", "Flipic settings with customizable shortcuts", "Rate, remap, work your way",
             "<p>Press <kbd>1</kbd> to <kbd>5</kbd> to rate. Ratings are standard XMP that Lightroom, Bridge and Capture One read: metadata only for JPEG and HEIC, a same-name .xmp sidecar for proprietary RAW.</p>"
             "<p>Every setting lives in one window (<kbd>⌘,</kbd>) and every shortcut can be changed. Record a global shortcut to bring Flipic forward from Photoshop and hide it again.</p>"),
        ],
        "more_title": "Also in the box",
        "more": [
            ("Hand off to your editor", "⌘E opens the photo in Photoshop, Lightroom or Capture One; the RAW if one sits next to it."),
            ("Slideshow", "1 to 10 seconds per photo with an adjustable crossfade; click to pause, click to resume."),
            ("Batch convert HEIC to JPG", "Convert a whole folder to JPEG, PNG or HEIC into a subfolder; originals stay untouched."),
            ("Lossless rotate", "JPEG and HEIC rotation only changes the orientation tag."),
            ("Batch rename, export copies", "Rename by sequence; export with a format and quality preview of the file size."),
            ("14 interface languages", "Follows your system language."),
        ],
        "vs_title": "Compared with Preview",
        "vs_head": ("", "Preview", "Flipic"),
        "vs": [
            ("Next image after opening one", "Go back and select all in Finder", "Just press ← →"),
            ("Zoom to 100% at the pointer", "No single key", "Press 0"),
            ("Star ratings Lightroom can read", "No", "Press 1–5"),
            ("Find bursts, closed eyes, blur", "No", "Cleanup Mode"),
            ("Batch convert HEIC to JPG", "Yes, export step by step", "A whole folder at once"),
        ],
        "keys_title": "Keyboard shortcuts",
        "keys": [("← →", "Previous / next photo"), ("Space", "Wrap the window to the photo"), ("0", "Zoom to 100% at the pointer"),
                 ("I", "Photo info"), ("1–5", "Rate one to five stars"), ("S", "Slideshow"), ("⌘E", "Edit in your photo editor"),
                 ("⇧⌘K", "Cleanup Mode"), ("⌘⌫", "Move to Trash"), ("⌘,", "Settings; change any shortcut")],
        "guides_title": "Guides",
        "faq": [
            ("Is Flipic free?", "Yes. No in-app purchases, no ads, no account. The code is MIT licensed on GitHub."),
            ("Is the download safe?", "It is signed with a Developer ID and notarized by Apple; macOS checks it on install. Flipic is offline by default and collects no data."),
            ("How do I see the next image on a Mac?", "Double-click any image in Flipic and press the right arrow key for the next one, the left arrow for the previous one, across the whole folder."),
            ("How do I make it my default viewer?", "Open Settings (⌘,) and click Make Default Viewer under General; common image formats and camera RAW are set in one go."),
            ("Which formats are supported?", "JPEG, PNG, HEIC, WebP, animated GIF, TIFF, AVIF, JPEG XL (macOS 14 or later) and camera RAW from Sony, Canon, Nikon, Fujifilm and others."),
            ("Does it run on Intel Macs?", "Yes. Flipic is universal for Apple silicon and Intel and needs macOS 13 or later."),
        ],
        "end": "Download Flipic",
    },
}

# ---------------------------------------------------------------- 指南

GUIDES = {"zh": [], "en": []}


def guide(lang, path, title, short, desc, summary, body, howto=None):
    GUIDES[lang].append(dict(path=path, title=title, short=short, desc=desc, summary=summary, body=body, howto=howto))


guide("zh", "/guides/mac-next-image/", "Mac 预览怎么看下一张图片？三种办法",
      "Mac 预览怎么看下一张",
      "Mac 自带的「预览」打开一张图后翻不到下一张。这里讲三种办法：访达里全选再打开、空格快速查看、用 Flipic 双击后直接按左右键。",
      "预览只打开单张时翻不了；全选打开、空格快速查看、换个看图软件",
      f"""<p>在访达里双击一张照片，「预览」只会打开这一张，按方向键没有反应。这是因为预览只显示你交给它的文件，没打开的那些它不知道。下面三种办法按顺手程度排。</p>
<h2>办法一：在访达里全选，再一起打开</h2>
<ol><li>在访达里打开照片所在的文件夹，按 <kbd>⌘A</kbd> 全选。</li><li>按 <kbd>⌘↓</kbd>（或右键选「打开」），所有图片会一起进到预览里。</li><li>在预览里按 <kbd>↑</kbd> <kbd>↓</kbd> 或 <kbd>←</kbd> <kbd>→</kbd> 切换，左侧边栏是缩略图。</li></ol>
<p>缺点是每次都得先回访达全选；文件夹里几百张时，一次全部打开会慢。</p>
<h2>办法二：选中后按空格，用「快速查看」翻</h2>
<p>在访达里选中多张图片（或 <kbd>⌘A</kbd> 全选），按 <kbd>空格</kbd> 打开快速查看，再按 <kbd>←</kbd> <kbd>→</kbd> 就能在选中的图片之间切换。看完按 <kbd>空格</kbd> 或 <kbd>Esc</kbd> 关掉。</p>
<p>快速查看适合扫一眼。放大、看拍摄参数、删除这些操作它都不方便。</p>
<h2>办法三：用 Flipic，双击后直接按左右键</h2>
<p>Flipic 是免费开源的 Mac 看图软件。双击任意一张，按 <kbd>→</kbd> 就是下一张，同一个文件夹里的图片都能翻到，不用先全选。</p>
<figure>{shot('browse-06.webp', 'Flipic 打开一张照片后按方向键翻看同一文件夹')}<figcaption>Flipic 打开一张后，底部缩略图栏是整个文件夹。</figcaption></figure>
<p>想以后双击照片都用 Flipic 打开：在 Flipic 的设置（<kbd>⌘,</kbd>）里点「设为默认看图软件」。也可以在访达里右键一张图，按住 <kbd>⌥</kbd>，选「始终以此方式打开」› Flipic。</p>
<p>设好之后可以当快速查看用：在访达里选中照片按 <kbd>⌘↓</kbd> 打开，左右翻看；在设置里打开「按 Esc 关闭窗口」，看完按 <kbd>Esc</kbd> 回到访达。</p>""",
      howto=["在访达里双击任意一张图片，用 Flipic 打开", "按右方向键看下一张，左方向键看上一张", "按 0 在鼠标处放大到 100%，再按一次回到全图"])

guide("zh", "/guides/heic-to-jpg-mac/", "Mac 怎么批量把 HEIC 转成 JPG（不用装 Photoshop）",
      "Mac 批量 HEIC 转 JPG",
      "iPhone 拍的 HEIC 照片发到 Windows 打不开。Mac 上不装付费软件也能批量转 JPG：访达快速操作、预览导出、终端 sips 命令，以及用 Flipic 整个文件夹一次转完。",
      "访达快速操作、预览导出、sips 命令、整个文件夹一次转",
      f"""<p>iPhone 默认用 HEIC 存照片，体积小，但很多 Windows 电脑、网页表单和旧软件打不开。Mac 自带的工具就能转，区别在于一次能转多少、要点几下。</p>
<h2>办法一：访达右键「转换图像」</h2>
<ol><li>在访达里选中要转的 HEIC 照片（可以多选）。</li><li>右键，选「快速操作」›「转换图像」。</li><li>格式选 JPEG，图像大小选「实际大小」，点「转换为 JPEG」。</li></ol>
<p>转好的 JPG 会放在原图旁边。这是 macOS 12 起自带的功能，几十张以内很方便。</p>
<h2>办法二：在「预览」里导出</h2>
<p>把照片全选后用预览打开，在左侧边栏 <kbd>⌘A</kbd> 全选缩略图，选「文件」›「导出所选图像…」，在选项里把格式改成 JPEG。适合想顺便调质量的时候。</p>
<h2>办法三：终端里用 sips 命令</h2>
<p>macOS 自带 <code>sips</code> 命令。进入照片所在的文件夹后运行：</p>
<pre><code>mkdir -p jpg && for f in *.HEIC *.heic; do [ -e "$f" ] && sips -s format jpeg "$f" --out "jpg/${{f%.*}}.jpg"; done</code></pre>
<p>转好的文件在 <code>jpg</code> 子文件夹里，原图不动。几千张也能一次跑完，就是要会用终端。</p>
<h2>办法四：用 Flipic，整个文件夹一次转完</h2>
<ol><li>用 Flipic 打开要转换的文件夹。</li><li>菜单「工具」›「批量转换格式」，或按 <kbd>⇧⌘C</kbd>。</li><li>选 JPEG，拖动滑杆调质量，开始转换。</li></ol>
<figure>{shot('convert.webp', 'Flipic 批量转换格式对话框，可选 JPEG、PNG、HEIC 与质量')}<figcaption>转好的文件放进子文件夹，原图不动。</figcaption></figure>
<p>Flipic 也能反过来把 JPEG、PNG 转成 HEIC 省空间，同样整个文件夹一次转完。</p>""",
      howto=["用 Flipic 打开要转换的文件夹", "选择工具 › 批量转换格式（⇧⌘C）", "格式选 JPEG，调好质量后开始转换"])

guide("zh", "/guides/windows-image-viewer-for-mac/", "从 Windows 换到 Mac，Honeyview、IrfanView 的替代用什么",
      "Honeyview、IrfanView 的 Mac 替代",
      "Honeyview（蜂蜜浏览器）和 IrfanView 都只有 Windows 版。刚换到 Mac 想要同样的看图手感，可以看看 Flipic、XnView MP、qView 这几个能在 Mac 上用的看图软件。",
      "Windows 看图软件没有 Mac 版时，按手感和需求挑一个",
      f"""<p>Honeyview（蜂蜜浏览器）、IrfanView、Windows 自带的照片查看器，都是打开一张图后用方向键往下翻、滚轮缩放。Mac 上系统的「预览」不是这样用的，刚换过来的人最先不习惯的就是这一点。</p>
<h2>Honeyview 和 IrfanView 有 Mac 版吗</h2>
<p>没有。Honeyview 由 Bandisoft 开发，只出了 Windows 版；IrfanView 官方也只支持 Windows。网上的「Mac 版」要么是别的软件，要么是用 Wine 套壳运行，不建议装来路不明的安装包。</p>
<h2>Mac 上可以用的替代</h2>
<p><strong>Flipic</strong>：免费开源，安装包 1.8 MB。双击一张图后用 <kbd>←</kbd> <kbd>→</kbd> 翻完整个文件夹，滚轮默认缩放，按 <kbd>0</kbd> 在鼠标处放大到 100%，这些都照着 Windows 看图软件的手感来做。快捷键都能在设置里改；用 Mos 改过滚轮方向的，可以把缩放方向反过来。</p>
<p><strong>XnView MP</strong>：功能很全的跨平台看图和管理软件，个人使用免费。适合需要大量格式转换、元数据编辑的人，界面比较复杂。</p>
<p><strong>qView</strong>：开源的极简看图软件，界面几乎只有图片。功能少，适合只想打开看看的人。</p>
<h2>换过来后常见的几处不同</h2>
<ul><li><strong>设成默认：</strong>在 Flipic 设置里点「设为默认看图软件」，以后双击照片就用它打开。</li><li><strong>删除照片：</strong>Mac 上是 <kbd>⌘⌫</kbd> 移到废纸篓，不是 Delete 键。</li><li><strong>滚轮方向：</strong>Mac 默认是「自然滚动」，方向和 Windows 相反，可以在系统设置里改，或用 Mos 只改鼠标。</li></ul>
<figure>{shot('zoom.webp', 'Flipic 在鼠标位置放大到 100%')}<figcaption>按 0 在鼠标处放大到 100%，再按一次回到全图。</figcaption></figure>""")

guide("zh", "/guides/cull-event-photos/", "活动照片几百张，怎么在 Mac 上快速挑片",
      "活动照片快速挑片",
      "会议、婚礼、活动一拍就是几百张。讲一个在 Mac 上挑片的流程：先自动挑出连拍、闭眼、模糊的废片，再快速翻看打星，最后把留下的交给 Lightroom 修。",
      "先清废片，再打星，最后交给后期",
      f"""<p>活动照片最花时间的不是修图，是从几百张里挑出能用的几十张。下面这个流程用 Flipic 一个软件就能走完，照片不用导进任何图库。</p>
<h2>第一步：先让软件挑出明显的废片</h2>
<p>用 Flipic 打开整个文件夹，按 <kbd>⇧⌘K</kbd> 进入清理模式（Beta）。它在本机检查每一张，分成四类：相似连拍、内容完全相同、闭眼、模糊或虚焦。连拍组里推荐保留最清楚、没人闭眼的那张，其余默认勾上。</p>
<figure>{shot('cleanup.webp', 'Flipic 清理模式按相似连拍分组并推荐保留', 1440, 967)}<figcaption>闭眼的照片会框出是哪张脸，空格放大检查。</figcaption></figure>
<p>只有你按「移到废纸篓」才会删除，删错了 <kbd>⌘Z</kbd> 撤销。自动判断会有误判，删之前过一眼。</p>
<h2>第二步：快速翻看，用星级标出要的</h2>
<p>剩下的照片按 <kbd>→</kbd> 一张张翻，喜欢的按 <kbd>1</kbd> 到 <kbd>5</kbd> 打星，想看细节就把鼠标停在脸上按 <kbd>0</kbd> 放大到 100%。也可以开幻灯片放映，看到好的单击暂停，打完星再单击继续。</p>
<p>星级按 XMP 标准写入：JPEG、HEIC 写进文件本身，专有 RAW 写在同名 .xmp 文件里，原始文件不动。</p>
<h2>第三步：把选好的交给后期</h2>
<p>在 Flipic 设置里选好 Lightroom、Photoshop 或 Capture One，看到要修的照片按 <kbd>⌘E</kbd> 打开，同名 RAW 在时打开 RAW。导入 Lightroom 时，刚才打的星级也会一起带过去，可以直接按星级筛选。</p>""",
      howto=["用 Flipic 打开整个文件夹，按 ⇧⌘K 进入清理模式", "确认要删的连拍、闭眼、模糊照片，移到废纸篓", "翻看剩下的照片，按 1–5 打星", "按 ⌘E 把选中的照片交给 Lightroom 或 Photoshop"])

guide("en", "/en/guides/mac-preview-next-image/", "How to see the next image in Mac Preview",
      "Next image in Mac Preview",
      "Preview opens only the image you double-clicked, so arrow keys do nothing. Three ways to page through a folder: select all, Quick Look, or Flipic.",
      "Open them all, Quick Look, or a viewer that just pages",
      f"""<p>Double-click a photo in Finder and Preview opens that one file; the arrow keys go nowhere because Preview only knows about the files you handed it. Here are three ways around that, from most to least effort.</p>
<h2>1. Select all in Finder, then open</h2>
<ol><li>Open the folder in Finder and press <kbd>⌘A</kbd>.</li><li>Press <kbd>⌘↓</kbd> (or choose Open). Every image lands in one Preview window.</li><li>Use <kbd>↑</kbd> <kbd>↓</kbd> or <kbd>←</kbd> <kbd>→</kbd> to move between them; thumbnails sit in the sidebar.</li></ol>
<p>You have to go back to Finder every time, and opening hundreds of files at once is slow.</p>
<h2>2. Use Quick Look with Space</h2>
<p>Select several images in Finder (or <kbd>⌘A</kbd>), press <kbd>Space</kbd>, then <kbd>←</kbd> <kbd>→</kbd> to step through the selection. Press <kbd>Space</kbd> or <kbd>Esc</kbd> to close.</p>
<p>Fine for a glance; awkward for zooming, reading EXIF or deleting.</p>
<h2>3. Use Flipic and just press the arrow keys</h2>
<p>Flipic is a free, open-source image viewer for Mac. Double-click any photo and press <kbd>→</kbd> for the next one in the folder, no selecting first.</p>
<figure>{shot('browse-06.webp', 'Flipic paging through a folder with the arrow keys')}<figcaption>Open one photo; the thumbnail strip is the whole folder.</figcaption></figure>
<p>To make Flipic open photos by default, click Make Default Viewer in Settings (<kbd>⌘,</kbd>), or Control-click an image in Finder, hold <kbd>⌥</kbd> and choose Always Open With › Flipic.</p>
<p>It then works like Quick Look: select a photo, press <kbd>⌘↓</kbd>, page with the arrows, and with Esc Closes Window turned on, press <kbd>Esc</kbd> to go back to Finder.</p>""",
      howto=["Double-click any image in Finder to open it in Flipic", "Press the right arrow key for the next image and the left arrow for the previous one", "Press 0 to zoom to 100% at the pointer; press it again to fit"])

guide("en", "/en/guides/batch-convert-heic-to-jpg-mac/", "How to batch convert HEIC to JPG on Mac",
      "Batch convert HEIC to JPG",
      "Four free ways to batch convert iPhone HEIC photos to JPG on a Mac: Finder Convert Image, Preview export, the sips command, or Flipic.",
      "Finder quick action, Preview, sips, or a whole folder at once",
      f"""<p>iPhones save photos as HEIC: small files, but many Windows PCs, web forms and older apps can't open them. Your Mac can convert them without paid software; the difference is how many at a time and how many clicks.</p>
<h2>1. Finder: Convert Image</h2>
<ol><li>Select the HEIC files in Finder.</li><li>Control-click and choose Quick Actions › Convert Image.</li><li>Pick JPEG and Actual Size, then click Convert to JPEG.</li></ol>
<p>The JPGs appear next to the originals. Built in since macOS 12; handy for a few dozen files.</p>
<h2>2. Export from Preview</h2>
<p>Open the photos together in Preview, select all thumbnails in the sidebar, choose File › Export Selected Images…, and set the format to JPEG in Options.</p>
<h2>3. The sips command in Terminal</h2>
<pre><code>mkdir -p jpg && for f in *.HEIC *.heic; do [ -e "$f" ] && sips -s format jpeg "$f" --out "jpg/${{f%.*}}.jpg"; done</code></pre>
<p>Run it inside the photo folder. Results go to a <code>jpg</code> subfolder and thousands of files are fine.</p>
<h2>4. Flipic: a whole folder at once</h2>
<ol><li>Open the folder in Flipic.</li><li>Choose Tools › Batch Convert, or press <kbd>⇧⌘C</kbd>.</li><li>Pick JPEG, set the quality and start.</li></ol>
<figure>{shot('convert.webp', 'Flipic batch convert dialog with JPEG, PNG and HEIC')}<figcaption>Converted files go into a subfolder; originals stay untouched.</figcaption></figure>""",
      howto=["Open the folder in Flipic", "Choose Tools › Batch Convert (⇧⌘C)", "Pick JPEG, set the quality and start the conversion"])

guide("en", "/en/guides/irfanview-for-mac/", "IrfanView for Mac? Free alternatives that feel the same",
      "IrfanView for Mac alternatives",
      "IrfanView and Honeyview are Windows-only. If you just moved to a Mac and miss arrow-key browsing and wheel zoom, try Flipic, XnView MP or qView.",
      "No Mac version exists; pick by feel and needs",
      f"""<p>IrfanView, Honeyview and the Windows Photos viewer all work the same way: open one image, press the arrow keys to page, scroll to zoom. Preview on Mac doesn't, and it's the first thing switchers miss.</p>
<h2>Is there an IrfanView for Mac?</h2>
<p>No. IrfanView officially supports Windows only, and Honeyview from Bandisoft is Windows-only too. Anything labeled "for Mac" is either a different app or Windows software wrapped in Wine, so be careful with unofficial installers.</p>
<h2>Alternatives that run natively on a Mac</h2>
<p><strong>Flipic</strong>: free and open source, a 1.8 MB download. Double-click a photo and page with <kbd>←</kbd> <kbd>→</kbd>; the wheel zooms by default; <kbd>0</kbd> zooms to 100% at the pointer. Every shortcut can be remapped, and if you reversed your wheel with Mos you can flip the zoom direction.</p>
<p><strong>XnView MP</strong>: a full-featured cross-platform viewer and organizer, free for personal use; great for heavy conversion and metadata work, busier interface.</p>
<p><strong>qView</strong>: a minimal open-source viewer that is little more than the image; few features by design.</p>
<h2>Things that work differently on a Mac</h2>
<ul><li><strong>Default viewer:</strong> click Make Default Viewer in Flipic's Settings.</li><li><strong>Deleting:</strong> <kbd>⌘⌫</kbd> moves a photo to the Trash; the Delete key alone doesn't.</li><li><strong>Scroll direction:</strong> macOS uses natural scrolling, the reverse of Windows; change it in System Settings or for the mouse only with Mos.</li></ul>
<figure>{shot('zoom.webp', 'Flipic zooming to 100% at the pointer')}<figcaption>Press 0 to zoom to 100% under the pointer; press it again to fit.</figcaption></figure>""")

guide("en", "/en/guides/cull-photos-on-mac/", "How to cull hundreds of event photos on a Mac",
      "Cull event photos on Mac",
      "A fast culling workflow on Mac: remove bursts, closed eyes and blur automatically, rate the rest with 1–5, then open keepers in Lightroom.",
      "Clear the rejects, rate the rest, hand off to your editor",
      f"""<p>The slow part of an event shoot isn't editing; it's finding the fifty usable frames among hundreds. This workflow runs in Flipic alone, with no catalog import.</p>
<h2>1. Let the app find the obvious rejects</h2>
<p>Open the folder in Flipic and press <kbd>⇧⌘K</kbd> for Cleanup Mode (Beta). It checks every photo on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry or out-of-focus shots, suggesting the sharpest blink-free frame of each burst.</p>
<figure>{shot('cleanup-en.webp', 'Flipic Cleanup Mode grouping bursts and suggesting a keeper', 1440, 967)}<figcaption>Faces flagged for closed eyes are outlined; Space zooms in to check.</figcaption></figure>
<p>Nothing is deleted until you press Move to Trash, and <kbd>⌘Z</kbd> undoes it. Detection can be wrong, so look before you delete.</p>
<h2>2. Page through and rate</h2>
<p>Press <kbd>→</kbd> through what's left and <kbd>1</kbd>–<kbd>5</kbd> to rate. Rest the pointer on a face and press <kbd>0</kbd> to check focus at 100%. Or run a slideshow, click to pause on a good one, rate it, click to resume.</p>
<p>Ratings are standard XMP: inside JPEG and HEIC files, in a same-name .xmp sidecar for proprietary RAW, leaving the RAW untouched.</p>
<h2>3. Hand the keepers to your editor</h2>
<p>Choose Lightroom, Photoshop or Capture One in Settings and press <kbd>⌘E</kbd> on a photo to open it there, the RAW if one sits next to the JPEG. Lightroom picks up the star ratings on import, so you can filter by them right away.</p>""",
      howto=["Open the folder in Flipic and press ⇧⌘K for Cleanup Mode", "Review the suggested bursts, closed eyes and blurry shots and move them to the Trash", "Page through the rest and rate with 1–5", "Press ⌘E to open keepers in Lightroom or Photoshop"])


# ---------------------------------------------------------------- 渲染

def render_home(lang):
    h = HOME[lang]
    t = T[lang]
    path = t["home"]
    schema = [app_schema(lang, h["desc"]), faq_schema(h["faq"]),
              {"@context": "https://schema.org", "@type": "WebSite", "name": "Flipic", "url": f"{BASE}{path}", "inLanguage": t["lang"]}]
    out = head(lang, path, h["title"], h["desc"], schema) + header(lang, path)
    first = f'<img class="on" src="/shots/browse-01.webp" alt="{esc(h["deck_alt"].format(n=1))}" width="1440" height="900" fetchpriority="high">'
    out += f"""<main id="main">
<section class="wrap hero">
  <p class="eyebrow rise">{h['eyebrow']}</p>
  <h1 class="rise">{h['h1']}</h1>
  <p class="lede rise">{h['lede']}</p>
  <div class="rise">{download_block(lang)}</div>
</section>
<section class="wrap stage" aria-label="{'翻页演示' if lang == 'zh' else 'Paging demo'}">
  <div class="frame" id="frame" data-total="8" data-base="/shots/" data-alt="{esc(h['deck_alt'])}">{first}</div>
  <div class="deck">
    <span class="hint-keys">{h['deck_hint']}</span>
    <span class="keys">
      <button type="button" data-step="-1" aria-label="{h['prev']}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m15 18-6-6 6-6"/></svg></button>
      <span class="count" id="count" aria-live="polite">1 / 8</span>
      <button type="button" data-step="1" aria-label="{h['next']}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button>
    </span>
  </div>
</section>
<div class="wrap" id="features">
"""
    for i, (img, alt, h2, body) in enumerate(h["features"]):
        dims = (1440, 967) if img.startswith("cleanup") else (1440, 900)
        out += f"""<section class="feature{' flip' if i % 2 else ''}">
  <div class="copytext"><h2>{h2}</h2>{body}</div>
  {shot(img, alt, *dims)}
</section>
"""
    out += "</div>\n"
    more = "".join(f"<li><b>{esc(a)}</b>{esc(b)}</li>" for a, b in h["more"])
    out += f'<section class="wrap more"><h2>{h["more_title"]}</h2><ul>{more}</ul></section>\n'
    vs_rows = "".join(f"<tr><td>{esc(a)}</td><td>{esc(b)}</td><td class=\"yes\">{esc(c)}</td></tr>" for a, b, c in h["vs"])
    keys_rows = "".join(f"<tr><td>{esc(k)}</td><td>{esc(v)}</td></tr>" for k, v in h["keys"])
    hd = h["vs_head"]
    out += f"""<section class="wrap tables"><div class="cols">
  <div><h2>{h['vs_title']}</h2><table><thead><tr><th>{hd[0]}</th><th>{hd[1]}</th><th>{hd[2]}</th></tr></thead><tbody>{vs_rows}</tbody></table></div>
  <div><h2>{h['keys_title']}</h2><table><tbody>{keys_rows}</tbody></table></div>
</div></section>
"""
    items = "".join(f'<li><a href="{g["path"]}"><b>{esc(g["title"])}</b><span>{esc(g["summary"])}</span></a></li>' for g in GUIDES[lang])
    out += f'<section class="wrap guides" id="guides"><h2>{h["guides_title"]}</h2><ol>{items}</ol></section>\n'
    faqs = "".join(f"<details><summary>{esc(q)}</summary><p>{a}</p></details>" for q, a in h["faq"])
    out += f'<section class="wrap faq" id="faq"><h2>{t["faq"]}</h2>{faqs}</section>\n'
    out += f'<section class="wrap end"><h2>{h["end"]}</h2>{download_block(lang)}</section>\n</main>\n'
    return out + footer(lang)


def render_guide(lang, g):
    t = T[lang]
    schema = [crumbs_schema(lang, g["title"], g["path"]),
              {"@context": "https://schema.org", "@type": "Article", "headline": g["title"], "description": g["desc"],
               "inLanguage": t["lang"], "datePublished": UPDATED, "dateModified": UPDATED, "image": f"{BASE}/og.jpg",
               "mainEntityOfPage": f"{BASE}{g['path']}", "author": {"@type": "Organization", "name": "Flipic"},
               "publisher": {"@type": "Organization", "name": "Flipic", "logo": {"@type": "ImageObject", "url": f"{BASE}/icon-256.png"}}}]
    if g["howto"]:
        schema.append({"@context": "https://schema.org", "@type": "HowTo", "name": g["title"], "inLanguage": t["lang"],
                       "tool": [{"@type": "HowToTool", "name": "Flipic"}],
                       "step": [{"@type": "HowToStep", "position": i + 1, "text": s} for i, s in enumerate(g["howto"])]})
    out = head(lang, g["path"], g["title"] + " | Flipic", g["desc"], schema, og_type="article") + header(lang, g["path"])
    related = "".join(f'<a href="{o["path"]}">{esc(o["title"])}</a>' for o in GUIDES[lang] if o is not g)
    out += f"""<main id="main" class="narrow article">
<p class="crumbs"><a href="{t['home']}">{t['crumbs_home']}</a> › <a href="{t['home']}#guides">{t['crumbs_guides']}</a></p>
<h1>{esc(g['title'])}</h1>
<p class="updated">{t['updated']}</p>
<div class="prose">{g['body']}</div>
<div class="cta"><p>{t['cta']}</p>{download_block(lang)}</div>
<nav class="related" aria-label="{t['related']}"><h2>{t['related']}</h2>{related}</nav>
</main>
"""
    return out + footer(lang)


def write(path, text):
    p = OUT / path.lstrip("/")
    if path.endswith("/"):
        p = p / "index.html"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    for name in ["favicon.png", "icon-256.png", "og.jpg", "version.json"]:
        shutil.copy(DOCS / name, OUT / name)
    shutil.copytree(DOCS / "shots", OUT / "shots")
    shutil.copytree(DOCS / "download", OUT / "download")
    shutil.copy(ROOT / "src/site.css", OUT / "site.css")
    shutil.copy(ROOT / "src/site.js", OUT / "site.js")

    urls = []
    for lang in ("zh", "en"):
        write(T[lang]["home"], render_home(lang))
        urls.append(T[lang]["home"])
        for g in GUIDES[lang]:
            write(g["path"], render_guide(lang, g))
            urls.append(g["path"])

    # sitemap：每个地址带上中英对应版本
    items = []
    for u in urls:
        zh = u if u in PAIRS else PAIRS_REV.get(u)
        en = PAIRS.get(u) if u in PAIRS else u
        alts = (f'<xhtml:link rel="alternate" hreflang="zh-CN" href="{BASE}{zh}"/>'
                f'<xhtml:link rel="alternate" hreflang="en" href="{BASE}{en}"/>'
                f'<xhtml:link rel="alternate" hreflang="x-default" href="{BASE}{en}"/>')
        pri = "1.0" if u in ("/", "/en/") else "0.7"
        items.append(f"<url><loc>{BASE}{u}</loc><lastmod>{UPDATED}</lastmod><priority>{pri}</priority>{alts}</url>")
    (OUT / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
                                     'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + "\n".join(items) + "\n</urlset>\n")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {BASE}/sitemap.xml\n")

    guide_lines = "\n".join(f"- [{g['title']}]({BASE}{g['path']}): {g['desc']}" for lang in ("en", "zh") for g in GUIDES[lang])
    (OUT / "llms.txt").write_text(f"""# Flipic

> Flipic is a free, open-source (MIT) image viewer for macOS 13+. Double-click any photo and page through the whole folder with the arrow keys. {SIZE} download, notarized by Apple, offline by default, no account.

Key facts:
- Paging: ← → through every image in the folder; Space wraps the window to the photo; 0 zooms to 100% at the pointer.
- Star ratings 1–5 written as XMP (embedded for JPEG/HEIC/TIFF, .xmp sidecar for proprietary RAW), readable by Lightroom, Bridge and Capture One.
- Cleanup Mode (Beta): finds similar bursts, exact duplicates, closed eyes and blurry photos on-device.
- Batch convert HEIC/JPEG/PNG, batch rename, lossless rotate, slideshow with adjustable crossfade and click-to-pause.
- Optional HDR display, customizable shortcuts, global show/hide shortcut, ⌘E hand-off to Photoshop/Lightroom/Capture One.
- Formats: JPEG, PNG, HEIC, WebP, GIF, TIFF, AVIF, JPEG XL, camera RAW (Sony, Canon, Nikon, Fujifilm, more).
- Download: {BASE}/download/Flipic.dmg · Source: {GITHUB} · Current version: {VERSION}

## Pages
- [Flipic (English)]({BASE}/en/)
- [Flipic（中文）]({BASE}/)
{guide_lines}
""")

    (OUT / "_headers").write_text("""/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: interest-cohort=()
/shots/*
  Cache-Control: public, max-age=2592000, immutable
/site.css
  Cache-Control: public, max-age=31536000, immutable
/site.js
  Cache-Control: public, max-age=31536000, immutable
/version.json
  Cache-Control: public, max-age=300
  Access-Control-Allow-Origin: *
/download/*
  Cache-Control: public, max-age=300
  Content-Type: application/x-apple-diskimage
""")
    # 旧的 GitHub Pages 路径结构（/macphoto/...）和常用短地址
    (OUT / "_redirects").write_text("""/download /download/Flipic.dmg 302
/dmg /download/Flipic.dmg 302
/macphoto/ / 301
/macphoto/en/ /en/ 301
/macphoto/download/* /download/:splat 301
/zh / 301
/zh/ / 301
""")
    (OUT / "404.html").write_text(head("zh", "/404", "页面不存在 | Flipic", "这个页面不存在。", []).replace(
        '<link rel="canonical" href="https://flipic.app/404">\n', '<meta name="robots" content="noindex">\n')
        + header("zh", "/") + '<main id="main" class="narrow article"><h1>页面不存在</h1><p class="prose">'
        '回到 <a href="/">Flipic 首页</a>，或看看 <a href="/en/">English</a>。</p></main>\n' + footer("zh"))
    print("built", len(urls), "pages ->", OUT)


if __name__ == "__main__":
    main()
