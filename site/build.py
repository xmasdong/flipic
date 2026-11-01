#!/usr/bin/env python3
"""生成 flipic.app 官网：中文在根目录，英文在 /en/。
用法：python3 site/build.py   产出到 site/public，再在 site/ 下 wrangler deploy（Worker 静态资源 + flipic.app 自定义域名）
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
SIZE = "2.5 MB"
# 样式和脚本按内容取版本号：它们缓存一年，内容一变地址就变
import hashlib
# 截图也一样：放进按内容命名的子文件夹，换了图地址就变
SHOTS_V = hashlib.sha1(b"".join(f.read_bytes() for f in sorted((REPO / "docs/shots").iterdir()) if f.is_file())).hexdigest()[:8]
SHOTS = f"/shots/{SHOTS_V}/"
ASSET_V = hashlib.sha1((ROOT / "src/site.css").read_bytes() + (ROOT / "src/site.js").read_bytes()).hexdigest()[:10]
GITHUB = "https://github.com/xmasdong/flipic"


def github_stars():
    """生成时读一次星标数写进页面，不在浏览器里加载 GitHub 的脚本；读不到就只显示按钮"""
    import subprocess
    try:
        out = subprocess.run(["gh", "api", "repos/xmasdong/flipic", "--jq", ".stargazers_count"],
                             capture_output=True, text=True, timeout=20)
        return int(out.stdout.strip())
    except Exception:
        return None


STARS = github_stars()
GITHUB_ICON = ('<svg viewBox="0 0 16 16" aria-hidden="true" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 '
               '5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 '
               '1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 '
               '0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 '
               '3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>')

# 中英页面一一对应，用来写 hreflang 和语言切换
PAIRS = {
    "/": "/en/",
    "/guides/mac-next-image/": "/en/guides/mac-preview-next-image/",
    "/guides/heic-to-jpg-mac/": "/en/guides/batch-convert-heic-to-jpg-mac/",
    "/guides/windows-image-viewer-for-mac/": "/en/guides/irfanview-for-mac/",
    "/guides/cull-event-photos/": "/en/guides/cull-photos-on-mac/",
    "/pro/": "/en/pro/",
}

# Pro 购买：Stripe 付款链接和价格。没填时页面显示「即将开放购买」
PRO_BUY_URL = "https://buy.stripe.com/9B66oI6Rg3uocmU2BAcbC02"
PRO_PRICE = {"zh": "¥68", "en": "$12.99"}
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
<meta name="theme-color" content="#f5f2ea">
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
<link rel="stylesheet" href="/site.css?v={ASSET_V}">
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
    <a href="{'/pro/' if lang == 'zh' else '/en/pro/'}">Pro</a>
    <a class="lang" href="{other}" hreflang="{'en' if lang == 'zh' else 'zh-CN'}">{t['other']}</a>
    {gh_button(lang)}
  </nav>
</header>
"""


def gh_button(lang):
    label = "在 GitHub 上给 Flipic 点星" if lang == "zh" else "Star Flipic on GitHub"
    count = f'<span class="gh-count">{STARS}</span>' if STARS is not None else ""
    return (f'<a class="gh" href="{GITHUB}" aria-label="{label}" rel="noopener">'
            f'<span class="gh-main">{GITHUB_ICON}<span class="gh-text">Star</span></span>{count}</a>')


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
<script src="/site.js?v={ASSET_V}" defer></script>
</body>
</html>
"""


def app_schema(lang, desc):
    return {
        "@context": "https://schema.org", "@type": "SoftwareApplication", "name": "Flipic",
        "operatingSystem": "macOS 13+", "applicationCategory": "MultimediaApplication",
        "softwareVersion": VERSION, "fileSize": SIZE.replace(" ", ""),
        "downloadUrl": f"{BASE}/download/Flipic.dmg", "installUrl": f"{BASE}/download/Flipic.dmg",
        "image": f"{BASE}/og.jpg", "screenshot": f"{BASE}{SHOTS}browse-01.webp",
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
    return f'<img class="shot" src="{SHOTS}{name}" alt="{esc(alt)}" width="{w}" height="{h}" {load}>'


# ---------------------------------------------------------------- 首页内容

HOME = {
    "zh": {
        "title": "Flipic：免费开源的 Mac 看图软件，双击图片用左右键看下一张",
        "desc": "Flipic 是一个免费开源的 Mac 看图软件。双击一张图片，用左右方向键就能看同一个文件夹里的其他图片，也能放大看细节、给照片打星、把 HEIC 批量转成 JPG。安装包 2.5 MB，已通过 Apple 公证。",
        "eyebrow": "免费开源的 Mac 看图软件",
        "h1": "双击一张图片，<br>用方向键往下翻",
        "lede": "Mac 自带的「预览」打开一张图片以后，没法直接看同一个文件夹里的下一张，得回访达全选再打开。Flipic 就是为这个做的：双击任意一张，按 → 就是下一张。另外加了放大看细节、打星、挑片这些看照片时常用的功能。",
        "deck_hint": "这是 Flipic 的实际界面，按键盘上的 <kbd>←</kbd><kbd>→</kbd> 可以翻页",
        "deck_alt": "Flipic 浏览文件夹中的第 {n} 张照片", "prev": "上一张", "next": "下一张",
        "features": [
            ("filmstrip.webp", "Flipic 底部缩略图栏与左右翻页按钮", "看完一张，按方向键看下一张",
             "<p>双击任意一张照片，按 <kbd>→</kbd> 看下一张，<kbd>←</kbd> 回上一张，同一个文件夹里的图片都能翻到。顺序可以按文件名、拍摄时间、修改时间、创建时间或文件大小来排。</p>"
             "<p>按 <kbd>空格</kbd>，窗口会变成照片的比例，竖着拍的照片就是一个竖长的窗口，跟访达里按空格预览差不多。前后几张会提前在后台准备好，4800 万像素的照片按住方向键连着翻也不卡。</p>"),
            ("zoom.webp", "Flipic 在鼠标位置放大到 100% 查看细节", "放大到 100% 看细节",
             "<p>把鼠标移到想看的地方，按 <kbd>0</kbd>，就以那个位置为中心放大到 100%，再按一次回到整张。用触控板捏合或者滚轮缩放时，也是以鼠标所在的位置为中心。</p>"
             "<p>平时只按屏幕需要的尺寸解码，放大到看得出区别时才读原图，所以连着翻几十张大图，内存也占得不多。</p>"),
            ("exif.webp", "Flipic 照片信息面板显示相机、镜头与拍摄参数", "需要时再看拍摄参数",
             "<p>平时界面上只有照片，不显示文件名和参数。按 <kbd>I</kbd> 会在右上角列出相机、镜头、快门、光圈、ISO、拍摄时间和尺寸，按 <kbd>Esc</kbd> 关掉。</p>"
             "<p>iPhone 拍的 HDR 照片可以按 HDR 显示，亮的地方会比普通的白更亮，跟系统「预览」一样。这个要在设置里打开，屏幕也得支持 HDR。</p>"),
            ("cleanup.webp", "Flipic 清理模式：相似连拍分组与推荐保留", "从一大堆照片里先挑出废片",
             "<p>拍完一场活动照片太多的话，可以按 <kbd>⇧⌘K</kbd> 进入清理模式（Beta）。Flipic 在你的 Mac 上检查整个文件夹，把照片分成相似连拍、完全重复、闭眼、模糊四类，每组标出最清楚的那张。</p>"
             "<p>删不删你自己定，点了「移到废纸篓」才会删，删错了按 <kbd>⌘Z</kbd> 撤销。同名的 RAW 和 JPG 会一起处理。</p>"),
            ("settings.webp", "Flipic 设置窗口：快捷键可以自己改", "打星，改快捷键",
             "<p>按 <kbd>1</kbd> 到 <kbd>5</kbd> 给照片打星。星级按 XMP 标准写进文件，Lightroom、Bridge、Capture One 都能读到。JPEG 和 HEIC 只改元数据，不会重新压缩；相机 RAW 的星级写在同名的 .xmp 文件里。</p>"
             "<p>设置窗口（<kbd>⌘,</kbd>）里每个快捷键都能改。还可以设一个全局快捷键，比如在 Photoshop 里按一下就把 Flipic 叫出来，再按一下收起来。</p>"),
        ],
        "more_title": "其他功能",
        "more": [
            ("标记和筛选", "按 P 标记想留的照片，⇧P 只看标记过的，也可以只看几星以上的。挑好以后按 ⇧⌘E 一起导出到别的文件夹。"),
            ("并排对比", "按 C 把两张照片并排放，⇧C 一次看四张，放大和拖动时几张一起动。"),
            ("窗口置顶和分享", "点工具条上的图钉，窗口就一直浮在其他软件上面，适合对照参考图。分享按钮可以用隔空投送、信息、邮件发出去。"),
            ("用后期软件打开", "按 ⌘E 用 Photoshop、Lightroom 或 Capture One 打开当前照片，有同名 RAW 时打开 RAW。"),
            ("幻灯片", "每张停 1 到 10 秒，切换的渐变时长也能调。单击暂停，暂停时可以手动翻页和打星。"),
            ("HEIC 批量转 JPG", "整个文件夹一次转成 JPEG、PNG 或 HEIC，转好的放在子文件夹里，原图不动。"),
            ("旋转", "JPEG 和 HEIC 旋转后只改方向标记，画质没有损失。"),
            ("批量重命名和导出", "可以按序号批量改名。导出时选格式和质量，导出前能看到大概多大。"),
            ("界面语言", "支持 14 种语言，跟随系统设置。"),
        ],
        "vs_title": "和「预览」的区别",
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
            ("Flipic 收费吗？", "看图、评星、标记、筛选、导出、清理这些都免费，没有广告，也不用注册账号，代码以 MIT 协议开源在 GitHub。另有可选的 <a href=\"/pro/\">Pro</a>，一次买断，只加了批量处理和几个专业功能，大多数人用不上。"),
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
        "desc": "A free, open-source image viewer for Mac. Double-click a photo and use the arrow keys to see the other images in the folder. You can also zoom in on details, rate photos and batch convert HEIC to JPG.",
        "eyebrow": "Free, open-source image viewer for Mac",
        "h1": "Double-click a photo,<br>then use the arrow keys",
        "lede": "When you open an image in Preview, you can’t just go on to the next one in the folder; you have to go back to Finder, select them all and open them again. Flipic was made for that: double-click any photo and press → for the next one. It also does the things you usually want while looking through photos, like zooming in, rating and picking keepers.",
        "deck_hint": "This is the real Flipic window. Press <kbd>←</kbd><kbd>→</kbd> on your keyboard to page through",
        "deck_alt": "Flipic showing photo {n} in a folder", "prev": "Previous", "next": "Next",
        "features": [
            ("filmstrip.webp", "Flipic thumbnail strip and navigation arrows", "Go to the next photo with an arrow key",
             "<p>Double-click any photo and press <kbd>→</kbd> for the next one or <kbd>←</kbd> for the previous one, across the whole folder. You can sort by name, date taken, date modified, date created or size.</p>"
             "<p>Press <kbd>Space</kbd> and the window takes the shape of the photo, so a portrait shot gets a tall, narrow window, much like Quick Look in Finder. The next few photos are prepared in the background, so even 48-megapixel images keep up when you hold an arrow key.</p>"),
            ("zoom.webp", "Flipic zooming to 100% at the pointer", "Zoom to 100% to check details",
             "<p>Move the pointer to the spot you want to check and press <kbd>0</kbd> to zoom to 100% around it. Press it again to see the whole photo. Pinching and scroll-wheel zoom also center on the pointer.</p>"
             "<p>Flipic only decodes the size your screen needs and loads the original when you zoom in far enough to see a difference, so memory stays low even after a few dozen large photos.</p>"),
            ("exif.webp", "Flipic photo info panel with camera, lens and exposure", "See shooting details when you need them",
             "<p>Normally the window shows only the photo, with no file name or settings. Press <kbd>I</kbd> to see the camera, lens, shutter speed, aperture, ISO, date taken and size in the corner, and <kbd>Esc</kbd> to close it.</p>"
             "<p>HDR photos from an iPhone can be shown in HDR, with highlights brighter than normal white, the same as in Preview. Turn it on in Settings; your display needs to support HDR.</p>"),
            ("cleanup-en.webp", "Flipic Cleanup Mode grouping similar bursts", "Find the rejects in a big shoot first",
             "<p>When an event leaves you with too many photos, press <kbd>⇧⌘K</kbd> for Cleanup Mode (Beta). Flipic checks the folder on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry shots, marking the sharpest photo in each group.</p>"
             "<p>You decide what goes. Nothing is deleted until you click Move to Trash, and <kbd>⌘Z</kbd> undoes it. RAW and JPG files with the same name are handled together.</p>"),
            ("settings-en.webp", "Flipic Settings window with editable shortcuts", "Ratings and shortcuts",
             "<p>Press <kbd>1</kbd> to <kbd>5</kbd> to rate a photo. Ratings are saved as standard XMP, so Lightroom, Bridge and Capture One can read them. JPEG and HEIC files only get their metadata changed and are not recompressed; ratings for camera RAW go into a .xmp file with the same name.</p>"
             "<p>Every shortcut can be changed in Settings (<kbd>⌘,</kbd>). You can also set a global shortcut, for example to bring Flipic up from Photoshop with one key and hide it again with the same key.</p>"),
        ],
        "more_title": "More features",
        "more": [
            ("Marks and filters", "Press P to mark the photos you want to keep and ⇧P to show only those, or show only photos with a certain rating or higher. Then ⇧⌘E exports them to another folder."),
            ("Side by side", "Press C to put two photos next to each other, or ⇧C to see four. Zooming and dragging move them together."),
            ("Keep on top and share", "Click the pin in the toolbar to keep the window above other apps, handy for a reference image. The share button sends the photo by AirDrop, Messages or Mail."),
            ("Open in your editor", "⌘E opens the current photo in Photoshop, Lightroom or Capture One, or its RAW file if there is one with the same name."),
            ("Slideshow", "Each photo stays 1 to 10 seconds and the crossfade length is adjustable. Click to pause; while paused you can page and rate."),
            ("Batch convert HEIC to JPG", "Convert a whole folder to JPEG, PNG or HEIC. The new files go into a subfolder and the originals are left alone."),
            ("Rotate", "Rotating a JPEG or HEIC only changes its orientation tag, so there is no quality loss."),
            ("Batch rename and export", "Rename by sequence number. When exporting, pick a format and quality and see roughly how big the file will be."),
            ("Languages", "14 interface languages, following your system setting."),
        ],
        "vs_title": "How it differs from Preview",
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
            ("Is Flipic free?", "Viewing, ratings, marks, filtering, export and Cleanup Mode are free, with no ads and no account, and the code is MIT licensed on GitHub. There is an optional <a href=\"/en/pro/\">Pro</a> one-time purchase that only adds batch and pro tools; most people won’t need it."),
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
<p><strong>Flipic</strong>：免费开源，安装包 2.5 MB。双击一张图后用 <kbd>←</kbd> <kbd>→</kbd> 翻完整个文件夹，滚轮默认缩放，按 <kbd>0</kbd> 在鼠标处放大到 100%，这些都照着 Windows 看图软件的手感来做。快捷键都能在设置里改；用 Mos 改过滚轮方向的，可以把缩放方向反过来。</p>
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
<p><strong>Flipic</strong>: free and open source, a 2.5 MB download. Double-click a photo and page with <kbd>←</kbd> <kbd>→</kbd>; the wheel zooms by default; <kbd>0</kbd> zooms to 100% at the pointer. Every shortcut can be remapped, and if you reversed your wheel with Mos you can flip the zoom direction.</p>
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

HOME_PRO = {
    "zh": ("免费版够用吗", "够用。上面说的这些功能都是免费的，以后也会一直免费。如果你经常一次要整理几百上千张照片，可以看看 Pro，里面加了修图前后对比、JPG 和 RAW 合并显示、按星级分文件夹这些批量处理的功能，一次买断。平时看看照片的话用不上，不用买。", "/pro/", "看看 Pro 有什么"),
    "en": ("Is the free version enough?", "Yes. Everything described above is free and will stay free. If you often sort through hundreds or thousands of photos at once, take a look at Pro. It adds batch tools such as before/after comparison, showing JPG and RAW pairs as one photo and sorting into folders by rating, for a one-time price. If you mostly just look at photos, you won’t need it.", "/en/pro/", "See what Pro adds"),
}


def render_home(lang):
    h = HOME[lang]
    t = T[lang]
    path = t["home"]
    schema = [app_schema(lang, h["desc"]), faq_schema(h["faq"]),
              {"@context": "https://schema.org", "@type": "WebSite", "name": "Flipic", "url": f"{BASE}{path}", "inLanguage": t["lang"]}]
    out = head(lang, path, h["title"], h["desc"], schema) + header(lang, path)
    first = f'<img class="on" src="{SHOTS}browse-01.webp" alt="{esc(h["deck_alt"].format(n=1))}" width="1440" height="900" fetchpriority="high">'
    out += f"""<main id="main">
<section class="wrap hero">
  <p class="eyebrow rise">{h['eyebrow']}</p>
  <h1 class="rise">{h['h1']}</h1>
  <p class="lede rise">{h['lede']}</p>
  <div class="rise">{download_block(lang)}</div>
</section>
<section class="wrap stage" aria-label="{'翻页演示' if lang == 'zh' else 'Paging demo'}">
  <div class="frame" id="frame" data-total="8" data-base="{SHOTS}" data-alt="{esc(h['deck_alt'])}">{first}</div>
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
    pro = HOME_PRO[lang]
    out += f'<section class="wrap pro-note"><h2>{pro[0]}</h2><p>{pro[1]}</p><p><a href="{pro[2]}">{pro[3]}</a></p></section>\n'
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


# ---------------------------------------------------------------- Pro 页

PRO = {
    "zh": {
        "path": "/pro/",
        "title": "Flipic Pro：给大量挑片、修图的摄影师准备的批量功能",
        "desc": "Flipic 免费版已经够大多数人用。Pro 只加了批量处理和几个专业功能，一次买断，下载就有 7 天试用。",
        "h1": "Flipic Pro",
        "lede": "先说一句：大多数人用免费版就够了。",
        "honest": [
            "看图、RAW 照片秒开、打星、标记、按星级筛选、导出到文件夹、并排对比、清理相似和模糊的照片，这些都是免费的，代码也开源，以后不会改成要付费。",
            "Pro 是给经常一次处理几百上千张照片的人准备的，加了几个批量处理和修图相关的功能，能省掉一些重复操作。如果你平时只是看看照片、偶尔挑几张，用不到它，不用买。",
            "如果你确实经常整理大量照片，可以先免费试用 7 天，觉得有用再买。卖 Pro 的收入用来继续维护 Flipic，免费版也会一直更新。",
        ],
        "buy": "购买 Pro",
        "price_note": "一次买断，之后的更新都能用。付款后马上拿到激活码，离线激活，不用注册账号。",
        "trial": "下载 Flipic 就带 7 天试用，到期后免费功能照常可用。",
        "skip_title": "这些情况用不到 Pro",
        "skip": ["只是想双击图片，用方向键看完一个文件夹", "偶尔给照片打星、标记几张，再导出到一个文件夹", "清理手机里导出来的重复、模糊照片"],
        "features_title": "Pro 多了哪些功能",
        "features": [
            ("修图前后对比", "原片和修过的那张叠在一起，按住 \\ 看修图前，松开看修图后。也可以拖一条分割线左右对照，或者调修图后那张的透明度。Flipic 会按文件名找到对应的两张，比如 IMG_1234.RAF 和 IMG_1234-编辑.jpg，或者导出文件夹里同名的那张。"),
            ("JPG 和 RAW 合并显示", "相机同时存 JPG 和 RAW 的话，同名的两个文件只显示成一张，张数不会翻倍，按 V 切换看哪一张。打星、标记、导出、删除都当成一张处理。"),
            ("按星级分到子文件夹", "打完星以后，可以把整个文件夹的照片按星级复制或移动到「5 星」「4 星」这样的子文件夹里。"),
            ("常用文件夹", "最多设 9 个常用文件夹，看图时按 ⌥1 到 ⌥9 就把当前照片复制或移动过去。"),
            ("删除没挑中的照片", "标记或打星挑完以后，可以把其余的照片一次移到废纸篓，删错了能马上放回来。"),
            ("一次在后期软件里打开多张", "把筛出来的照片一次在 Lightroom、Photoshop 或 Capture One 里打开，有 RAW 的打开 RAW。"),
            ("自定义同名文件", "复制、移动、删除照片时，同名的 xmp、dop、pp3 这类附属文件，或者 JPG 和 RAW，可以设置成跟着一起处理。"),
        ],
        "free_title": "免费和 Pro",
        "free_head": ("功能", "免费", "Pro"),
        "free_rows": [("看图、RAW 秒开、HDR、幻灯片", "有", "有"), ("评星、标记、按星级筛选", "有", "有"),
                      ("导出到文件夹、并排对比、清理模式", "有", "有"), ("批量转格式、批量重命名", "有", "有"),
                      ("修图前后对比", "", "有"), ("JPG 和 RAW 合并显示", "", "有"), ("按星级分到子文件夹", "", "有"),
                      ("常用文件夹 ⌥1–⌥9", "", "有"), ("删除没挑中的照片", "", "有"), ("批量送进后期软件", "", "有"),
                      ("自定义同名关联", "", "有")],
        "faq": [
            ("激活码怎么用？", "付款成功的页面上有激活码和「在 Flipic 中激活」按钮，点一下就激活了。也可以复制激活码，粘贴到 Flipic「设置 › Pro」里。"),
            ("要联网验证吗？", "不用。激活码在 Mac 上离线验证，Flipic 照样默认不联网。"),
            ("能装在几台 Mac 上？", "你自己的 Mac 都可以用同一个激活码。"),
            ("激活码丢了怎么办？", "在 <a href=\"https://pay.flipic.app/recover?lang=zh\">找回激活码</a> 页面输入付款邮箱和卡号后四位就能找回。"),
            ("Flipic 还是开源的吗？", "是。看图和挑片的核心功能继续开源（MIT），Pro 功能的代码不在公开仓库里。"),
        ],
    },
    "en": {
        "path": "/en/pro/",
        "title": "Flipic Pro: batch tools for photographers who cull and edit a lot",
        "desc": "The free Flipic is enough for most people. Pro adds batch and pro tools only. One-time purchase, 7-day trial in every download.",
        "h1": "Flipic Pro",
        "lede": "First, most people will be fine with the free version.",
        "honest": [
            "Viewing, quick RAW previews, ratings, marks, filtering by rating, export to a folder, side-by-side comparison and cleaning up similar or blurry photos are all free, the code is open source, and none of it will become paid.",
            "Pro is for people who often go through hundreds or thousands of photos at a time. It adds a few batch and editing-related tools that save some repetitive work. If you mostly look at photos and pick a few now and then, you won’t use it, so there’s no need to buy it.",
            "If you do sort through a lot of photos, try it free for 7 days and buy it only if it helps. Pro sales pay for keeping Flipic going, and the free version keeps getting updates too.",
        ],
        "buy": "Buy Pro",
        "price_note": "One-time purchase with future updates included. You get your key right after paying. Offline activation, no account.",
        "trial": "Every download includes a 7-day trial; after it ends, the free features keep working.",
        "skip_title": "You won’t need Pro if you",
        "skip": ["just want to double-click a photo and page through the folder", "rate or mark a few photos now and then and export them to a folder", "clean up duplicate or blurry photos from your phone"],
        "features_title": "What Pro adds",
        "features": [
            ("Before & after", "The original and the edited version sit on top of each other. Hold \\ to see the original and let go to see the edit. You can also drag a split line to compare side by side, or change the edit’s opacity. Flipic finds the pair by file name, such as IMG_1234.RAF and IMG_1234-Edit.jpg, or a file with the same name in an export folder."),
            ("Show JPG and RAW as one photo", "If your camera saves both JPG and RAW, each pair shows up as one photo, so the count doesn’t double. Press V to switch between them. Rating, marking, exporting and deleting treat the pair as one."),
            ("Sort into folders by rating", "After rating, copy or move the photos in a folder into subfolders like “5 stars” and “4 stars”."),
            ("Favorite folders", "Set up to nine folders, then press ⌥1 to ⌥9 while viewing to copy or move the current photo there."),
            ("Delete the photos you didn’t pick", "After marking or rating, move all the others to the Trash at once, and put them back right away if you made a mistake."),
            ("Open several photos in your editor", "Open the photos you filtered in Lightroom, Photoshop or Capture One at once, using the RAW file when there is one."),
            ("Same-name files", "Choose which files with the same name go along when you copy, move or delete a photo, such as xmp, dop and pp3 sidecars, or JPG and RAW."),
        ],
        "free_title": "Free and Pro",
        "free_head": ("Feature", "Free", "Pro"),
        "free_rows": [("Viewing, instant RAW, HDR, slideshow", "Yes", "Yes"), ("Ratings, marks, filter by rating", "Yes", "Yes"),
                      ("Export to folder, side-by-side, Cleanup Mode", "Yes", "Yes"), ("Batch convert, batch rename", "Yes", "Yes"),
                      ("Before & after", "", "Yes"), ("Merge JPG and RAW", "", "Yes"), ("Sort into folders by rating", "", "Yes"),
                      ("Favorite folders ⌥1–⌥9", "", "Yes"), ("Delete what you didn’t pick", "", "Yes"), ("Send a batch to your editor", "", "Yes"),
                      ("Custom linked files", "", "Yes")],
        "faq": [
            ("How do I activate?", "The payment confirmation page shows your key and an Activate in Flipic button. Or copy the key and paste it into Flipic › Settings › Pro."),
            ("Does it need to go online?", "No. The key is verified offline on your Mac, and Flipic stays offline by default."),
            ("How many Macs?", "Use the same key on all of your own Macs."),
            ("I lost my key", "Use <a href=\"https://pay.flipic.app/recover?lang=en\">Recover Key</a> with your payment email and the last four digits of your card."),
            ("Is Flipic still open source?", "Yes. The core viewer and culling features stay open source (MIT). Pro code isn’t in the public repository."),
        ],
    },
}


def render_pro(lang):
    t = T[lang]
    p = PRO[lang]
    path = p["path"]
    schema = [faq_schema(p["faq"])]
    out = head(lang, path, p["title"], p["desc"], schema) + header(lang, path)
    price = PRO_PRICE[lang]
    buy = (f'<div class="get"><a class="btn" href="{PRO_BUY_URL}">{p["buy"]}{" · " + esc(price) if price else ""}</a></div>'
           f'<p class="alt">{p["price_note"]}</p>')
    honest = "".join(f"<p>{esc(x)}</p>" for x in p["honest"])
    skip = "".join(f"<li>{esc(x)}</li>" for x in p["skip"])
    feats = "".join(f"<section><h3>{esc(h)}</h3><p>{esc(b)}</p></section>" for h, b in p["features"])
    hd = p["free_head"]
    rows = "".join(f'<tr><td>{esc(a)}</td><td>{esc(b)}</td><td class="yes">{esc(c)}</td></tr>' for a, b, c in p["free_rows"])
    faqs = "".join(f"<details><summary>{esc(q)}</summary><p>{a}</p></details>" for q, a in p["faq"])
    out += f"""<main id="main" class="narrow article">
<h1>{p['h1']}</h1>
<p class="lede">{p['lede']}</p>
<div class="prose">{honest}</div>
<h2 class="pro-h">{p['skip_title']}</h2>
<ul class="prose">{skip}</ul>
{download_block(lang)}
<h2 class="pro-h">{p['features_title']}</h2>
<div class="prose">{feats}</div>
<h2 class="pro-h">{p['free_title']}</h2>
<table><thead><tr><th>{hd[0]}</th><th>{hd[1]}</th><th>{hd[2]}</th></tr></thead><tbody>{rows}</tbody></table>
<div class="pro-buy">{buy}<p>{p['trial']}</p></div>
<section class="faq"><h2>{t['faq']}</h2>{faqs}</section>
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
    shutil.copytree(DOCS / "shots", OUT / "shots" / SHOTS_V)
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
        write(PRO[lang]["path"], render_pro(lang))
        urls.append(PRO[lang]["path"])

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
