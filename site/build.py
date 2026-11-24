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
UPDATED = "2026-11-24"
# 水印功能 1.0.43 发布后改成 True；False 时站点里不出现任何水印文字和图片
SHOW_WATERMARK = True
# Windows 版候补名单：首页的留邮箱区块、首屏的「用 Windows？」链接、隐私政策里的说明。False 时三处都不生成（Worker 的 /api/waitlist 不受影响）
SHOW_WINDOWS_WAITLIST = True
VERSION = json.loads((DOCS / "version.json").read_text())["version"]
SIZE = "8.9 MB"
# 样式和脚本按内容取版本号：它们缓存一年，内容一变地址就变
import hashlib
# 截图也一样：放进按内容命名的子文件夹，换了图地址就变
SHOTS_V = hashlib.sha1(b"".join(f.read_bytes() for f in sorted((REPO / "docs/shots").iterdir()) if f.is_file() and (SHOW_WATERMARK or not f.name.startswith("wm-")))).hexdigest()[:8]
SHOTS = f"/shots/{SHOTS_V}/"
ASSET_V = hashlib.sha1((ROOT / "src/site.css").read_bytes() + (ROOT / "src/site.js").read_bytes()).hexdigest()[:10]
GITHUB = "https://github.com/xmasdong/flipic"
# IndexNow：发布后把网址推给 Bing / Yandex 等，密钥本来就是公开放在网站上的
INDEXNOW_KEY = "b3c572183d825917ef4d3b1eae8c1035"


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
    "/guides/mac-image-viewer-recommend/": "/en/guides/open-source-image-viewers-mac/",
    "/guides/adobe-bridge-mac/": "/en/guides/adobe-bridge-alternative-mac/",
    "/guides/photo-mechanic-mac/": "/en/guides/photo-mechanic-alternative-mac/",
    "/guides/xnview-mp-mac/": "/en/guides/xnview-mp-alternative-mac/",
    "/guides/fastrawviewer-mac/": "/en/guides/fastrawviewer-alternative-mac/",
    "/compare/": "/en/compare/",
    "/guides/read-iptc-caption-mac/": "/en/guides/read-iptc-caption-mac/",
    "/guides/mac-view-raw/": "/en/guides/view-raw-files-mac/",
    "/guides/external-drive-slow-photos-mac/": "/en/guides/fast-photo-viewer-external-hard-drive-mac/",
    "/guides/mac-photo-viewer-benchmark/": "/en/guides/mac-photo-viewer-benchmark/",
    "/guides/exif-photo-frame-mac/": "/en/guides/exif-photo-frame-mac/",
    "/guides/check-focus-histogram-zebra-mac/": "/en/guides/check-focus-histogram-zebra-mac/",
    "/guides/match-client-photo-list-mac/": "/en/guides/match-client-photo-list-mac/",
    "/guides/exif-batch-rename-photos-mac/": "/en/guides/exif-batch-rename-photos-mac/",
    "/guides/cube-lut-preview-photos-mac/": "/en/guides/cube-lut-preview-photos-mac/",
    "/guides/fix-wrong-image-extension-mac/": "/en/guides/fix-wrong-image-extension-mac/",
    "/changelog/": "/en/changelog/",
}

# Pro 购买：Stripe 付款链接和价格。没填时页面显示「即将开放购买」
# Mac App Store 上的 Flipic Lens（改名前的名字在 private.json 的 store_app_name）。中国大陆区没有上架
APP_STORE_URL = "https://apps.apple.com/app/id6829623097"
APP_STORE_REVIEW_URL = APP_STORE_URL + "?action=write-review"
PRO_BUY_URL = "https://buy.stripe.com/9B66oI6Rg3uocmU2BAcbC02"
PRO_PRICE = {"zh": "¥68", "en": "$12.99"}
PRO_VALUE = {"zh": (68, "CNY"), "en": (12.99, "USD")}   # GA4 begin_checkout 的金额
# GA4（媒体资源 flipic.app）。欧洲经济区、英国、瑞士默认不写统计 cookie（Consent Mode 无 cookie 请求），其他地区照常统计；
# 广告相关一律关闭。埋点在 src/site.js，付款成功页的 purchase 在 pay.flipic.app 的 worker 里
GA_ID = "G-YBHEXX64G3"
GA_EEA = ["AT","BE","BG","HR","CY","CZ","DK","EE","FI","FR","DE","GR","HU","IE","IT","LV","LT","LU","MT","NL","PL","PT","RO","SK","SI","ES","SE","IS","LI","NO","GB","CH"]
# 隐私政策和用户协议里要写明的三项，由用户填写；有一项没填，这两页就不生成，页脚也不放链接
LEGAL = {
    "operator": {"zh": "Flipic Lens 团队", "en": "Flipic Lens Team"},   # 运营主体
    "email": "support@flipic.app",      # 联系邮箱，Cloudflare Email Routing 转发
    "refund_days": 14,                  # 官网购买 Pro 后几天内可以退款
    "effective": "2026-11-18",   # 生效日期；隐私政策新增候补名单一节时改成当天
}
# Mac App Store 版的名字只放在本机的 site/private.json（不进公开仓库）；没有时页面写「Mac App Store 版」
_private = ROOT / "private.json"
STORE_NAME = json.loads(_private.read_text()).get("store_app_name", "") if _private.exists() else ""
LEGAL_READY = bool(LEGAL["operator"]["zh"] and LEGAL["operator"]["en"] and LEGAL["email"] and LEGAL["refund_days"])
if LEGAL_READY:
    PAIRS.update({"/privacy/": "/en/privacy/", "/terms/": "/en/terms/"})
PAIRS_REV = {v: k for k, v in PAIRS.items()}

DOWNLOAD_ICON = ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
                 'stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/></svg>')

T = {
    "zh": {
        "lang": "zh-CN", "home": "/", "features": "功能", "guides": "指南", "faq": "常见问题",
        "other": "English", "download": "免费下载 Mac 版", "github_alt": "也可以从 <a href=\"{gh}/releases/latest\">GitHub</a> 下载，或者到 <a href=\"{store}\">Mac App Store</a>（中国大陆区暂未上架；已从商店下载欢迎<a href=\"{review}\">留一条评价</a>）",
        "facts": ["免费开源", f"安装包约 {SIZE}", "macOS 13 或更新", "Apple 芯片与 Intel 通用", "已通过 Apple 公证", "不用账号"],
        "phone": "Flipic Lens 是 Mac 软件，手机上装不了。复制网址，到 Mac 的浏览器里打开就能下载。",
        "phone_btn": "复制网址 flipic.app", "phone_done": "已复制，到 Mac 上粘贴打开",
        "crumbs_home": "Flipic Lens", "crumbs_guides": "指南", "updated": "更新于 " + UPDATED,
        "cta": "Flipic Lens 是一款免费开源的 Mac 看图软件，双击一张图，左右键就能翻完整个文件夹。",
        "related": "相关指南",
        "footer_credit": "截图中的照片来自 Wikimedia Commons，均为 CC0：圣托里尼 Aidan Meyer、Anthony Delanoix，布莱德湖 Aleš Krivec，哈尔施塔特 Fineas Anton、Martin Horák，冰岛 Alexandre Godreau，优胜美地 John Salzarulo，阳朔 Manon Boyer。",
        "footer_line": "Flipic Lens {v} · MIT 开源 · 原名 PixDeck",
        "src": "源代码", "feedback": "反馈问题", "releases": "更新记录",
        "privacy": "隐私政策", "terms": "用户协议",
    },
    "en": {
        "lang": "en", "home": "/en/", "features": "Features", "guides": "Guides", "faq": "FAQ",
        "other": "中文", "download": "Download for Mac, free", "github_alt": "or get it from <a href=\"{gh}/releases/latest\">GitHub</a> or the <a href=\"{store}\">Mac App Store</a> (installed from there? <a href=\"{review}\">leave a rating</a>)",
        "facts": ["Free and open source", f"About {SIZE} download", "macOS 13 or later", "Apple silicon and Intel", "Notarized by Apple", "No account needed"],
        "phone": "Flipic Lens is a Mac app and can't be installed on a phone. Copy the address and open it in a browser on your Mac.",
        "phone_btn": "Copy flipic.app", "phone_done": "Copied. Paste it on your Mac.",
        "crumbs_home": "Flipic Lens", "crumbs_guides": "Guides", "updated": "Updated " + UPDATED,
        "cta": "Flipic Lens is a free, open-source image viewer for Mac: double-click one photo and page through the whole folder with the arrow keys.",
        "related": "More guides",
        "footer_credit": "Photos in the screenshots are from Wikimedia Commons, all CC0: Santorini by Aidan Meyer and Anthony Delanoix, Lake Bled by Aleš Krivec, Hallstatt by Fineas Anton and Martin Horák, Iceland by Alexandre Godreau, Yosemite by John Salzarulo, Yangshuo by Manon Boyer.",
        "footer_line": "Flipic Lens {v} · MIT licensed · formerly PixDeck",
        "src": "Source code", "feedback": "Feedback", "releases": "Release notes",
        "privacy": "Privacy", "terms": "Terms",
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
<meta property="og:site_name" content="Flipic Lens for Mac">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:image" content="{BASE}/og.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:url" content="{BASE}{path}">
<meta property="og:locale" content="{'zh_CN' if lang == 'zh' else 'en_US'}">
<meta name="twitter:card" content="summary_large_image">
<link rel="stylesheet" href="/site.css?v={ASSET_V}">
<script async src="https://www.googletagmanager.com/gtag/js?id={GA_ID}"></script>
<script>window.dataLayer=window.dataLayer||[];function gtag(){{dataLayer.push(arguments);}}
gtag('consent','default',{{ad_storage:'denied',ad_user_data:'denied',ad_personalization:'denied',analytics_storage:'denied',region:{json.dumps(GA_EEA)}}});
gtag('consent','default',{{ad_storage:'denied',ad_user_data:'denied',ad_personalization:'denied',analytics_storage:'granted'}});
gtag('js',new Date());gtag('config','{GA_ID}',{{site_lang:'{lang}'}});</script>
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
  <a class="brand" href="{home}"><img src="/icon-256.png" alt="" width="30" height="30">Flipic Lens</a>
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
    label = "在 GitHub 上给 Flipic Lens 点星" if lang == "zh" else "Star Flipic Lens on GitHub"
    count = f'<span class="gh-count">{STARS}</span>' if STARS is not None else ""
    return (f'<a class="gh" href="{GITHUB}" aria-label="{label}" rel="noopener">'
            f'<span class="gh-main">{GITHUB_ICON}<span class="gh-text">Star</span></span>{count}</a>')


def download_block(lang, big=True, brew=False, win=False):
    t = T[lang]
    brew_line = (f'\n<p class="brew">{"或者用 Homebrew 装：" if lang == "zh" else "Or with Homebrew: "}'
                 '<code>brew install xmasdong/flipic/flipic-lens</code></p>') if brew else ""
    facts = "".join(f"<li>{f}</li>" for f in t["facts"])
    win_link = f'\n  <a class="alt win-link" href="#windows">{WAITLIST[lang]["link"]}</a>' if win else ""
    return f"""<div class="get">
  <a class="btn" href="/download/Flipic.dmg" download>{DOWNLOAD_ICON}{t['download']}</a>
  <span class="alt">{t['github_alt'].format(gh=GITHUB, store=APP_STORE_URL, review=APP_STORE_REVIEW_URL)}</span>{win_link}
</div>
<ul class="facts">{facts}</ul>{brew_line}
<div class="on-phone"><p>{t['phone']}</p><button class="copy" type="button" data-url="https://flipic.app" data-done="{t['phone_done']}">{t['phone_btn']}</button></div>"""


def legal_links(lang):
    if not LEGAL_READY:
        return ""
    t = T[lang]
    pre = "" if lang == "zh" else "/en"
    return f' · <a href="{pre}/privacy/">{t["privacy"]}</a> · <a href="{pre}/terms/">{t["terms"]}</a>'


def footer(lang):
    t = T[lang]
    links = [(g["path"], g["short"]) for g in GUIDES[lang]]
    nav = "".join(f'<a href="{p}">{esc(n)}</a>' for p, n in links)
    changelog_path = "/changelog/" if lang == "zh" else "/en/changelog/"
    return f"""<footer class="wrap">
  <nav>{nav}</nav>
  <p>{t['footer_line'].format(v=VERSION)} · <a href="{GITHUB}">{t['src']}</a> · <a href="{GITHUB}/issues">{t['feedback']}</a> · <a href="{changelog_path}">{t['releases']}</a>{legal_links(lang)}</p>
  <p>{t['footer_credit']}</p>
</footer>
<script src="/site.js?v={ASSET_V}" defer></script>
</body>
</html>
"""


def app_schema(lang, desc):
    features = (
        [
            "不导入建库，方向键翻看整个文件夹照片与相机 RAW",
            "按住 0 鼠标处 100% 放大看对焦；C / ⇧C 两张或四张同步对比",
            "1–5 星评分与颜色标签写标准 XMP（Lightroom / Capture One 互通）",
            "H 直方图、J 过曝/死黑警示、K 焦点峰值、A 相机对焦框",
            "清理模式：本机识别相似连拍、重复、闭眼与模糊照片",
            "外接硬盘本机 SSD 预览缓存（500 MB LRU）与 RAW 4 MB 前缀快扫",
            "EXIF 参数相框、EXIF 模板批量重命名、批量转格式、加水印与导出脱敏",
            "可选 Pro：工作台宫格、放大到眼睛、按客户文件名清单挑图、自定义 .cube 3D LUT",
        ] if lang == "zh" else [
            "Catalog-free folder browsing for photos and camera RAW with arrow keys",
            "Hold 0 for 100% zoom at pointer; C / Shift-C synced 2-up and 4-up comparison",
            "1–5 star ratings and color labels written as standard XMP (Lightroom & Capture One compatible)",
            "Single-viewer H histogram, J highlight/shadow clipping, K focus peaking, A camera AF point",
            "On-device Cleanup Mode for bursts, duplicates, closed eyes and blur",
            "External drive local SSD preview cache (500 MB LRU) and 4 MB RAW embedded-preview scan",
            "EXIF photo frame, EXIF template batch rename, batch convert, export watermarks and serial stripping",
            "Optional Pro: Workbench project grid, zoom to eyes, match from client filename list, custom .cube 3D LUTs",
        ]
    )
    return {
        "@context": "https://schema.org", "@type": "SoftwareApplication", "name": "Flipic Lens",
        # 「Flipic Lens」这个词常被当成拼错的 flip icon / flipaclip，写全称帮搜索引擎认出是哪个软件
        "alternateName": ["Flipic", "PixDeck", "Flipic for Mac", "Flipic Lens for Mac", "Flipic Image Viewer", "Flipic Lens Image Viewer", "Flipic 看图", "Flipic Lens 看图"],
        "sameAs": [GITHUB, f"{GITHUB}/releases"],
        "operatingSystem": "macOS 13+", "applicationCategory": "MultimediaApplication",
        "softwareVersion": VERSION, "fileSize": SIZE.replace(" ", ""),
        "releaseNotes": f"{BASE}{'/changelog/' if lang == 'zh' else '/en/changelog/'}",
        "featureList": features,
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
        {"@type": "ListItem", "position": 1, "name": "Flipic Lens", "item": f"{BASE}{t['home']}"},
        {"@type": "ListItem", "position": 2, "name": t["crumbs_guides"], "item": f"{BASE}{t['home']}#guides"},
        {"@type": "ListItem", "position": 3, "name": title, "item": f"{BASE}{path}"}]}


def shot(name, alt, w=1440, h=900, eager=False):
    load = 'fetchpriority="high"' if eager else 'loading="lazy" decoding="async"'
    return f'<img class="shot" src="{SHOTS}{name}" alt="{esc(alt)}" width="{w}" height="{h}" {load}>'


# ---------------------------------------------------------------- 首页内容

HOME = {
    "zh": {
        "title": "Flipic Lens：免费 Mac 看图软件，摄影师挑片用",
        "desc": "Flipic Lens 是给摄影师挑片用的免费 Mac 看图软件。导完卡，双击一张照片，用方向键翻完整个文件夹，按住 0 在鼠标处放大到 100% 看焦点，按 1–5 打星、P 标记要留的，星级 Lightroom 和 Capture One 都能读。支持主流相机 RAW，免费开源。",
        "eyebrow": "给摄影师挑片用的 Mac 看图软件",
        "h1": "导完卡，<br>用方向键挑一遍",
        "lede": "拍完一组想先挑一挑，Mac 自带的「预览」只能在一起打开的那几张里翻，开 Lightroom 又得先导入。我自己嫌麻烦，就做了 Flipic Lens：双击文件夹里随便一张，左右键往下翻，看中的打个星，回到 Lightroom 里星还在。现在用它的基本都是摄影师。",
        "deck_hint": "这是 Flipic Lens 的实际界面，按键盘上的 <kbd>←</kbd><kbd>→</kbd> 可以翻页",
        "deck_alt": "Flipic Lens 浏览文件夹中的第 {n} 张照片", "prev": "上一张", "next": "下一张",
        "features": [
            ("filmstrip.webp", "Flipic Lens 底部缩略图栏与左右翻页按钮", "翻片不用先导入",
             "<p>双击文件夹里任意一张，<kbd>→</kbd> 下一张，<kbd>←</kbd> 上一张，整个文件夹都能翻到。右上角点 <kbd>⇅</kbd>（或右键菜单「排序方式」）随时切换跟随访达、文件名、拍摄时间、添加时间、大小或标星，不用进设置；鼠标移到底部缩略图栏直接滚轮就能翻片。</p>"
             "<p>后面几张会先在后台准备好，4800 万像素的照片按住方向键一直翻也跟得上。外接机械硬盘和 ExFAT 存储卡的预览会自动缓存到 Mac 内置 SSD，再次打开或重插硬盘翻图接近本地速度。按一下 <kbd>空格</kbd>，窗口会贴合照片比例。</p>"),
            ("zoom.webp", "Flipic Lens 在鼠标位置放大到 100% 查看对焦", "看清楚焦点对没对上",
             "<p>鼠标移到眼睛上按住 <kbd>0</kbd>，就以那儿为中心放大到 100%，对没对上一下就看出来了，松手回到整张。用触控板捏合或者滚轮缩放，也是围着鼠标的位置放大。</p>"
             "<p>连拍里拿不准留哪张的话，按 <kbd>C</kbd> 把两张并排放（<kbd>⇧C</kbd> 四张），放大、拖动的时候一起动，方便对着同一个地方比。</p>"),
            ("inspect-suite.webp", "Flipic Lens 单图摄影质检：左下角实时 RGB 直方图、画面红斜纹过曝警示、青绿焦点峰值、绿色相机对焦框，以及顶部工作台入口与快捷排序按钮", "直方图、过曝、峰值、对焦框，单图直接看",
             "<p>看图时不用切去后期软件就能做完技术质检：按 <kbd>H</kbd> 开实时 RGB 与亮度直方图（底部标出死黑与过曝占比），按 <kbd>J</kbd> 开过曝红斜纹与暗部蓝斜纹警示，按 <kbd>K</kbd> 开青绿焦点峰值，按 <kbd>A</kbd> 叠加相机原始对焦框。</p>"
             "<p>支持 EXIF SubjectArea、XMP MWG-RS 以及索尼、富士机身 MakerNotes 对焦区域，旋转 90° 后叠加层自动跟着对齐。这四项摄影质检全部免费。</p>"),
            ("settings.webp", "Flipic Lens 设置窗口：快捷键可以自己改", "打的星 Lightroom 也认",
             "<p><kbd>1</kbd> 到 <kbd>5</kbd> 打星，再按一次同样的数字取消，<kbd>6</kbd> 到 <kbd>9</kbd> 打红黄绿蓝颜色标签，<kbd>P</kbd> 标记要留的。星级和颜色标签都按标准 XMP（含 <code>xmp:Label</code>）保存，Lightroom、Bridge、Capture One 全部读得到；JPEG 和 HEIC 只改元数据不重新压缩，RAW 写在旁边同名 .xmp 文件里。</p>"
             "<p>挑完按 <kbd>⇧P</kbd> 只看标记过的，或者只看几星以上的，再按 <kbd>⇧⌘E</kbd> 一起拷到别的文件夹。快捷键用不惯的话，设置里每个都能改。</p>"),
            ("cleanup.webp", "Flipic Lens 清理模式：相似连拍分组与推荐保留", "让它先把废片找出来",
             "<p>一场活动拍下来几百张，可以按 <kbd>⇧⌘K</kbd> 打开清理模式。它在你自己的 Mac 上把整个文件夹过一遍，相似的连拍、一模一样的文件、闭眼的、糊的分别归到一起，每组里标出最清楚的那张。</p>"
             "<p>删哪些还是你说了算，点了「移到废纸篓」才会删，删错了 <kbd>⌘Z</kbd> 能撤回来。同名的 RAW 和 JPG 会一起处理。</p>"),
            ("exif.webp", "Flipic Lens 照片信息面板显示相机、镜头与拍摄参数", "参数按 I 才出来",
             "<p>平时画面上只有照片，想看参数就按 <kbd>I</kbd>，窗口右边会列出相机、镜头、快门、光圈、ISO、拍摄时间、IPTC 标题图说与色域，照片自动让到左边，不会被挡住，看完按 <kbd>Esc</kbd> 关掉。</p>"
             "<p>带位置的照片下面有一块小地图，点「显示地图」才联网加载。在国内拍的照片会自动换算国内地图坐标，红点落在实际拍摄位置，不会偏几百米。iPhone 拍的 HDR 照片也能按 HDR 显示，跟系统「预览」看到的一样。</p>"),
            ("exif-frame.webp", "Flipic Lens EXIF 参数相框：圣托里尼照片配上白色留白边框，底边自动排版 SONY ILCE-7M4、FE 35mm F1.4 GM 与 35mm ƒ/8 1/2000s ISO 100 拍摄参数", "带拍摄参数的相框，一键加好",
             "<p>发小红书、朋友圈或者做作品集想留白并标出机身镜头，按 <kbd>⇧B</kbd> 打开加边框，勾选「拍摄参数」就会在底边自动排版相机型号、镜头、焦距、光圈、快门、ISO 和拍摄日期。</p>"
             "<p>支持原比例等宽、4:5、1:1、16:9 等常见社媒比例，以及白、黑、模糊背景和自定义底色，深浅底色自动切换字色。单张另存、⌘S 导出、批量转换格式和 Pro 导出预设都能直接套用，全部免费。</p>"),
        ],
        "film_feature": ("film.webp", "Flipic Lens 胶片滤镜面板：十款效果的缩略图和强度、颗粒、光晕滑块", "给照片套上胶片的颜色",
             "<p>按 <kbd>⇧F</kbd> 打开胶片滤镜面板，每一格都是当前这张照片套上这一款的样子，点一下就换。一共十款：偏暖的人像、日常的暖色、浓一点的反转片色、清冷的薄荷、细腻鲜艳的、夜景用的电影色、灰调的纪实，再加三款黑白。</p>"
             "<p>下面三个滑块调强度、颗粒和光晕。翻到下一张，效果还在，可以一路翻下去，看整组照片套上以后什么样。按住 <kbd>\\</kbd> 看原图，<kbd>G</kbd> 开关，<kbd>,</kbd> 和 <kbd>.</kbd> 换上一款、下一款。</p>"
             "<p>这只改看到的画面，原图不会动。想留下来就点「另存一份…」，拍摄信息、说明和位置都带着。⌘S 导出、批量转换格式和导出预设里也能选胶片，整批一起套。视频、动图和 HDR 照片不套用。</p>"
             "<p>「暖调人像」和「经典黑白」免费，其余八款与导入自定义 .cube 3D LUT 是 Pro 功能，试用期内都能用。</p>"),
        "wm_feature": ("wm-editor.webp", "Flipic Lens 导出水印编辑窗口：平铺的文字水印预览在一张示意证件上", "导出的副本加水印",
             "<p>拿照片去办事、发样片给客户或者署个名，可以给导出的副本加水印。文字或者你自己的图片（比如 logo）都行，可以斜着平铺满整张，也可以放在九个位置里的某一处。大小、透明度、颜色和角度都能调。</p>"
             "<p>自带三个起点：证件用途、样片、署名，改几个字就能用。文字里支持 <code>{index}</code> 自动序号，发样片选图时方便客户按编号回复；每次导出时还能单独填一行字，只对这一次导出有效，存好的水印不变。</p>"
             "<p>⌘S 导出、批量转换格式和导出预设（Pro）里都能选，也可以从「文件 › 加水印导出…」直接进。原照片不会被改，视频和动图会跳过。水印能让别人不方便直接拿去用，但拦不住有心人，重要的东西别只靠它。</p>"),
        "more_title": "其他功能",
        "more": [
            ("看图与工作台快捷排序（⇅）+ 缩略图滚轮翻片", "看图页右上角（及右键菜单）和工作台 5 种视图顶栏都有 ⇅ 排序按钮，随时切换跟随访达、文件名、拍摄时间、添加时间、大小或标星。鼠标移到底部胶片缩略图栏时，上下滚轮直接切上一张/下一张（鼠标侧键也支持翻页），宫格里按住 ⌥ + 滚轮也能直接翻图。"),
            ("检测并一键修复错误的图片后缀（免费）", "豆包、即梦或网页保存的 PNG / WebP 常被写成 .jpg，导致 Mac 访达不显示缩略图、Photoshop 报错。Flipic Lens 打开即在顶部与照片信息栏提示真实格式，支持单张无损修正，也可通过「工具 › 修复错误的图片后缀…」一键扫描整文件夹，无损改后缀或转为标准 JPEG（透明底自动铺白），同步改名 .xmp / .MOV。"),
            ("ExFAT 与外接机械硬盘深度冷读取加速", "针对外接机械硬盘、ExFAT 存储卡与网络盘：POSIX 顺序大块读盘、按卷优先级单通道顺序调度、RAW 前 4 MB 内嵌预览优先、跳过无效扩展属性寻道，并把预览与缩略图缓存到 Mac 内置 SSD（上限 500 MB，最久未访问自动清理，可在「设置 › 看图」开关或清空）。"),
            ("拍摄地点地图，国内照片不偏移", "按 I 打开照片信息，带位置的照片能看到拍在哪。国内拍的照片会先把 GPS 坐标换算成国内地图用的坐标，不会偏几百米；香港、澳门、台湾和国外的照片不用换算。地图点了才加载。"),
            ("一次看四张（工作台支持 2–9 张）", "单图看图按 ⇧C 可以四张一起并排看，放大、拖动一起动；Pro 工作台里框选 2–9 张即可多图同屏对比，支持 5 图上 3 下 2 铺满、同步缩放与右侧照片信息栏联动。"),
            ("用后期软件打开", "按 ⌘E 用 Photoshop、Lightroom 或 Capture One 打开当前照片，有同名 RAW 时打开 RAW。"),
            ("RAW 和 JPG 当一张看（Pro）", "RAW 加 JPG 一起拍的话，同名的两个文件只显示一张，按 V 换着看。打星、标记、删除都只算一张。"),
            ("按客户文件名清单挑图（Pro）", "客户从微信或邮件发来一堆选片编号（如 IMG_0123、0456），在「照片 › 按文件名清单挑图…」里整段粘贴，自动匹配文件夹里的原图（支持 .JPG 跨扩展名匹配同名 .ARW/RAW），一键筛选、标记或导出。"),
            ("自定义 .cube 3D LUT 导入（Pro）", "在胶片滤镜面板（⇧F）直接导入索尼、富士、达芬奇或 Adobe 的 .cube 3D LUT（超过 64 级自动重采样），支持强度调节、实时翻页预览、导出与预设。"),
            ("修图前后对比（Pro）", "修好导出的那张跟原片叠在一起，按住 \\ 看原片，一松手就是修过的。"),
            ("按星级分文件夹（Pro）", "挑完可以按星级一下分到几个子文件夹里，也可以用 ⌥1 到 ⌥9 把照片丢进常用的文件夹。"),
            ("窗口置顶和分享", "点右上角的图钉，窗口就一直浮在最上面，修图时拿来对照参考图挺方便。分享按钮能用隔空投送、信息、邮件发出去。"),
            ("幻灯片", "每张停 1 到 10 秒，切换的渐变时长也能调。单击暂停，暂停时可以手动翻页和打星。"),
            ("HEIC 批量转 JPG", "整个文件夹一次转成 JPEG、PNG 或 HEIC，可以选保存到哪里，不会覆盖同名文件，原图不动，转到一半可以取消。"),
            ("旋转、裁剪和拉直", "转 90° 只改方向标记，JPEG、HEIC 和相机 RAW 都不重新编码，画质没有损失。按 ⇧R 打开「裁剪与拉直」，拖裁剪框或者选个比例，裁完可以覆盖原图，也可以另存一份。RAW 不会被改，裁剪结果另存成 JPEG。"),
            ("照片里写的说明", "按 I 打开照片信息，文件里写的标题和说明（IPTC）显示在最上面，下面是作者、署名、版权、地名和关键词，文字可以选中复制。按 ⇧I 在「常用」和「全部」之间切换。这些信息只能看，Flipic Lens 不改。"),
            ("说明翻译", "说明的语言和界面语言不一样时，说明下面会出现「翻译」按钮，译文显示在原文下方。用的是 macOS 自带的翻译，在本机完成，需要 macOS 15 或更新。"),
            ("EXIF 模板批量重命名与导出", "支持 {date}、{time}、{camera}、{focal}、{name}、{seq} 变量、5 套摄影预设与前 3 张实时预览，也兼容直接填前缀自动编号；同步改名 .xmp / .MOV 附属文件。导出前能看到预估体积。"),
            ("导出限尺寸、去位置与去序列号", "⌘S 导出和批量转换格式时，可设长边像素、目标大小上限（MB）、转 sRGB；拍摄信息默认保留，位置信息和相机/镜头序列号都可以单独抹掉。"),
            ("颜色标签（XMP + 访达互通）", "按 6、7、8、9 打红、黄、绿、蓝标签，再按一次取消。同时写入访达标签与标准 xmp:Label，在 Lightroom 和 Capture One 里也能认出来。"),
            ("缩略图上点右键", "在底部缩略图上选一张或几张，点右键就能送去后期软件，设好了软件时菜单第一项直接写软件名和张数。「打开方式」里能临时换别的软件，评分、标签、标记、复制、分享、移到废纸篓在这里也能用。"),
            ("裁剪记住上次的比例", "下次进入裁剪，默认用上次完成裁剪时的比例，横图裁 3:2，换到竖图会自动变成 2:3。"),
            ("导出预设（Pro）", "把常用的导出方式存成预设，一步导出一批照片：格式、质量、尺寸上限、保存位置、文件名模板、胶片/LUT、水印和参数相框都记在里面，快捷键是 ⌥⌘1 到 ⌥⌘9。"),
            ("界面语言", "支持 14 种语言，跟随系统设置。"),
        ],
        "vs_title": "和「预览」的区别",
        "vs_head": ("", "预览", "Flipic Lens"),
        "vs": [
            ("打开一张后看下一张", "要回访达全选再打开", "直接按 ← →"),
            ("在鼠标处放大到 100%", "没有单键操作", "按 0"),
            ("打星（Lightroom 能读）", "不支持", "按 1–5"),
            ("挑出连拍、闭眼、模糊", "不支持", "清理模式"),
            ("同名 RAW 和 JPG 一起处理", "不支持", "删除、清理时一起走"),
            ("HEIC 批量转 JPG", "可以，要逐步导出", "整个文件夹一次转完"),
        ],
        "keys_title": "常用快捷键",
        "keys": [("← →", "上一张 / 下一张"), ("空格", "窗口贴合照片比例"), ("0", "按住时在鼠标处放大到 100%，松手恢复"),
                 ("I / ⇧I", "照片信息（常用 / 全部）"), ("H / J / K / A", "直方图 / 过曝警示 / 焦点峰值 / 相机对焦框"),
                 ("⇧R / ⇧B", "裁剪与拉直 / EXIF 参数相框"), ("1–5", "打 1 到 5 星，再按一次取消"), ("6–9", "红、黄、绿、蓝颜色标签（XMP + 访达）"),
                 ("C / ⇧C", "并排对比 2 张 / 4 张"), ("⌘E", "在后期软件中编辑"),
                 ("⇧⌘K", "清理模式"), ("⇧F", "胶片滤镜与 .cube LUT"), ("⌘⌫", "移到废纸篓"), ("⌘,", "设置，快捷键都能改")],
        "guides_title": "指南",
        "faq": [
            ("Flipic Lens 收费吗？", "看图、评星、标记、筛选、导出、清理、两款胶片滤镜这些都免费，没有广告，也不用注册账号，代码以 MIT 协议开源在 GitHub。另有可选的 <a href=\"/pro/\">Pro</a>，¥68 一次买断，下载后可以先试用 7 天，只加了批量处理、另外八款胶片滤镜和几个专业功能，大多数人用不上。"),
            ("Flipic Lens 和 App Store 上的 Flipic 是同一个吗？", "不是。Flipic Lens 原名 Flipic（更早叫 PixDeck），是 Mac 看图挑片软件；App Store 上的「Flipic: Photo Organizer」是另一位开发者的 iPhone App。为了区分，2026 年 11 月起改名 Flipic Lens，下载地址、激活码和设置都不变。"),
            ("Mac App Store 上能下载吗？", "能，在 <a href=\"" + APP_STORE_URL + "\">Mac App Store</a> 搜 Flipic Lens" + (f"（上架时叫 {STORE_NAME}）" if STORE_NAME else "") + "，免费下载，中国大陆区暂未上架。App Store 版的 Pro 在 App 里购买，可以按月、按年订阅（年订阅首次有 7 天免费试用），也可以一次买断，付款和续订都由 Apple 处理。它和官网版是分开买的：官网的激活码在 App Store 版里用不了，App Store 里买的 Pro 也不能用在官网版上。"),
            ("从网上下载的安全吗？", "安装包用 Developer ID 签名，并通过了 Apple 公证，macOS 安装时会自动校验。Flipic Lens 没有账号，照片只在本机处理。"),
            ("能代替 Lightroom 挑片吗？", "挑片可以用它。在 Flipic Lens 里翻一遍、打星、删掉废片，打的星 Lightroom 和 Capture One 都读得到。调色修图还是回原来的软件，按 ⌘E 就能把当前这张在那边打开。"),
            ("和 Bridge、Photo Mechanic、Lightroom 有什么不同？", "Bridge 更像素材和元数据工具，Photo Mechanic 强在拷卡、IPTC 和交付，Lightroom Classic 要先进目录再挑。Flipic Lens 只做打开文件夹、翻页、看焦点、打星、标记和清理这一段，挑完再把留下的导入后期。完整对比见 <a href=\"/compare/\">Mac 看图与挑片软件对比</a>。"),
            ("能看到照片里写的图说（IPTC）吗？", "能。按 I 打开照片信息，文件里写的标题（IPTC Headline）和说明（IPTC Description）显示在面板最上面，下面是作者、署名、版权、地名和关键词。文字可以选中复制，说明里的网址可以点开，按 ⇧I 能在「常用」和「全部」之间切换。说明的语言和界面语言不一样时，说明下面有「翻译」按钮，译文显示在原文下方，用的是 macOS 自带的翻译，在本机完成，文字不会发到服务器，需要 macOS 15 或更新。这些信息只能看，Flipic Lens 不编辑 IPTC 和其他元数据。具体步骤见 <a href=\"/guides/read-iptc-caption-mac/\">Mac 上怎么看照片里的说明</a>。"),
            ("照片的拍摄地点在地图上偏了几百米，怎么回事？", "国内地图用的不是照片里存的国际通用 GPS 坐标，直接放上去会偏几百米。在中国大陆拍的照片，Flipic Lens 会先换算成地图用的坐标再标点，iPhone 拍的照片会落在实际拍摄的地方，点开「地图」App 也一样。面板上显示的坐标数字还是照片里的原值。"),
            ("Mac 上怎么看下一张图片？", "用 Flipic Lens 双击任意一张图片，按右方向键就是下一张，左方向键是上一张，同一个文件夹里的图片都能翻到。"),
            ("怎么设为默认看图软件？", "打开 Flipic Lens 的设置（⌘,），在「通用」里点「设为默认看图软件」，常见图片格式和相机 RAW 一次设好。"),
            ("能不能一次看很多张，像宫格那样？", "免费版翻片时，底部有胶片缩略图栏（支持鼠标滚轮直接翻图），单图窗口也免费自带直方图（H）、过曝警示（J）、焦点峰值（K）、相机对焦框（A）与快捷排序（⇅）。Pro 的工作台（⌥⌘B）把每场拍摄当一个项目，提供宫格、宫格+大图、胶片条（T）、单张和 2–9 张多图对比 5 种视图，侧栏可折叠（⌃⌘S），顶部实时显示 1★–5★ 数量角标，最右侧可一键展开一屏照片信息卡片（I），下载后可先免费试用 7 天。"),
            ("外接硬盘上看图和 RAW 会不会很慢？", "针对外接机械硬盘、存储卡和网络盘，Flipic Lens 会把屏幕级预览图与缩略图缓存到 Mac 内置 SSD（上限 500 MB，最久未访问自动清理，可在「设置 › 看图 › 外接盘加速」开关或清空），同时对 RAW 做前 4 MB 内嵌预览快扫并切单通道顺序读。再次打开或拔盘重插同一块硬盘时翻图接近本地速度，放大到 100% 仍读原图。详见 <a href=\"/guides/external-drive-slow-photos-mac/\">Mac 外接硬盘打开照片慢的原因与提速办法</a>。"),
            ("支持哪些格式？", "JPEG、PNG、HEIC、WebP、GIF 动图、TIFF、AVIF、JPEG XL（macOS 14 起），以及索尼、佳能、尼康、富士等相机 RAW。"),
            ("Intel 芯片的 Mac 能用吗？", "能。Flipic Lens 同时支持 Apple 芯片和 Intel 芯片，需要 macOS 13 或更新版本。"),
            ("以前装过 PixDeck 怎么办？", "Flipic Lens 就是改名后的 PixDeck。把「应用程序」里的 PixDeck 拖进废纸篓，再装 Flipic Lens，原来的设置都会保留。"),
        ],
        "wm_faq": [("导出的照片能加水印吗？", "能，免费。⌘S 导出、批量转换格式里选「水印」，或者从「文件 › 加水印导出…」进入。可以用文字或自己的图片，平铺或放在九个位置之一，大小、透明度、颜色、角度都能调。原照片不会被改，视频和动图会跳过。水印只能让别人不方便直接拿去用，防不住有心人。")],
        "end": "下载 Flipic Lens",
    },
    "en": {
        "title": "Flipic Lens: free Mac photo viewer for arrow-key culling",
        "desc": "Free Mac photo viewer for culling: double-click a photo, arrow keys for the next photo, hold 0 to check focus, rate 1 to 5. Lightroom reads the stars.",
        "eyebrow": "A Mac photo viewer for culling a shoot",
        "h1": "Photo culling on a Mac,<br>with the arrow keys",
        "lede": "Flipic Lens is free photo culling software for Mac. After a shoot, Preview only pages through the files you opened together, and Lightroom wants an import first. Flipic Lens opens the folder as it is: double-click any photo, press → for the next one, hold 0 to zoom to 100% at the pointer and check focus, 1 to 5 to rate and P to mark keepers. Ratings are saved as standard XMP, so they are still there in Lightroom and Capture One.",
        "deck_hint": "This is the real Flipic Lens window. Press <kbd>←</kbd><kbd>→</kbd> on your keyboard to page through",
        "deck_alt": "Flipic Lens showing photo {n} in a folder", "prev": "Previous", "next": "Next",
        "features": [
            ("filmstrip.webp", "Flipic Lens thumbnail strip and navigation arrows", "Page through the card, no import",
             "<p>Double-click any photo in the folder and press <kbd>→</kbd> for the next one or <kbd>←</kbd> for the previous one. Click <kbd>⇅</kbd> at the top right (or right-click › Sort By) to switch between Same as Finder, Name, Date Taken, Date Added, Size or Rating on the fly; hover over the bottom filmstrip and roll the mouse wheel to flip photos.</p>"
             "<p>The next few photos are prepared in the background, and external hard drive or ExFAT SD card previews cache to your Mac’s internal SSD so reopening or reconnecting browses at near-local speed. Press <kbd>Space</kbd> and the window wraps to the photo’s aspect ratio.</p>"),
            ("zoom.webp", "Flipic Lens zooming to 100% at the pointer to check focus", "Hold 0 to check focus",
             "<p>Point at the eyes or whatever needs to be sharp and hold <kbd>0</kbd> to zoom to 100% around it; you can tell at once whether it’s in focus. Let go to see the whole photo. Pinch and scroll-wheel zoom also center on the pointer.</p>"
             "<p>Not sure which frame in a burst is sharper? Press <kbd>C</kbd> to put two side by side (<kbd>⇧C</kbd> for four); zooming and dragging move them together, so you compare the same spot.</p>"),
            ("inspect-suite-en.webp", "Flipic Lens single-viewer inspection suite showing a live RGB histogram at the bottom left, red highlight clipping zebras, cyan focus peaking, a green camera AF point reticle, and the top Workbench and Quick Sort bar", "Histogram, clipping, focus peaking &amp; AF point",
             "<p>Run a full technical check before importing anywhere: press <kbd>H</kbd> for a live RGB &amp; luminance histogram (with shadow and highlight clipping %), <kbd>J</kbd> for red highlight and blue shadow zebra overlays, <kbd>K</kbd> for cyan focus peaking, and <kbd>A</kbd> to overlay the camera’s AF focus box.</p>"
             "<p>Reads EXIF SubjectArea, XMP MWG-RS, plus Sony and Fujifilm MakerNotes AF metadata, and keeps every overlay aligned when you rotate 90°. All four inspection tools are completely free.</p>"),
            ("settings-en.webp", "Flipic Lens Settings window with editable shortcuts", "Ratings and marks that Lightroom sees",
             "<p>Press <kbd>1</kbd> to <kbd>5</kbd> to rate (the same number again clears it), <kbd>6</kbd> to <kbd>9</kbd> for red, yellow, green or blue color labels, and <kbd>P</kbd> to mark keepers. Ratings and labels save as standard XMP (including <code>xmp:Label</code>), which Lightroom, Bridge and Capture One read; JPEG and HEIC metadata updates without recompression, and RAW ratings go into a same-name .xmp sidecar.</p>"
             "<p>When you’re done, <kbd>⇧P</kbd> shows only marked photos, or show only a minimum rating, and <kbd>⇧⌘E</kbd> copies them to another folder. Every shortcut can be changed in Settings.</p>"),
            ("cleanup-en.webp", "Flipic Lens Cleanup Mode grouping similar bursts", "Bursts, closed eyes and blur, found for you",
             "<p>After an event, press <kbd>⇧⌘K</kbd> for Cleanup Mode. Flipic Lens checks the folder on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry shots, marking the sharpest photo in each group.</p>"
             "<p>You decide what goes. Nothing is deleted until you click Move to Trash, and <kbd>⌘Z</kbd> undoes it. RAW and JPG files with the same name are handled together.</p>"),
            ("exif.webp", "Flipic Lens photo info panel with camera, lens and exposure", "Shooting details when you need them",
             "<p>Normally the window shows only the photo. Press <kbd>I</kbd> to see the camera, lens, shutter speed, aperture, ISO, date taken, IPTC captions and color profile along the right side; the photo slides over so nothing is covered. Press <kbd>Esc</kbd> to close it.</p>"
             "<p>Photos with GPS data get a small map that loads only when you click Show Map, with automatic coordinate alignment for photos taken in mainland China. iPhone HDR photos also render in true HDR on HDR displays.</p>"),
            ("exif-frame-en.webp", "Flipic Lens EXIF photo frame on a Santorini photo inside a white museum border, typesetting SONY ILCE-7M4, FE 35mm F1.4 GM, and 35mm f/8 1/2000s ISO 100 along the bottom edge", "EXIF photo frames in one shortcut",
             "<p>Press <kbd>⇧B</kbd> to frame a photo for Instagram, portfolios or print previews, and tick Photo info to automatically typeset the camera body, lens, focal length, aperture, shutter speed, ISO and date along the bottom edge.</p>"
             "<p>Choose even original-ratio margins or social presets like 4:5, 1:1 and 16:9 with white, black, blurred or custom backgrounds—text contrast adapts automatically. Works for single saves, Export (⌘S), Batch Convert and Pro export presets, completely free.</p>"),
        ],
        "film_feature": ("film-en.webp", "Flipic Lens Film Looks panel: ten swatches of the current photo with Strength, Grain and Halation sliders", "Give photos the color of film",
             "<p>Press <kbd>⇧F</kbd> to open the Film Looks panel. Each swatch is the current photo with that look, and one click switches to it. There are ten: a warm portrait look, an everyday warm, a richer slide-film color, a cool mint, a fine vivid one, a night look with a cinema feel, a muted documentary gray, and three in black and white.</p>"
             "<p>Three sliders set Strength, Grain and Halation. The look stays on as you page, so you can go through a whole set and see how it sits. Hold <kbd>\\</kbd> to see the original, press <kbd>G</kbd> to turn it on and off, and <kbd>,</kbd> and <kbd>.</kbd> for the previous and next look.</p>"
             "<p>It only changes what you see; your files are not touched. To keep a result, click Save a Copy…; camera info, caption and location go with it. Export, Batch Convert Format and export presets can apply a look to a whole batch too. Videos, animated images and HDR photos are left as they are.</p>"
             "<p>Warm Portrait and Classic B&amp;W are free. The other eight and custom .cube 3D LUT import are Pro, and everything works during the 7-day trial.</p>"),
        "wm_feature": ("wm-editor-en.webp", "Flipic Lens Export Watermarks window: a tiled text watermark previewed on a sample ID card", "Watermark the copies you export",
             "<p>Sending a copy of an ID, or a proof to a client? Add a watermark to the exported copy: text, or your own picture such as a logo, tiled diagonally across the photo or placed once in one of nine positions. Size, opacity, color and angle are adjustable.</p>"
             "<p>Three starting styles are built in: For verification only, Proof and Signature. Text supports an automatic <code>{index}</code> sequence number for numbered client proofs, and you can type a one-off line for a single export without changing your saved watermark.</p>"
             "<p>Pick one in Export (⌘S), Batch Convert Format and, with Pro, export presets, or go straight to File › Export with Watermark…. Originals are never changed, and videos and animated images are skipped. A watermark makes reuse harder but does not prevent it, so don’t rely on it alone for anything important.</p>"),
        "more_title": "More features",
        "more": [
            ("Quick sort (⇅) + filmstrip mouse-wheel flipping", "Both the Viewer top-right bar (plus right-click › Sort By) and all 5 Workbench views have a ⇅ quick sort menu for Same as Finder, Name, Capture Date, Date Added, Size or Rating. Hover over the bottom filmstrip and scroll vertically to flip photos (side buttons 3/4 also page), or hold ⌥ + wheel in the Workbench grid."),
            ("Detect & fix mismatched image extensions (Free)", "PNG or WebP images saved as .jpg break Finder thumbnails and Photoshop. Flipic Lens flags mismatches on open in a top banner and Photo Info, and Tools › Fix Mismatched Extensions… scans a whole folder in milliseconds to losslessly rename extensions (syncing .xmp/.MOV) or convert to real JPEG with white transparency flattening."),
            ("Deep ExFAT & external hard drive cold-read acceleration", "On external HDDs, ExFAT SD cards and network shares: POSIX sequential large-chunk reads, per-volume priority serial I/O, 4 MB RAW prefix embedded previews, zero Finder-tag/AppleDouble seeks, plus a 500 MB local SSD preview & thumbnail cache (toggle or clear in Settings › Viewing)."),
            ("Location map that lines up in China", "Press I and photos with a location show where they were taken. Photos from mainland China are converted to the coordinates maps there use, so the pin isn’t a few hundred metres off; Hong Kong, Macau, Taiwan and the rest of the world need no conversion. The map loads only when you ask for it."),
            ("Four up in Viewer, 2–9 up in Workbench", "Press ⇧C in the Viewer to compare four burst frames side by side with synced zoom and pan; Pro Workbench lets you select 2 to 9 photos for adaptive multi-pane comparison synced with the right Photo Info card."),
            ("Open in your editor", "⌘E opens the current photo in Photoshop, Lightroom or Capture One, or its RAW file if there is one with the same name."),
            ("RAW and JPG as one (Pro)", "If you shoot RAW + JPG, the two files with the same name show as one photo; press V to switch between them. Ratings, marks and deletes count once."),
            ("Match from a client’s filename list (Pro)", "Paste a client’s messy list of filenames or trailing numbers from chat or email (Photo › Match from Filename List…) to match files across extensions (.JPG → .ARW) and RAW+JPG pairs, then filter, mark or export."),
            ("Custom .cube 3D LUT import (Pro)", "Import 17/33/64/65-point .cube 3D LUTs from Sony, Fujifilm, DaVinci Resolve or Adobe directly in the Film Looks panel (⇧F), with live swatches, Strength slider, Export and preset support."),
            ("Before and after (Pro)", "Put an edited export next to its original: hold \\ to see the original, release to see the edit."),
            ("Sort by rating (Pro)", "When you’re done, split the folder into subfolders by stars in one go, or send photos to favorite folders with ⌥1 to ⌥9."),
            ("Keep on top and share", "Click the pin at the top right to keep the window above other apps, handy for a reference image while editing. The share button sends the photo by AirDrop, Messages or Mail."),
            ("Slideshow", "Each photo stays 1 to 10 seconds and the crossfade length is adjustable. Click to pause; while paused you can page and rate."),
            ("Batch convert HEIC to JPG", "Convert a whole folder to JPEG, PNG or HEIC. Choose where the results go; files with the same name are never overwritten, the originals are left alone, and you can cancel part way."),
            ("Rotate, crop and straighten", "90° turns only change the orientation tag, for JPEG, HEIC and camera RAW alike, so nothing is re-encoded. ⇧R opens Crop & Straighten: drag the frame or pick a ratio, then overwrite the original or save a copy. RAW files are not changed; the crop is saved as a JPEG."),
            ("Captions stored in the file", "Press I and the headline and caption written into the file (IPTC) are shown at the top of the info panel, above the creator, credit, copyright, place and keywords. The text can be selected and copied. ⇧I switches between Essentials and All. Flipic Lens reads this data and does not edit it."),
            ("Translate a caption", "When a caption is in a different language from the interface, a Translate button appears under it and the translation is shown below the original. It uses the translation built into macOS, on your Mac, and needs macOS 15 or later."),
            ("EXIF template batch rename & export", "Rename folders with {date}, {time}, {camera}, {focal}, {name} and {seq} tokens, 5 presets and live preview (plain prefixes still auto-number), keeping .xmp / .MOV sidecars in sync. Export shows an estimated file size beforehand."),
            ("Size limits, GPS & serial stripping on export", "Export (⌘S) and Batch Convert can cap the long edge in pixels, target a file size in MB and convert to sRGB. Shooting info stays by default, while GPS location and camera/lens serial numbers can be stripped independently."),
            ("Color tags (XMP + Finder)", "Press 6, 7, 8 or 9 for red, yellow, green or blue; press again to clear. Writes both Finder tags and standard xmp:Label so Lightroom and Capture One read them too."),
            ("Right-click on thumbnails", "Select one or several photos in the thumbnail strip and right-click to send them to your editor; when one is set, the first item names it and the count. Open With lets you pick another app for this time, and rating, tags, marks, copy, share and Move to Trash work here too."),
            ("Crop remembers the ratio", "The next crop starts with the ratio you last finished with. 3:2 on a landscape photo becomes 2:3 on a portrait one."),
            ("Export presets (Pro)", "Save the ways you usually export and deliver a batch in one step: format, quality, size limits, destination, file name template, film/LUT, watermark and EXIF frame are all remembered. Shortcuts are ⌥⌘1 to ⌥⌘9."),
            ("Languages", "14 interface languages, following your system setting."),
        ],
        "vs_title": "How it differs from Preview",
        "vs_head": ("", "Preview", "Flipic Lens"),
        "vs": [
            ("Next image after opening one", "Go back and select all in Finder", "Just press ← →"),
            ("Zoom to 100% at the pointer", "No single key", "Press 0"),
            ("Star ratings Lightroom can read", "No", "Press 1–5"),
            ("Find bursts, closed eyes, blur", "No", "Cleanup Mode"),
            ("RAW and JPG pairs handled together", "No", "When deleting and cleaning up"),
            ("Batch convert HEIC to JPG", "Yes, export step by step", "A whole folder at once"),
        ],
        "keys_title": "Keyboard shortcuts",
        "keys": [("← →", "Previous / next photo"), ("Space", "Wrap the window to the photo"), ("0", "Zoom to 100% at the pointer; hold to peek"),
                 ("I / ⇧I", "Photo info (Essentials / All)"), ("H / J / K / A", "Histogram / clipping / peaking / AF point"),
                 ("⇧R / ⇧B", "Crop & Straighten / EXIF photo frame"), ("1–5", "Rate one to five stars; again to clear"), ("6–9", "Red, yellow, green, blue tags (XMP + Finder)"),
                 ("C / ⇧C", "Compare 2 or 4 photos side by side"), ("⌘E", "Edit in your photo editor"),
                 ("⇧⌘K", "Cleanup Mode"), ("⇧F", "Film Looks & .cube LUTs"), ("⌘⌫", "Move to Trash"), ("⌘,", "Settings; change any shortcut")],
        "guides_title": "Guides",
        "faq": [
            ("Is Flipic Lens free?", "Viewing, ratings, marks, filtering, export, Cleanup Mode and two film looks are free, with no ads and no account, and the code is MIT licensed on GitHub. There is an optional <a href=\"/en/pro/\">Pro</a> upgrade, $12.99 once, with a 7-day trial in every download. It adds batch tools, the other eight film looks and a few pro features; most people won’t need it."),
            ("Is Flipic Lens the same as Flipic on the App Store?", "No. Flipic Lens was formerly Flipic (and PixDeck before that) and is a Mac culling app. “Flipic: Photo Organizer” on the App Store is an iPhone app from another developer. We renamed to Flipic Lens in November 2026 to keep the two apart; download links, license keys and settings are unchanged."),
            ("Is Flipic Lens on the Mac App Store?", "Yes. Search for Flipic Lens on the <a href=\"" + APP_STORE_URL + "\">Mac App Store</a>" + (f" (it launched there as {STORE_NAME})" if STORE_NAME else "") + "; it is a free download, not available in mainland China. In the App Store version, Pro is bought inside the app as a monthly or yearly subscription (the yearly plan starts with a 7-day free trial for new subscribers) or a one-time purchase, and Apple handles payment and renewals. It is bought separately from the website version: a license key from flipic.app doesn’t work in the App Store version, and Pro bought on the App Store doesn’t carry over to the website version."),
            ("Is the download safe?", "It is signed with a Developer ID and notarized by Apple; macOS checks it on install. Flipic Lens has no account and keeps photos on your Mac."),
            ("Can it replace Lightroom for culling?", "For culling, yes; for editing, no. Page through, check focus, rate, mark and delete rejects in Flipic Lens, and Lightroom or Capture One will read the ratings. Edit in the app you already use; ⌘E opens the current photo there."),
            ("How is Flipic Lens different from Bridge, Photo Mechanic or Lightroom?", "Bridge is an asset and metadata browser, Photo Mechanic is built for ingest, IPTC and delivery, and Lightroom Classic works from an imported catalog. Flipic Lens covers the catalog-free first pass: open a folder, page, check focus, rate, mark and clean up, then send the keepers to your editor. See the <a href=\"/en/compare/\">full comparison</a>."),
            ("Can I read the caption or IPTC data stored in a photo?", "Yes. Press I and the headline (IPTC Headline) and caption (IPTC Description) written into the file are shown at the top of the info panel, followed by the creator, credit, copyright, place and keywords. The text can be selected and copied, links in a caption can be clicked, and ⇧I switches the panel between Essentials and All. When the caption is in a different language from the interface, a Translate button under it shows a translation below the original. Translation uses the one built into macOS and runs on your Mac, so the text is not sent to a server; it needs macOS 15 or later. Flipic Lens only reads this data and does not edit IPTC or other metadata. Steps are in <a href=\"/en/guides/read-iptc-caption-mac/\">how to read an IPTC caption on a Mac</a>."),
            ("Why is a photo’s location a few hundred metres off on the map?", "In mainland China, maps use a different coordinate system from the standard GPS coordinates stored in photos, so a pin placed directly ends up a few hundred metres away. Flipic Lens converts coordinates for photos taken there before placing the pin, and does the same when opening Maps. The coordinates shown as text are still the values stored in the photo."),
            ("How do I see the next image on a Mac?", "Double-click any image in Flipic Lens and press the right arrow key for the next one, the left arrow for the previous one, across the whole folder."),
            ("How do I make it my default viewer?", "Open Settings (⌘,) and click Make Default Viewer under General; common image formats and camera RAW are set in one go."),
            ("Can I see many photos at once, in a grid?", "The free version includes a bottom filmstrip with mouse-wheel paging, single-viewer histogram (H), clipping zebras (J), focus peaking (K), camera AF point (A) and quick sort (⇅). Pro adds the Workbench (⌥⌘B): one project per shoot with a collapsible sidebar (⌃⌘S), live per-star counts, five view modes including Filmstrip (T) and 2–9 photo multi-compare, and a one-screen Photo Info card on the right (I), with a 7-day trial in every download."),
            ("Is it fast with photos on an external hard drive?", "For external hard drives, SD cards and network shares, Flipic Lens caches screen-sized previews and thumbnails on your Mac’s internal SSD (up to 500 MB with automatic LRU cleanup; toggle or clear in Settings › Viewing › External drives), scans only the first 4 MB of RAW files for embedded previews, and switches to single-lane sequential I/O on slow storage. Reopening or reconnecting the same drive browses at near-local speed, while 100% zoom always reads the original. See <a href=\"/en/guides/fast-photo-viewer-external-hard-drive-mac/\">why photos open slowly from an external hard drive on Mac</a>."),
            ("Which formats are supported?", "JPEG, PNG, HEIC, WebP, animated GIF, TIFF, AVIF, JPEG XL (macOS 14 or later) and camera RAW from Sony, Canon, Nikon, Fujifilm and others."),
            ("Does it run on Intel Macs?", "Yes. Flipic Lens is universal for Apple silicon and Intel and needs macOS 13 or later."),
        ],
        "wm_faq": [("Can I add a watermark to exported photos?", "Yes, and it is free. Choose a watermark in Export (⌘S) or Batch Convert Format, or use File › Export with Watermark…. It can be text or your own picture, tiled or placed in one of nine positions, with size, opacity, color and angle adjustable. Originals are never changed, and videos and animated images are skipped. A watermark makes reuse harder but cannot prevent it.")],
        "end": "Download Flipic Lens",
    },
}

# ---------------------------------------------------------------- 指南

GUIDES = {"zh": [], "en": []}


def guide(lang, path, title, short, desc, summary, body, howto=None, faq=None, title_suffix=True,
          updated=UPDATED, published=UPDATED):
    published = min(published, updated)   # 发布日期不能晚于更新日期（默认值 UPDATED 会比手写的 updated 新）
    GUIDES[lang].append(dict(path=path, title=title, short=short, desc=desc, summary=summary, body=body,
                             howto=howto, faq=faq, title_suffix=title_suffix, updated=updated, published=published))


guide("zh", "/guides/mac-next-image/", "Mac 预览怎么看下一张图片？三种办法",
      "Mac 预览怎么看下一张",
      "Mac 自带的「预览」打开一张图后翻不到下一张。这里讲三种办法：访达里全选再打开、空格快速查看、用 Flipic Lens 双击后直接按左右键。",
      "预览只打开单张时翻不了；全选打开、空格快速查看、换个看图软件",
      f"""<p>在访达里双击一张照片，「预览」只会打开这一张。下面三种办法按顺手程度排。</p>
<h2>为什么方向键翻不过去</h2>
<p>「预览」不会把一个文件夹当成一组照片。双击一张时，它只打开你点的那一个文件，窗口里没有别的图，方向键自然没有下一张可翻。只有把多张图一起用预览打开，方向键才会在这些图之间切换。所以要么一次全选打开，要么换一个直接读整个文件夹的看图软件。</p>
<h2>办法一：在访达里全选，再一起打开</h2>
<ol><li>在访达里打开照片所在的文件夹，按 <kbd>⌘A</kbd> 全选。</li><li>按 <kbd>⌘↓</kbd>（或右键选「打开」），所有图片会一起进到预览里。</li><li>在预览里按 <kbd>↑</kbd> <kbd>↓</kbd> 或 <kbd>←</kbd> <kbd>→</kbd> 切换，左侧边栏是缩略图。</li></ol>
<p>缺点是每次都得先回访达全选；文件夹里几百张时，一次全部打开会慢。</p>
<h2>办法二：选中后按空格，用「快速查看」翻</h2>
<p>在访达里选中多张图片（或 <kbd>⌘A</kbd> 全选），按 <kbd>空格</kbd> 打开快速查看，再按 <kbd>←</kbd> <kbd>→</kbd> 就能在选中的图片之间切换。看完按 <kbd>空格</kbd> 或 <kbd>Esc</kbd> 关掉。</p>
<p>快速查看适合扫一眼。放大、看拍摄参数、删除这些操作它都不方便。</p>
<h2>办法三：用 Flipic Lens，双击后直接按左右键</h2>
<p>Flipic Lens 是免费开源的 Mac 看图软件。双击任意一张，按 <kbd>→</kbd> 就是下一张，同一个文件夹里的图片都能翻到，不用先全选。</p>
<figure>{shot('browse-06.webp', 'Flipic Lens 打开一张照片后按方向键翻看同一文件夹')}<figcaption>Flipic Lens 打开一张后，底部缩略图栏是整个文件夹。</figcaption></figure>
<p>想以后双击照片都用 Flipic Lens 打开：在 Flipic Lens 的设置（<kbd>⌘,</kbd>）里点「设为默认看图软件」。也可以在访达里右键一张图，按住 <kbd>⌥</kbd>，选「始终以此方式打开」› Flipic Lens。</p>
<p>设好之后可以当快速查看用：在访达里选中照片按 <kbd>⌘↓</kbd> 打开，左右翻看；在设置里打开「按 Esc 关闭窗口」，看完按 <kbd>Esc</kbd> 回到访达。</p>""",
      howto=["在访达里双击任意一张图片，用 Flipic Lens 打开", "按右方向键看下一张，左方向键看上一张", "按住 0 在鼠标处放大到 100%，松手回到全图"],
      faq=[
          ("Mac 预览怎么翻到下一张照片？",
           "预览只在你一起打开的文件之间切换。先在访达里全选照片，按 ⌘↓ 一起打开，方向键才有下一张；或者用空格快速查看；也可以换成 Flipic Lens，双击一张后直接按 →。"),
          ("MacBook 上怎么用方向键看下一张图片？",
           "双击单张照片时，预览只认识这一张，方向键不会翻到文件夹里的其他图。把照片全选后用预览打开，或者用 Flipic Lens 打开文件夹，用 ← → 一张张翻。"),
          ("为什么「预览」里按方向键没反应？",
           "你只把一张图交给了预览，窗口里没有别的图可翻。一次多选几张一起打开，或者换一个读整个文件夹的看图软件。"),
      ], title_suffix=False, updated="2026-11-07")

guide("zh", "/guides/heic-to-jpg-mac/", "Mac HEIC 批量转 JPG",
      "Mac 批量 HEIC 转 JPG",
      "iPhone 拍的 HEIC 照片发到 Windows 打不开。Mac 上不装付费软件也能批量转 JPG：访达快速操作、预览导出、终端 sips 命令，以及用 Flipic Lens 整个文件夹一次转完。",
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
<h2>办法四：用 Flipic Lens，整个文件夹一次转完</h2>
<ol><li>用 Flipic Lens 打开要转换的文件夹。</li><li>菜单「工具」›「批量转换格式」，或按 <kbd>⇧⌘C</kbd>。</li><li>选 JPEG，拖动滑杆调质量，开始转换。</li></ol>
<figure>{shot('convert.webp', 'Flipic Lens 批量转换格式对话框，可选 JPEG、PNG、HEIC 与质量')}<figcaption>转好的文件放进子文件夹，原图不动。</figcaption></figure>
<p>Flipic Lens 也能反过来把 JPEG、PNG 转成 HEIC 省空间，同样整个文件夹一次转完。</p>""",
      howto=["用 Flipic Lens 打开要转换的文件夹", "选择工具 › 批量转换格式（⇧⌘C）", "格式选 JPEG，调好质量后开始转换"])

guide("zh", "/guides/windows-image-viewer-for-mac/", "Windows 看图软件的替代",
      "Honeyview、IrfanView 的 Mac 替代",
      "Honeyview（蜂蜜浏览器）和 IrfanView 都只有 Windows 版。刚换到 Mac 想要同样的看图手感，可以看看 Flipic Lens、XnView MP、qView 这几个能在 Mac 上用的看图软件。",
      "Windows 看图软件没有 Mac 版时，按手感和需求挑一个",
      f"""<p>Honeyview（蜂蜜浏览器）、IrfanView、Windows 自带的照片查看器，都是打开一张图后用方向键往下翻、滚轮缩放。Mac 上系统的「预览」不是这样用的，刚换过来的人最先不习惯的就是这一点。</p>
<h2>Honeyview 和 IrfanView 有 Mac 版吗</h2>
<p>没有。Honeyview 由 Bandisoft 开发，只出了 Windows 版；IrfanView 官方也只支持 Windows。网上的「Mac 版」要么是别的软件，要么是用 Wine 套壳运行，不建议装来路不明的安装包。</p>
<h2>Mac 上可以用的替代</h2>
<p><strong>Flipic Lens</strong>：免费开源，安装包 8 MB 左右。双击一张图后用 <kbd>←</kbd> <kbd>→</kbd> 翻完整个文件夹，滚轮默认缩放，按 <kbd>0</kbd> 在鼠标处放大到 100%，这些都照着 Windows 看图软件的手感来做。快捷键都能在设置里改；用 Mos 改过滚轮方向的，可以把缩放方向反过来。</p>
<p><strong>XnView MP</strong>：功能很全的跨平台看图和管理软件，个人使用免费。适合需要大量格式转换、元数据编辑的人，界面比较复杂。</p>
<p><strong>qView</strong>：开源的极简看图软件，界面几乎只有图片。功能少，适合只想打开看看的人。</p>
<h2>换过来后常见的几处不同</h2>
<ul><li><strong>设成默认：</strong>在 Flipic Lens 设置里点「设为默认看图软件」，以后双击照片就用它打开。</li><li><strong>删除照片：</strong>Mac 上是 <kbd>⌘⌫</kbd> 移到废纸篓，不是 Delete 键。</li><li><strong>滚轮方向：</strong>Mac 默认是「自然滚动」，方向和 Windows 相反，可以在系统设置里改，或用 Mos 只改鼠标。</li></ul>
<figure>{shot('zoom.webp', 'Flipic Lens 在鼠标位置放大到 100%')}<figcaption>按住 0 在鼠标处放大到 100%，松手回到全图。</figcaption></figure>""")

guide("zh", "/guides/cull-event-photos/", "Mac 上怎么挑活动照片",
      "活动照片快速挑片",
      "会议、婚礼、活动一拍就是几百张。讲一个在 Mac 上挑片的流程：先自动挑出连拍、闭眼、模糊的废片，再快速翻看打星，最后把留下的交给 Lightroom 修。",
      "先清废片，再打星，最后交给后期",
      f"""<p>活动照片最花时间的不是修图，是从几百张里挑出能用的几十张。下面这个流程用 Flipic Lens 一个软件就能走完，照片不用导进任何图库。</p>
<h2>第一步：先让软件挑出明显的废片</h2>
<p>用 Flipic Lens 打开整个文件夹，按 <kbd>⇧⌘K</kbd> 进入清理模式。它在本机检查每一张，分成四类：相似连拍、内容完全相同、闭眼、模糊或虚焦。连拍组里推荐保留最清楚、没人闭眼的那张，其余默认勾上。</p>
<figure>{shot('cleanup.webp', 'Flipic Lens 清理模式按相似连拍分组并推荐保留', 1440, 967)}<figcaption>闭眼的照片会框出是哪张脸，空格放大检查。</figcaption></figure>
<p>只有你按「移到废纸篓」才会删除，删错了 <kbd>⌘Z</kbd> 撤销。自动判断会有误判，删之前过一眼。</p>
<h2>第二步：快速翻看，用星级标出要的</h2>
<p>剩下的照片按 <kbd>→</kbd> 一张张翻，喜欢的按 <kbd>1</kbd> 到 <kbd>5</kbd> 打星，想看细节就把鼠标停在脸上按 <kbd>0</kbd> 放大到 100%。也可以开幻灯片放映，看到好的单击暂停，打完星再单击继续。</p>
<p>星级按 XMP 标准写入：JPEG、HEIC 写进文件本身，专有 RAW 写在同名 .xmp 文件里，原始文件不动。</p>
<h2>第三步：把选好的交给后期</h2>
<p>在 Flipic Lens 设置里选好 Lightroom、Photoshop 或 Capture One，看到要修的照片按 <kbd>⌘E</kbd> 打开，同名 RAW 在时打开 RAW。导入 Lightroom 时，刚才打的星级也会一起带过去，可以直接按星级筛选。</p>
<p>打完星在 Lightroom 里怎么读，见 <a href="/guides/star-rating-lightroom/">Mac 照片打星，Lightroom 能认吗</a>；连拍、闭眼和拍糊的照片怎么先分组，见 <a href="/guides/burst-closed-eyes-cleanup/">连拍、闭眼、拍糊的照片，Mac 上先挑再删</a>。</p>""",
      howto=["用 Flipic Lens 打开整个文件夹，按 ⇧⌘K 进入清理模式", "确认要删的连拍、闭眼、模糊照片，移到废纸篓", "翻看剩下的照片，按 1–5 打星", "按 ⌘E 把选中的照片交给 Lightroom 或 Photoshop"], updated="2026-11-07")

guide("en", "/en/guides/mac-preview-next-image/", "How to go to the next photo on a Mac (Preview arrow keys)",
      "How to go to the next photo on a Mac",
      "Preview only pages through the photos you opened together, so the arrow keys stop after one. Three ways to page a whole folder: one Finder shortcut, Quick Look, or a viewer.",
      "Why the arrows stop, and how to page a whole folder",
      f"""<p>Preview opens only the file you double-clicked, so the arrow keys have nothing to move to. The direct fix is to open the folder's photos as a set: select them in Finder, press <kbd>⌘↓</kbd>, and the arrows work inside that Preview window. If you would rather start from one photo and keep paging, double-click it in Flipic Lens and press <kbd>→</kbd>.</p>
<h2>How to go to the next picture in Preview</h2>
<ol><li>Open the folder in Finder.</li><li>Press <kbd>⌘A</kbd> to select every photo (or ⌘-click the ones you want).</li><li>Press <kbd>⌘↓</kbd>. The photos open in one Preview window, listed in the sidebar.</li><li>Press <kbd>→</kbd> or <kbd>Page Down</kbd> for the next picture and <kbd>←</kbd> or <kbd>Page Up</kbd> for the previous one.</li></ol>
<p>This works, but opening hundreds of RAW files just to look at one is slow, and you make the trip back to Finder every time.</p>
<h2>Why the arrow keys don't go to the next photo in Preview</h2>
<p>If <kbd>←</kbd> <kbd>→</kbd> still do nothing, check what Preview has open: one document has no next image inside it. Apple's shortcut list sends the Up and Down arrows to the sidebar and <kbd>Page Down</kbd> to the next image in the window, so the keys only move inside a set that is already open (<a href="https://support.apple.com/guide/preview/cpprvw0003/mac">Apple Preview shortcuts</a>). Quick Look and a folder viewer take a different route.</p>
<h2>How to see the next photo without opening Preview (Quick Look)</h2>
<p>Quick Look is built into macOS and needs no extra app. Select one or more files in Finder and press <kbd>Space</kbd>; Apple's guide says the window shows a full-size preview without opening the file, and with several items selected the Left and Right arrow keys move between them (<a href="https://support.apple.com/guide/mac-help/view-and-edit-files-with-quick-look-mh14119/mac">Apple Quick Look guide</a>). MacMost makes the same case for viewing files rather than editing them (<a href="https://macmost.com/use-quick-look-instead-of-preview-to-view-files.html">MacMost</a>). It is a preview window tied to the Finder selection, not a folder browser, and closing it ends the session.</p>
<h2>How to go to the next photo on a MacBook trackpad</h2>
<p>In Flipic Lens, two fingers on the trackpad do what the arrow keys do. Swipe left or right to change photos, and left goes to the next one. Pinch to zoom, or double-click to switch between fit and 100%. The recording below is the real app, paging, zooming to 100% and rating in real time.</p>
<figure>{shot('demo-paging.webp', 'Flipic Lens paging through 34 RAW files from 34 different cameras', 960, 540)}<figcaption>Real-time screen recording: 34 RAW files from 34 different cameras.</figcaption></figure>
<h2>How to go to the next photo in a folder from one double-click</h2>
<p>In the Windows Photos viewer the loop is one double-click, arrows through the folder, wheel to zoom and Delete to reject. Preview does not do that from one file. Flipic Lens, which is free and open source, does: double-click any photo in the folder, press <kbd>←</kbd> <kbd>→</kbd> to page, use the wheel or a pinch to zoom, and <kbd>⌘⌫</kbd> to move a photo to the Trash (the Delete key alone does not). Hold <kbd>0</kbd> to check focus at 100% and let go to fit.</p>
<h3>Make it the viewer that opens on a double-click</h3>
<p>Open Settings (<kbd>⌘,</kbd>) and click Make Default Viewer under General; common image formats and camera RAW are set in one go. You can also Control-click a photo in Finder, hold <kbd>⌥</kbd> and choose Always Open With › Flipic Lens. After that, select a photo, press <kbd>⌘↓</kbd>, page with the arrows and press <kbd>Esc</kbd> to go back to Finder (turn on Esc Closes Window in Settings first).</p>
<p>The Windows Photos habit is mapped out in <a href="/en/guides/mac-photo-viewer-like-windows/">Mac photo viewer like Windows</a>.</p>""",
      howto=["Double-click any image in Finder to open it in Flipic Lens", "Press the right arrow key for the next image and the left arrow for the previous one", "Hold 0 to zoom to 100% at the pointer; let go to fit"],
      faq=[
          ("How do I go to the next photo in Mac Preview?",
           "Open the photos together first: select them in Finder, press ⌘↓, then use the arrow keys or Page Down. Preview cannot page a folder from one double-clicked file."),
          ("How do I move to the next photo in Mac Preview with the arrow keys?",
           "The arrows move within the set that is open. If only one file is open, add the others with ⌘A and ⌘↓ in Finder, or switch to Quick Look or Flipic Lens."),
          ("How do I see the next photo in the same folder?",
           "Open the folder in Flipic Lens and double-click any photo; ← and → walk the whole folder without selecting files first."),
          ("How do I go to the next picture on a MacBook?",
           "Use ← → in Flipic Lens, or swipe left or right with two fingers and swipe left for the next photo. In Preview, open the photos as a set first."),
          ("Which Mac image viewer has a next image key?",
           "Preview, Quick Look and Flipic Lens all respond to the arrow keys, but only Flipic Lens reads the whole folder from one double-click. Quick Look moves through the Finder selection."),
      ], title_suffix=False, updated="2026-11-13")

guide("en", "/en/guides/batch-convert-heic-to-jpg-mac/", "How to batch convert HEIC to JPG on Mac",
      "Batch convert HEIC to JPG",
      "Four free ways to batch convert iPhone HEIC photos to JPG on a Mac: Finder Convert Image, Preview export, the sips command, or Flipic Lens.",
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
<h2>4. Flipic Lens: a whole folder at once</h2>
<ol><li>Open the folder in Flipic Lens.</li><li>Choose Tools › Batch Convert, or press <kbd>⇧⌘C</kbd>.</li><li>Pick JPEG, set the quality and start.</li></ol>
<figure>{shot('convert.webp', 'Flipic Lens batch convert dialog with JPEG, PNG and HEIC')}<figcaption>Converted files go into a subfolder; originals stay untouched.</figcaption></figure>""",
      howto=["Open the folder in Flipic Lens", "Choose Tools › Batch Convert (⇧⌘C)", "Pick JPEG, set the quality and start the conversion"])

guide("en", "/en/guides/irfanview-for-mac/", "IrfanView for Mac: free alternatives",
      "IrfanView for Mac alternatives",
      "IrfanView and Honeyview are Windows-only. If you just moved to a Mac and miss arrow-key browsing and wheel zoom, try Flipic Lens, XnView MP or qView.",
      "No Mac version exists; pick by feel and needs",
      f"""<p>IrfanView, Honeyview and the Windows Photos viewer all work the same way: open one image, press the arrow keys to page, scroll to zoom. Preview on Mac doesn't, and it's the first thing switchers miss.</p>
<h2>Is there an IrfanView for Mac?</h2>
<p>No. IrfanView officially supports Windows only, and Honeyview from Bandisoft is Windows-only too. Anything labeled "for Mac" is either a different app or Windows software wrapped in Wine, so be careful with unofficial installers.</p>
<h2>Alternatives that run natively on a Mac</h2>
<p><strong>Flipic Lens</strong>: free and open source, an 8 MB download. Double-click a photo and page with <kbd>←</kbd> <kbd>→</kbd>; the wheel zooms by default; <kbd>0</kbd> zooms to 100% at the pointer. Every shortcut can be remapped, and if you reversed your wheel with Mos you can flip the zoom direction.</p>
<p><strong>XnView MP</strong>: a full-featured cross-platform viewer and organizer, free for personal use; great for heavy conversion and metadata work, busier interface.</p>
<p><strong>qView</strong>: a minimal open-source viewer that is little more than the image; few features by design.</p>
<h2>Things that work differently on a Mac</h2>
<ul><li><strong>Default viewer:</strong> click Make Default Viewer in Flipic Lens's Settings.</li><li><strong>Deleting:</strong> <kbd>⌘⌫</kbd> moves a photo to the Trash; the Delete key alone doesn't.</li><li><strong>Scroll direction:</strong> macOS uses natural scrolling, the reverse of Windows; change it in System Settings or for the mouse only with Mos.</li></ul>
<p>For the Windows Photos viewer habit specifically, see <a href="/en/guides/mac-photo-viewer-like-windows/">Mac photo viewer like Windows</a>.</p>
<figure>{shot('zoom.webp', 'Flipic Lens zooming to 100% at the pointer')}<figcaption>Hold 0 to zoom to 100% under the pointer; let go to fit.</figcaption></figure>""")

guide("en", "/en/guides/mac-photo-viewer-like-windows/", "Free Mac photo viewer like Windows, with arrow keys",
      "Mac photo viewer like Windows",
      "Free Mac photo viewer like Windows Photos: double-click one photo, page the whole folder with the arrow keys, zoom with the wheel, delete with ⌘⌫.",
      "The double-click, arrow, zoom and delete loop, rebuilt on a Mac",
      f"""<p>If you came from Windows, the Photos viewer gave you a simple loop: double-click a picture, press the arrow keys to move through the folder, scroll to zoom, and press Delete when a shot is no good. macOS splits that loop between Preview, Quick Look and Finder, which is why the first double-click often feels like a dead end.</p>
<h2>What the Windows Photos viewer does in one window</h2>
<p>One window, one folder, one photo at a time. The next photo is one arrow key away, the wheel zooms, and Delete removes a shot. Nothing needs importing, and you do not select the rest of the folder before you start. That is the habit this page is about.</p>
<h2>Where Preview stops</h2>
<p>Preview is an editor and a document viewer, not a folder browser. Double-click one image and it opens exactly that file. Apple's shortcut list sends the Up and Down arrows to the sidebar and Page Down to the next image in the window, so the keys only reach documents already open (<a href="https://support.apple.com/guide/preview/cpprvw0003/mac">Apple Preview shortcuts</a>). MacMost puts it plainly: after a double-click, Preview cannot move to the next file with the arrow keys (<a href="https://macmost.com/use-quick-look-instead-of-preview-to-view-files.html">MacMost</a>).</p>
<h2>Where Quick Look stops</h2>
<p>Quick Look is closer because it follows the Finder selection. Select files, press <kbd>Space</kbd>, and the Left and Right arrows move through the selected items (<a href="https://support.apple.com/guide/mac-help/view-and-edit-files-with-quick-look-mh14119/mac">Apple Quick Look guide</a>). It is still a preview window tied to the Finder selection, not a viewer with a folder behind it: zoom is <kbd>⌘+</kbd> and <kbd>⌘-</kbd> rather than the wheel, and closing the window ends the session.</p>
<h2>Flipic Lens: the Windows-style loop on a Mac</h2>
<p>Flipic Lens is a free, open-source Mac photo viewer that reads the folder directly. Double-click any photo, press <kbd>→</kbd> for the next one and <kbd>←</kbd> for the previous one; the strip along the bottom is the rest of the folder. The wheel zooms around the pointer, a pinch zooms on the trackpad, and holding <kbd>0</kbd> shows 100% at the pointer, with the fit view back when you let go. <kbd>⌘⌫</kbd> moves the current photo to the Trash and <kbd>⌘Z</kbd> puts back the last one. Ratings 1 to 5 and <kbd>P</kbd> marks are there when you want them, and the stars are standard XMP that Lightroom reads.</p>
<h2>Set it as the default photo viewer</h2>
<p>Open Settings (<kbd>⌘,</kbd>) and click Make Default Viewer under General; common image formats and camera RAW are set in one go. Or Control-click a photo in Finder, hold <kbd>⌥</kbd> and choose Always Open With › Flipic Lens. After that, a double-click opens the photo in Flipic Lens, the arrows page the folder, and with Esc Closes Window turned on, <kbd>Esc</kbd> returns to Finder.</p>
<h2>Not the same as an IrfanView replacement</h2>
<p>This page is about the Windows Photos loop. If you are looking for IrfanView or Honeyview themselves, the differences are on the <a href="/en/guides/irfanview-for-mac/">IrfanView for Mac alternatives</a> page. That page covers the Windows-only apps and the native Mac options; this one covers the double-click, arrow, zoom and delete habit.</p>""",
      howto=["Double-click any photo in Finder to open it in Flipic Lens", "Press the right arrow key for the next photo and the left arrow for the previous one", "Scroll or pinch to zoom; hold 0 for 100% at the pointer", "Press ⌘⌫ to move a reject to the Trash"],
      faq=[
          ("Is there a free Mac photo viewer like Windows Photos?",
           "Yes. Flipic Lens is free and open source, reads a folder without importing, and pages with the arrow keys after one double-click."),
          ("Is there a Mac image viewer with arrow keys?",
           "Not one built in that reads a folder from a single double-click. Preview needs the photos opened together, Quick Look moves through a selection, and Flipic Lens reads the folder."),
          ("How do I zoom and delete like in Windows Photos?",
           "In Flipic Lens use the wheel or a pinch to zoom, hold 0 for 100% at the pointer, and press ⌘⌫ to move the photo to the Trash; ⌘Z puts it back."),
          ("How do I set Flipic Lens as my default photo viewer?",
           "Open Settings (⌘,) and click Make Default Viewer, or Control-click a photo in Finder, hold ⌥ and choose Always Open With › Flipic Lens."),
          ("Is this the same as an IrfanView alternative?",
           "No. IrfanView is a specific Windows app; this page is about the Windows Photos habit. The IrfanView page covers that replacement."),
      ], title_suffix=False, updated="2026-11-13", published="2026-11-13")

guide("en", "/en/guides/cull-photos-on-mac/", "How to cull hundreds of event photos on a Mac",
      "Cull event photos on Mac",
      "A fast culling workflow on Mac: remove bursts, closed eyes and blur automatically, rate the rest with 1–5, then open keepers in Lightroom.",
      "Clear the rejects, rate the rest, hand off to your editor",
      f"""<p>The slow part of an event shoot isn't editing; it's finding the fifty usable frames among hundreds. This workflow runs in <a href="/en/">Flipic Lens</a> alone, with no catalog import.</p>
<h2>1. Let the app find the obvious rejects</h2>
<p>Open the folder in Flipic Lens and press <kbd>⇧⌘K</kbd> for Cleanup Mode. It checks every photo on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry or out-of-focus shots, suggesting the sharpest blink-free frame of each burst.</p>
<figure>{shot('cleanup-en.webp', 'Flipic Lens Cleanup Mode grouping bursts and suggesting a keeper', 1440, 967)}<figcaption>Faces flagged for closed eyes are outlined; Space zooms in to check.</figcaption></figure>
<p>Nothing is deleted until you press Move to Trash, and <kbd>⌘Z</kbd> undoes it. Detection can be wrong, so look before you delete.</p>
<h2>2. Page through and rate</h2>
<p>Press <kbd>→</kbd> through what's left and <kbd>1</kbd>–<kbd>5</kbd> to rate (if the arrow keys stop after one photo in Preview, see <a href="/en/guides/mac-preview-next-image/">how to go to the next photo on a Mac</a>). Rest the pointer on a face and press <kbd>0</kbd> to check focus at 100%. Or run a slideshow, click to pause on a good one, rate it, click to resume.</p>
<p>Ratings are standard XMP: inside JPEG and HEIC files, in a same-name .xmp sidecar for proprietary RAW, leaving the RAW untouched.</p>
<h2>3. Hand the keepers to your editor</h2>
<p>Choose Lightroom, Photoshop or Capture One in Settings and press <kbd>⌘E</kbd> on a photo to open it there, the RAW if one sits next to the JPEG. Lightroom picks up the star ratings on import, so you can filter by them right away.</p>
<p>For the side-by-side view itself, see <a href="/en/guides/compare-photos-side-by-side-mac/">how to compare similar photos side by side on Mac</a>.</p>""",
      howto=["Open the folder in Flipic Lens and press ⇧⌘K for Cleanup Mode", "Review the suggested bursts, closed eyes and blurry shots and move them to the Trash", "Page through the rest and rate with 1–5", "Press ⌘E to open keepers in Lightroom or Photoshop"], updated="2026-11-07")


guide("zh", "/guides/mac-image-viewer-recommend/", "Mac 看图软件推荐 2026",
      "Mac 看图软件推荐",
      "Mac 自带的预览翻不了整个文件夹。这里把 2026 年还在更新的 Mac 看图软件按免费开源、免费不开源、付费三类列出来，写清楚各自适合谁。",
      "免费开源、免费、付费三类，各自适合什么人",
      f"""<p>Mac 自带的「预览」只在你一起打开的几个文件之间切换，双击打开一张后，同一个文件夹里的其他图片翻不到。下面这些都能解决这个问题，按类型分开写。信息在 2026 年 11 月 1 日从各自官网、GitHub 和 App Store 核对过，价格和版本以官网为准。</p>
<h2>免费开源</h2>
<table><thead><tr><th>软件</th><th>协议</th><th>适合</th></tr></thead><tbody>
<tr><td>Flipic Lens</td><td>MIT</td><td>只用 Mac、想要 Windows 看图软件那种手感：双击后方向键翻整个文件夹，按 0 在鼠标处放大到 100%，打星、标记、挑片</td></tr>
<tr><td>PicView</td><td>GPL-3.0</td><td>Mac 和 Windows 都用；支持的格式多，相机 RAW 也在列；可以 <code>brew install picview</code></td></tr>
<tr><td>FlowVision</td><td>GPL-3.0</td><td>喜欢按瀑布流网格浏览整个文件夹，也看视频；Swift 写的原生 Mac 软件。和 Flipic Lens 的区别：它偏网格浏览，Flipic Lens 偏单张方向键翻页挑片，免费版有底部缩略图栏，Pro 工作台也有宫格</td></tr>
<tr><td>qView</td><td>GPL-3.0</td><td>只想看图、越简单越好；界面只有图片和标题栏，方向键翻页</td></tr>
<tr><td>nomacs</td><td>GPL-3.0</td><td>Windows、Linux 上用惯了 nomacs；功能多，RAW 用 LibRaw 解</td></tr>
<tr><td>Oculante</td><td>MIT</td><td>想要速度和一点简单编辑；Rust 写的，跨平台</td></tr>
<tr><td>ImageGlass</td><td>GPL-3.0</td><td>Windows 上的老用户；Mac 版刚出 beta，需要 macOS 14 和 Apple 芯片，Pro 功能另外付费</td></tr>
</tbody></table>
<p>不太推荐的：Phew 只能打开 FLIF 格式，作者已经说不再维护；Sequential 的维护分支 2024 年 9 月之后没有发新版。</p>
<h2>免费但不开源</h2>
<p><strong>XnView MP</strong>：个人和教育用途免费，公司用要买授权。支持 500 多种格式，管理、批量转换、改元数据都很强，界面信息比较多。官网的 Mac 下载目前只看到 Intel（x64）版本。</p>
<p><strong>Picview</strong>（App Store）：免费，模仿 Windows「照片」的用法，方向键翻页。</p>
<h2>付费</h2>
<p><strong>Lyn</strong>：29.99 美元，15 天试用，带 HDR 和 RAW，更新很勤。<strong>FastRawViewer</strong>：23.99 美元可装两台电脑，自己解 RAW 而不是看内嵌的预览图，有直方图和焦点峰值，适合严肃挑 RAW。<strong>ApolloOne</strong>：有免费版，也有付费版，面向摄影师的挑片和关键词整理，部分功能需要较新的 macOS。</p>
<h2>怎么选</h2>
<ul><li>只是想双击一张后方向键往下翻：Flipic Lens、qView、PicView 都可以，Flipic Lens 最接近 Windows 看图软件的手感。</li><li>主要挑相机 RAW、要看焦点和直方图：FastRawViewer。</li><li>要一个能管理、能批量处理的「大」软件：XnView MP。</li><li>喜欢网格浏览：FlowVision。</li></ul>
<p>说明一下：Flipic Lens 是本站的软件。看图、打星、标记、筛选、导出都免费开源；另有一个可选的付费 Pro，只加了批量整理的功能，大多数人用不上。</p>
<figure>{{shot('filmstrip.webp', 'Flipic Lens 底部缩略图栏与左右翻页')}}<figcaption>Flipic Lens：双击一张，方向键翻完整个文件夹。</figcaption></figure>
<p>想先看 RAW 再决定用哪个软件，步骤见 <a href="/guides/mac-view-raw/">Mac 上怎么快速看 RAW 照片</a>。完整的软件对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""", updated="2026-11-08")

guide("en", "/en/guides/open-source-image-viewers-mac/", "Open-source Mac image viewers (2026)",
      "Open-source image viewers for Mac",
      "Preview can't page through a folder. These open-source Mac image viewers can, checked against their official sites and GitHub in November 2026, with notes on who each one suits.",
      "Seven maintained options, what each is good at, and two to skip",
      f"""<p>Preview only moves between files you opened together, so after you double-click one photo you can't page through the rest of the folder. The viewers below fix that and are all open source. Everything here was checked on 1 November 2026 against each project's site, GitHub releases and licenses; check the project pages for current versions.</p>
<h2>The short list</h2>
<table><thead><tr><th>Viewer</th><th>License</th><th>Good for</th></tr></thead><tbody>
<tr><td>Flipic Lens</td><td>MIT</td><td>Mac-only users who want the Windows-viewer feel: arrow keys through the folder, 0 to zoom to 100% at the pointer, ratings, marks and culling</td></tr>
<tr><td>PicView</td><td>GPL-3.0</td><td>People on both Mac and Windows; a long format list including camera RAW; <code>brew install picview</code></td></tr>
<tr><td><a href="/en/guides/flowvision-alternative/">FlowVision</a></td><td>GPL-3.0</td><td>Browsing a folder as a waterfall grid, with video; a native Swift app</td></tr>
<tr><td>qView</td><td>GPL-3.0</td><td>The most minimal option: just the image and a title bar, arrow keys to page</td></tr>
<tr><td>nomacs</td><td>GPL-3.0</td><td>People who already use it on Windows or Linux; feature-rich, RAW through LibRaw</td></tr>
<tr><td>Oculante</td><td>MIT (parts GPL)</td><td>Speed plus light editing; written in Rust</td></tr>
<tr><td>ImageGlass</td><td>GPL-3.0</td><td>Longtime Windows users; the Mac version just left beta, needs macOS 14 and Apple silicon, and Pro features are paid</td></tr>
</tbody></table>
<h2>Two to skip</h2>
<p>Phew only opens FLIF files and its author says it is no longer maintained. The maintained fork of Sequential hasn't shipped a release since September 2024.</p>
<h2>If open source isn't a requirement</h2>
<p>XnView MP is free for private and educational use and handles 500+ formats, with strong batch and metadata tools. FastRawViewer ($23.99 for two computers) renders RAW data itself with histograms and focus peaking, which makes it the specialist for culling RAW files. Lyn ($29.99) is a polished paid browser with HDR and RAW support.</p>
<h2>How to choose</h2>
<ul><li>You just want to double-click a photo and arrow through the folder: <a href="/en/">Flipic Lens</a>, qView or PicView. Flipic Lens is the closest to IrfanView or Honeyview in feel.</li><li>You mostly cull RAW and need focus and histograms: FastRawViewer.</li><li>You want one big tool that also organizes and converts: XnView MP.</li><li>You like grids: FlowVision.</li></ul>
<p>Disclosure: Flipic Lens is made by the people behind this site. Viewing, ratings, marks, filtering and export are free and MIT-licensed; an optional paid Pro adds batch tools that most people won't need.</p>
<figure>{{shot('filmstrip.webp', 'Flipic Lens thumbnail strip and arrow-key paging')}}<figcaption>Flipic Lens: double-click a photo, then arrow through the folder.</figcaption></figure>
<p>If you are deciding between Photo Mechanic and a lighter viewer, see <a href="/en/guides/photo-mechanic-alternative-mac/">Photo Mechanic alternative for Mac</a>; for the RAW workflow itself, see <a href="/en/guides/view-raw-files-mac/">how to quickly view RAW files on a Mac</a>. The full field is in <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""", updated="2026-11-08")

guide("en", "/en/guides/flowvision-alternative/", "FlowVision vs Flipic Lens: which fits?",
      "FlowVision vs Flipic Lens",
      "FlowVision and Flipic Lens are free, open-source Mac photo viewers. FlowVision browses folders as a grid; Flipic Lens pages one photo at a time, with a grid in Pro.",
      "Two free, open-source viewers with different ideas about browsing",
      f"""<p>FlowVision and Flipic Lens are both free, open-source image viewers for Mac, and they start from different ideas. FlowVision is built around seeing a whole folder at once in a waterfall or grid layout, with video alongside the photos. Flipic Lens is built around one photo at a time, with a thumbnail strip along the bottom; the Pro Workbench adds a grid for a whole shoot. Double-click any image, then use the arrow keys to work through the folder and rate what you want to keep. Neither is a replacement for the other; the right one depends on how you look at photos.</p>
<h2>FlowVision vs Flipic Lens at a glance</h2>
<table><thead><tr><th></th><th>FlowVision</th><th>Flipic Lens</th></tr></thead><tbody>
<tr><td>Price</td><td>Free</td><td>Free; optional Pro for batch tools</td></tr>
<tr><td>License</td><td>GPL-3.0</td><td>MIT</td></tr>
<tr><td>Minimum macOS</td><td>macOS 11.0 or later</td><td>macOS 13 or later</td></tr>
<tr><td>Main view</td><td>Waterfall and grid layouts</td><td>One photo at a time with a thumbnail strip; a grid in the Pro Workbench</td></tr>
<tr><td>Camera RAW</td><td>Yes</td><td>Yes</td></tr>
<tr><td>Built for</td><td>Browsing and organizing folders</td><td>Culling a shoot with ratings and marks</td></tr>
</tbody></table>
<h2>Where FlowVision fits</h2>
<p>FlowVision is the one to try if you think in folders. Its waterfall and grid layouts show many images at different sizes at once, which suits going through a shoot, a download folder or a reference library before deciding what to open. It plays video in the same window, so mixed folders of clips and stills stay in one place. The app also handles file management while you browse: move, copy and rename files, add tags and ratings, and jump between folders with right-click gestures. It is GPL-3.0, needs macOS 11.0 or later, and handles camera RAW.</p>
<h2>Where Flipic Lens fits</h2>
<p><a href="/en/">Flipic Lens</a> is the one to try if you cull by stepping through photos. Open a folder, double-click any photo and press <kbd>←</kbd> or <kbd>→</kbd>; the window moves through the folder one image at a time, with a thumbnail strip along the bottom. Press <kbd>0</kbd> to zoom to 100% at the pointer and check focus, <kbd>1</kbd>–<kbd>5</kbd> to rate, and <kbd>P</kbd> to mark keepers. Ratings are written as standard XMP, so Lightroom, Bridge and Capture One can read them. Cleanup Mode groups similar bursts, exact duplicates, closed eyes and blurry shots on your Mac, and nothing is deleted until you choose Move to Trash. Flipic Lens is MIT-licensed, an 8 MB download, needs macOS 13 or later, and runs on Apple silicon and Intel.</p>
<h2>Which should you pick?</h2>
<p>If you want to see a whole folder at once and keep video in the same view, FlowVision fits better. If you want to open one photo and go forward and back with the arrow keys while rating and marking, Flipic Lens fits better. Both are free and open source, so trying both costs nothing but a download.</p>
<h2>FlowVision facts and links</h2>
<p>FlowVision is at <a href="https://github.com/netdcy/FlowVision">github.com/netdcy/FlowVision</a> and <a href="https://flowvision.app/">flowvision.app</a>. The details above were checked on 7 November 2026 against those two pages: the repository is GPL-3.0, the README lists macOS 11.0 or later, the source handles camera RAW and video, and the latest release is 1.7.6 from 8 September 2026.</p>
<p>For the full field, see <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      title_suffix=False, updated="2026-11-08", published="2026-11-07")


guide("zh", "/guides/mac-view-raw/", "Mac 上怎么快速看 RAW 照片",
      "Mac 快速看 RAW",
      "在 Mac 上双击 RAW 就能用方向键一张张看，按 0 看焦点，按 1–5 打星。也写清 CR3、NEF、ARW 等格式和 RAW+JPG 同名文件的处理。",
      "RAW 也能双击后一张张翻，看焦点、打星，同名 JPG 一起处理",
      f"""<p>把 RAW 文件拷到 Mac 上，用 Flipic Lens 打开所在文件夹，双击任意一张，按 <kbd>←</kbd> <kbd>→</kbd> 就能一张张翻。不用先导入，也不建图库，CR3、NEF、ARW、RAF、DNG 这些常见相机 RAW 都能直接打开。</p>
<p>看到要确认焦点的，把鼠标移到眼睛上按住 <kbd>0</kbd>，就在那里放大到 100%，松手回到整张。想看拍摄参数按 <kbd>I</kbd>，右上角会列出相机、镜头、快门、光圈、ISO 和拍摄时间。</p>
<p>翻页时先出现一张略糊的预览，停下来马上变清晰；按住方向键一直翻也能跟上。不用先导入，所以也没有导入进度条。</p>
<figure>{shot('zoom.webp', 'Flipic Lens 在鼠标处放大到 100% 检查焦点')}<figcaption>按住 0 在鼠标处放大到 100%，松手回到整张。</figcaption></figure>
<h2>先把整个文件夹翻一遍</h2>
<p>打开文件夹后，底部缩略图栏就是整个文件夹。按 <kbd>→</kbd> 看下一张，按 <kbd>←</kbd> 回上一张；排序可以按文件名、拍摄时间、修改时间或文件大小，连拍多的时候按拍摄时间会更顺。</p>
<p>只想快速扫一遍时，按 <kbd>空格</kbd> 让窗口贴合照片比例，再按一次回到原窗口。竖拍的照片会得到一个竖长的窗口，扫起来更顺。</p>
<p>拿不准两张哪张更清楚，按 <kbd>C</kbd> 并排看两张，放大和拖动会同步；四张一起看按 <kbd>⇧C</kbd>。这些都不需要先导入，也不建图库。</p>
<h2>RAW 和 JPG 同名的一对怎么处理</h2>
<p>相机同时存 RAW 和 JPG 时，免费版会把它们显示成两张，但打星、删除、移动、导出按一对处理：给其中一张打星，同名另一张一起有星；删掉一张，另一张跟着走，不会只留下半对。清理模式里也按一张算。</p>
<p>如果不想在列表里看到两张，Pro 可以把同名的 JPG 和 RAW 合并成一张显示，按 <kbd>V</kbd> 切换看哪个版本。这是 Pro 功能；只是看 RAW、打星、挑片的话，免费版够用。</p>
<h2>星级写在旁边，不改 RAW</h2>
<p>RAW 的星级写在旁边同名的 <code>.xmp</code> 文件里，RAW 本身不改。JPEG、HEIC、TIFF 的评分写进文件元数据，不重新压缩。给 RAW 打星以后，Lightroom Classic 和 Capture One 读取 XMP 时能拿到这些星级，具体做法见 <a href="/guides/star-rating-lightroom/">Mac 照片打星，Lightroom 能认吗</a>。</p>
<h2>常见格式和打开方式</h2>
<p>Flipic Lens 支持 ARW、CR2、CR3、NEF、RAF、DNG 等常见相机 RAW，也支持 JPEG、PNG、HEIC、WebP、TIFF、AVIF 等普通图片。系统能解码的其他格式一般也能打开。</p>
<p>想以后双击 RAW 就用 Flipic Lens：在设置（<kbd>⌘,</kbd>）里点「设为默认看图软件」，常见图片格式和相机 RAW 会一次设好；也可以在访达里右键一张 RAW，按住 <kbd>⌥</kbd> 选「始终以此方式打开」› Flipic Lens。</p>
<p>如果你还在挑 Mac 上的看图软件，可以先看 <a href="/guides/mac-image-viewer-recommend/">Mac 看图软件推荐</a>；要一次处理几百张活动照片，流程见 <a href="/guides/cull-event-photos/">活动照片几百张，怎么在 Mac 上快速挑片</a>。</p>""",
      faq=[
          ('Mac 上双击 RAW 用什么打开？',
           '把 Flipic Lens 设为默认看图软件后，双击 RAW 就会用它打开；也可以在访达里右键 RAW，按住 ⌥ 选「始终以此方式打开」› Flipic Lens。'),
          ('RAW 和 JPG 同名会显示两张吗？',
           '免费版会显示两张，但打星、删除、移动、导出按一对处理，清理模式也算一张。Pro 可以把它们合并成一张显示，按 V 切换。'),
          ('看 RAW 会改原文件吗？',
           '只看不会改。打星时 RAW 的评分写在旁边同名的 .xmp 文件里，RAW 本身不动；JPEG、HEIC、TIFF 只改元数据，不重新压缩。'),
      ], title_suffix=False, updated="2026-11-07", published="2026-11-07")

guide("zh", "/guides/star-rating-lightroom/", "Mac 照片打星，Lightroom 能认吗",
      "打星，Lightroom 能认吗",
      "用 Flipic Lens 按 1–5 打星，评分写成 XMP；Lightroom Classic、Capture One 都能读。JPEG 不重压，RAW 写同名 .xmp。",
      "Flipic Lens 打的星写成 XMP，Lightroom Classic 和 Capture One 怎么读",
      f"""<p>能。Flipic Lens 里按 <kbd>1</kbd> 到 <kbd>5</kbd> 给照片打星，评分按 XMP 标准写入。Lightroom Classic 和 Capture One 都支持星级评分，也都能读 XMP 里的元数据，所以你在 Flipic Lens 里挑一遍，回到后期软件不用重新打。</p>
<h2>在 Flipic Lens 里怎么打星</h2>
<p>打开照片所在的文件夹，双击任意一张，按 <kbd>1</kbd> 到 <kbd>5</kbd> 就是一到五星；右键菜单「评分」里可以改成「未评分」。评过分的照片会在窗口底部正中显示星级。要标记「这张要留」，按 <kbd>P</kbd>，标记存成访达标签，不改照片文件。</p>
<p>打完一轮，按 <kbd>⇧P</kbd> 只看标记过的照片，或者用「显示 › 只看星级」只看几星以上。筛出来的照片按 <kbd>⇧⌘E</kbd> 可以一次复制或移动到一个文件夹。</p>
<p>标记和星级是两套东西：星级表示这张有多好，<kbd>P</kbd> 表示这张要留。可以只打星不标记，也可以只标记不打星；两个都做，后面筛选会更灵活。</p>
<figure>{shot('settings.webp', 'Flipic Lens 设置里的评分快捷键')}<figcaption>评分快捷键也能在设置里改。</figcaption></figure>
<h2>星级具体存在哪里</h2>
<p>JPEG、HEIC、TIFF 的评分写进文件本身的元数据，只改信息，不重新压缩。索尼、佳能、尼康等专有 RAW 格式的评分写在旁边同名的 <code>.xmp</code> 文件里，RAW 文件一个字节都不改。同名的 RAW 和 JPG 会一起打分。</p>
<p>这也是为什么换软件不用重打：XMP 是通用的元数据格式，Lightroom Classic 的评分和版权、关键词等信息都用 XMP 保存；Capture One 也能读嵌入的 XMP 和同名的 .XMP sidecar 文件。</p>
<p>移动、导出照片时，同名的 <code>.xmp</code> 会跟着 RAW 一起走，不会把评分留在原来的文件夹。用 <kbd>⇧⌘E</kbd> 导出时也一样。</p>
<h2>Lightroom 和 Capture One 怎么读</h2>
<p>Lightroom Classic 自己就有 1 到 5 星评分，也支持把元数据写进 XMP 或同名的 sidecar 文件。把 Flipic Lens 生成的 <code>.xmp</code> 和 RAW 放在同一个文件夹、保持同名，Lightroom Classic 读 sidecar 时就能拿到评分。</p>
<p>Capture One 在「图像 › 元数据」里可以设置 XMP sidecar 的同步方式。选 Load 会从 sidecar 读入，选 Full Sync 会双向同步；只要 .XMP 文件和 RAW 同名，星级就在里面。</p>
<p>如果一次要挑几百张，建议先按星级过一轮，再用 <kbd>⇧P</kbd> 或星级筛选缩小范围。不要一边挑一边改文件名，先把要留的选出来，导出或交给后期时再整理。</p>
<h2>挑完交给后期</h2>
<p>在 Flipic Lens 设置里选好 Lightroom 或 Capture One，看到要修的照片按 <kbd>⌘E</kbd> 就用它打开；同名的 RAW 也在时，打开的是 RAW。想先看 RAW 怎么快速翻，见 <a href="/guides/mac-view-raw/">Mac 上怎么快速看 RAW 照片</a>；想先把废片清掉，见 <a href="/guides/cull-event-photos/">活动照片几百张，怎么在 Mac 上快速挑片</a>。还在选看图软件的话，可以先看 <a href="/guides/mac-image-viewer-recommend/">Mac 看图软件推荐</a>。</p>""",
      faq=[
          ('打星会改 RAW 原文件吗？',
           '不会。RAW 的评分写在旁边同名的 .xmp 文件里，RAW 本身不改；JPEG、HEIC、TIFF 只改文件里的元数据，不重新压缩。'),
          ('Lightroom 和 Capture One 都能读吗？',
           'Lightroom Classic 和 Capture One 都支持星级和 XMP 元数据；把同名 .xmp 与 RAW 放在一起，打开或导入时就能读到。'),
          ('打星要买 Pro 吗？',
           '不用。打星、按星级筛选、标记、导出都是免费的，Pro 只加批量整理等额外功能。'),
      ], title_suffix=False, updated="2026-11-07", published="2026-11-07")

guide("zh", "/guides/burst-closed-eyes-cleanup/", "连拍、闭眼、拍糊的照片，Mac 上先挑再删",
      "连拍、闭眼、拍糊怎么清理",
      "连拍、闭眼、拍糊的照片不用一张张翻。Flipic Lens 清理模式先在 Mac 本机分好组并推荐保留，删之前还能过一眼，删错了也能撤销。",
      "先让清理模式分好连拍、闭眼、拍糊，再决定删哪些",
      f"""<p>一场活动拍几百张，最花时间的往往不是修图，是从里面挑出能用的几十张。用 Flipic Lens 打开整个文件夹，按 <kbd>⇧⌘K</kbd> 进入清理模式，它先在 Mac 本机把照片过一遍，再让你决定删哪些。</p>
<p>它不是只有活动才用得上。婚礼、聚会、孩子运动会，一次拍几百张的场合都适合；如果照片本来就不多，手动翻页更直接。</p>
<h2>它会把照片分成四类</h2>
<p>清理模式分成相似连拍、内容完全相同的文件、闭眼、模糊或虚焦四类。连拍组里会推荐保留最清楚、没人闭眼的那张，其余默认勾上；闭眼的照片会框出是哪张脸，方便你放大确认。</p>
<p>检测用的是 macOS 自带的 Vision 框架，清晰度、人脸和闭眼都在你自己的 Mac 上算，照片不会上传。它只负责分组和推荐，不替你删。</p>
<figure>{shot('cleanup.webp', 'Flipic Lens 清理模式按相似连拍分组并推荐保留', 1440, 967)}<figcaption>每组标出推荐保留的那张，删之前可以逐个取消。</figcaption></figure>
<h2>删之前过一眼</h2>
<p>自动判断会有误判，尤其是连拍里表情差别很小的时候。点缩略图上的勾可以取消或重新选中，按 <kbd>空格</kbd> 能放大检查。确认以后按「移到废纸篓」，照片会先进废纸篓，不会立刻消失。</p>
<p>删错了按 <kbd>⌘Z</kbd> 可以放回来。同名的 RAW 和 JPG 会当成一张照片处理，不会只删掉一半。</p>
<p>清理模式只做第一轮分组，最后留哪张还是得自己看。把明显的废片去掉以后，剩下的照片再按方向键一张张过，按星级和标记挑，会轻松一些。</p>
<p>检测结果放在 <code>~/Library/Caches/Flipic</code>，删掉也不影响照片；清理模式的检测结果不会写进照片文件夹。重要拍摄还是先备份，再批量删。</p>
<h2>删完再打星，交给后期</h2>
<p>剩下的照片按 <kbd>→</kbd> 一张张翻，按 <kbd>1</kbd> 到 <kbd>5</kbd> 打星，按 <kbd>P</kbd> 标记要留的。挑完按 <kbd>⇧P</kbd> 只看标记过的，或者按星级筛选，再用 <kbd>⇧⌘E</kbd> 一起导出。打星和 Lightroom 的关系见 <a href="/guides/star-rating-lightroom/">Mac 照片打星，Lightroom 能认吗</a>。</p>
<p>清理模式是免费的，不需要 Pro。整个挑片流程可以看 <a href="/guides/cull-event-photos/">活动照片几百张，怎么在 Mac 上快速挑片</a>；RAW 和 JPG 同名时怎么处理，见 <a href="/guides/mac-view-raw/">Mac 上怎么快速看 RAW 照片</a>。还在选软件的话，见 <a href="/guides/mac-image-viewer-recommend/">Mac 看图软件推荐</a>。</p>""",
      faq=[
          ('清理模式收费吗？',
           '免费，不需要 Pro。'),
          ('删掉的照片能找回来吗？',
           '会先进废纸篓，按 ⌘Z 可以放回刚删的照片。'),
          ('RAW 和 JPG 会被分开删吗？',
           '不会。同名的 RAW 和 JPG 算一张，一起处理。'),
      ], title_suffix=False, updated="2026-11-07", published="2026-11-07")

guide("en", "/en/guides/photo-mechanic-alternative-mac/", "Photo Mechanic alternative for Mac: a free culling viewer",
      "Photo Mechanic alternative",
      "Photo Mechanic is a mature paid pro tool with far more features. Flipic Lens is a free, open-source Mac viewer for quick paging, focus checks, stars and marks.",
      "A lighter, free option for paging, focus, stars and marks",
      f"""<p>Photo Mechanic is a mature, paid professional photo browser from Camera Bits. It is built for high-volume ingest, browsing, culling, metadata and upload workflows, and it does far more than <a href="/en/">Flipic Lens</a>. If you mainly need to open a folder, page through photos, check focus, rate and mark, Flipic Lens is a free, open-source alternative for that narrower job.</p>
<h2>What Photo Mechanic is built for</h2>
<p>Photo Mechanic is a full workflow tool. Its own tour highlights copying cards and culling while the files are still being ingested, a contact sheet for browsing, keywords and IPTC metadata, batch copy/delete/rename, side-by-side comparison, and export or upload to galleries and services. It also has a Plus version with an image database for cataloging files across drives.</p>
<p>That breadth is the point. If you shoot for clients and need ingest, metadata, captions and delivery in one place, Photo Mechanic is the more complete tool. It is also paid software, with a free trial; check Camera Bits for current licensing.</p>
<h2>What Flipic Lens covers</h2>
<p>Flipic Lens starts from a folder, not a catalog. Copy the card yourself, double-click any photo, and press <kbd>←</kbd> <kbd>→</kbd> to move through the folder. There is no import step and no library to maintain. That is a smaller promise than Photo Mechanic makes, and it is deliberate.</p>
<p>For culling, the useful keys are all there. Press <kbd>0</kbd> to zoom to 100% at the pointer and check focus. Press <kbd>1</kbd> to <kbd>5</kbd> to rate, <kbd>P</kbd> to mark keepers. Press <kbd>C</kbd> for two photos side by side or <kbd>⇧C</kbd> for four, with zoom and pan synced. Cleanup Mode groups similar bursts, exact duplicates, closed eyes and blurry shots on your Mac before you decide what to delete. Viewing, ratings, marks, side-by-side comparison and Cleanup Mode are free.</p>
<figure>{shot('filmstrip.webp', 'Flipic Lens thumbnail strip and arrow-key paging')}<figcaption>Flipic Lens: open one photo, then page through the folder.</figcaption></figure>
<h2>Where the two differ</h2>
<p>Photo Mechanic is stronger when the job includes ingest automation, detailed metadata, keywording and delivery. Flipic Lens is stronger when you want to open a folder quickly and judge one photo at a time without a catalog. It shows the IPTC headline and caption stored in a file and can translate the caption, but it does not edit metadata. Flipic Lens is also Mac-only, MIT-licensed and an 8 MB download; it needs macOS 13 or later.</p>
<p>Photo Mechanic is not the only heavier option, and Flipic Lens is not trying to replace it. If you already use Photo Mechanic for the parts of the workflow that matter to you, keep it. Use Flipic Lens when you just want to look at the pictures and pick.</p>
<h2>Can you use both?</h2>
<p>Yes. You can keep a full workflow app for ingest and metadata, then open the folder in a lighter viewer for a quick pass. Flipic Lens does not import, copy or catalog your files, and opening a folder does not move anything. Unless you rotate or crop a photo, the only photo data it writes is the rating you set, as standard XMP; marks are stored as Finder tags. Other apps can read the ratings. If you later decide you need the wider workflow, you can go back without a migration.</p>
<p>For the broader field, see <a href="/en/guides/open-source-image-viewers-mac/">open-source image viewers for Mac</a>. For a culling routine that starts with rejects, see <a href="/en/guides/cull-photos-on-mac/">how to cull hundreds of event photos on a Mac</a>. The full comparison is at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Is Flipic Lens a drop-in replacement for Photo Mechanic?',
           'No. Photo Mechanic covers ingest, metadata, keywording and delivery; Flipic Lens is a smaller viewer for paging, focus, ratings, marks and culling. If you need the full workflow, keep Photo Mechanic.'),
          ('Is Flipic Lens free?',
           'Yes, free and open source (MIT). An optional paid Pro adds batch tools; viewing, ratings, marks, side-by-side comparison and Cleanup Mode are free.'),
          ('Does Flipic Lens import or catalog photos?',
           'No. It reads the folder you open and does not build a library or copy the files.'),
      ], title_suffix=False, updated="2026-11-14", published="2026-11-07")

guide("en", "/en/guides/view-raw-files-mac/", "How to quickly view RAW files on a Mac",
      "View RAW files on Mac",
      "View a folder of camera RAW files on a Mac with the arrow keys, check focus at 100%, rate with 1–5 and handle same-name RAW+JPG pairs in one place.",
      "Open a folder of RAW files, page with the arrows and check focus",
      f"""<p>Copy the RAW files to a folder on your Mac, open that folder in Flipic Lens, double-click any photo and use <kbd>←</kbd> <kbd>→</kbd> to move through the folder. There is no import step and no catalog. Flipic Lens opens common camera RAW formats including ARW, CR2, CR3, NEF, RAF and DNG.</p>
<h2>Quick Look or a folder viewer</h2>
<p>Quick Look is a quick way to glance at a few files: select them in Finder, press <kbd>Space</kbd>, and use the arrow keys to browse the selection. It is useful when you already know which files you want. The limit is that you are browsing a selection, not the whole folder.</p>
<p>Quick Look is also temporary: close the window and the selection is gone. A folder viewer keeps the folder open, so you can come back to the same place after a break.</p>
<p>A folder viewer fits when you want to start at one photo and keep going. Flipic Lens reads the folder as it is, so the next photo is whatever comes next in the folder, not the next item you happened to select (the Preview and Quick Look routes are in <a href="/en/guides/mac-preview-next-image/">how to go to the next photo on a Mac</a>). You can sort by name, date taken, date modified or file size.</p>
<h2>Check focus before you rate</h2>
<p>Point at the eyes or another detail and hold <kbd>0</kbd> to zoom to 100% there. Let go to fit the photo. Press <kbd>I</kbd> for the camera, lens, shutter speed, aperture, ISO and date taken. When two frames look close, press <kbd>C</kbd> to compare two side by side, or <kbd>⇧C</kbd> for four.</p>
<p>If you shoot bursts, comparing two frames saves going back and forth between them and trying to remember the last. The compare view keeps the same zoom and position, which is exactly what you need for eyes and expressions.</p>
<p>Then rate with <kbd>1</kbd> to <kbd>5</kbd> and mark keepers with <kbd>P</kbd>. Ratings are written as standard XMP: into the file for JPEG, HEIC and TIFF, and into a same-name <code>.xmp</code> sidecar for proprietary RAW. The RAW file itself is not changed.</p>
<figure>{shot('zoom.webp', 'Flipic Lens zooming to 100% at the pointer to check focus')}<figcaption>Hold 0 to check focus; let go to fit.</figcaption></figure>
<h2>A simple RAW routine</h2>
<ol><li>Copy the card to a folder. Do not rename anything yet.</li><li>Open the folder in <a href="/en/">Flipic Lens</a> and page from the first frame, pressing <kbd>0</kbd> on anything that looks soft.</li><li>Rate the keepers with <kbd>1</kbd> to <kbd>5</kbd>, mark the ones you want to edit with <kbd>P</kbd>, then deal with the rejects.</li></ol>
<h2>RAW and JPG with the same name</h2>
<p>If your camera writes both a RAW and a JPG, the free version shows them as two photos. They are still treated as a pair when you rate, delete, move or export them, and Cleanup Mode counts them as one. The Pro version can show the pair as one photo; press <kbd>V</kbd> to switch between the RAW and the JPG.</p>
<p>To review a burst, see <a href="/en/guides/compare-photos-side-by-side-mac/">how to compare similar photos side by side on Mac</a>. To make Flipic Lens the default viewer, open Settings (<kbd>⌘,</kbd>) and click Make Default Viewer; common image formats and camera RAW are set in one go.</p>
<p>If you are choosing a viewer, the wider list is in <a href="/en/guides/open-source-image-viewers-mac/">open-source image viewers for Mac</a>. If you are culling a whole shoot, the event workflow is in <a href="/en/guides/cull-photos-on-mac/">how to cull hundreds of event photos on a Mac</a>.</p>""",
      faq=[
          ('Does viewing a RAW change the file?',
           'No. Viewing only reads it. Ratings on proprietary RAW go into a same-name .xmp sidecar; the RAW itself is not changed.'),
          ('Can I see RAW and JPG as one photo?',
           'The free version shows them as two but treats them as a pair when rating, deleting, moving and exporting. Pro can merge the pair and switch with V.'),
          ('Which RAW formats does Flipic Lens open?',
           'Common camera RAW including ARW, CR2, CR3, NEF, RAF and DNG. Other formats macOS can decode generally open too.'),
      ], title_suffix=False, updated="2026-11-07", published="2026-11-07")

guide("en", "/en/guides/compare-photos-side-by-side-mac/", "How to compare similar photos side by side on Mac",
      "Compare photos side by side",
      "Compare two or four similar shots side by side on a Mac, with zoom and pan synced, to check focus and expressions before you pick a keeper.",
      "Two or four frames at once, with zoom and pan synced",
      f"""{shot("compare-focus-en.webp", "Two frames of the same swan side by side in Flipic Lens, zoomed to the same spot: the left one is sharp, the right one is out of focus", 1600, 1075, eager=True)}
<p>To compare photos side by side on a Mac, press <kbd>C</kbd> in <a href="/en/">Flipic Lens</a>: two frames sit next to each other at the same zoom, so the one that missed focus is obvious, like the right-hand frame above.</p>
<p>Open the folder in Flipic Lens, find the first frame you want to compare and press <kbd>C</kbd>. That puts two photos side by side. Press <kbd>⇧C</kbd> to compare four at once. Zooming and dragging move every pane together by default, so you are looking at the same spot in each frame.</p>
<h2>Two or four?</h2>
<p>Two works well when you are deciding between the last two frames of a burst: one may have the sharper eye, the other a stronger expression. Four is useful earlier, when you have a short run of similar shots and want to see the whole run before narrowing down.</p>
<p>A useful habit is to compare first, then rate. If you rate one frame before looking at its neighbour, you may keep the first one out of habit rather than because you compared it.</p>
<p>The compare view is for judging, not for editing. It does not merge files or create a new copy. You are still looking at the originals in the folder, and you can rate or delete from the same window.</p>
<h2>How to check focus across frames</h2>
<p>Press <kbd>0</kbd> to zoom to 100% at the pointer. Because the panes stay in sync, the same area stays in view when you move between them. If one pane needs a small adjustment without moving the others, hold <kbd>⌥</kbd> while you drag it. Press <kbd>⇧L</kbd> to turn syncing off, and press it again to turn it back on.</p>
<p>Use <kbd>←</kbd> <kbd>→</kbd> to move through the folder and load another pair or set. When you have a keeper, press <kbd>1</kbd> to <kbd>5</kbd> to rate it or <kbd>P</kbd> to mark it. Press <kbd>⌘⌫</kbd> to move a reject to the Trash.</p>
<h2>A simple compare routine</h2>
<ol><li>Open the folder and find the first frame of a short run.</li><li>Press <kbd>C</kbd> for two or <kbd>⇧C</kbd> for four, then press <kbd>0</kbd> to check the eyes.</li><li>Rate the keeper, page on with <kbd>→</kbd>, and repeat for the next run.</li></ol>
<h2>When side by side helps most</h2>
<p>It helps with bursts where the difference is a blink, a slight turn of the head, or focus that lands on the ear instead of the eye. Looking at one photo at a time makes those differences hard to hold in memory; two panes at the same zoom make them easier to see.</p>
<p>It also helps with a sequence of group photos, where you want the frame where everyone looks awake and nobody is half-turned. Four panes are enough for most short sequences; longer runs are easier to handle by paging and rating first.</p>
<p>Side-by-side comparison is free, along with viewing, ratings, marks, filtering, export and Cleanup Mode. If you want the culling routine around it, see <a href="/en/guides/cull-photos-on-mac/">how to cull hundreds of event photos on a Mac</a>. For the RAW workflow, see <a href="/en/guides/view-raw-files-mac/">how to quickly view RAW files on a Mac</a>, and for the wider field, see <a href="/en/guides/open-source-image-viewers-mac/">open-source image viewers for Mac</a>.</p>""",
      faq=[
          ('Is side-by-side comparison free?',
           'Yes, along with viewing, ratings, marks, filtering, export and Cleanup Mode.'),
          ('Can I compare more than two photos?',
           'Press C for two photos or Shift-C for four.'),
          ('Why did only one pane move?',
           'Hold Option (⌥) to nudge one pane on its own; Shift-L turns syncing off and on.'),
      ], title_suffix=False, updated="2026-11-18", published="2026-11-07")



guide("en", "/en/guides/adobe-bridge-alternative-mac/", "Adobe Bridge vs Flipic Lens: which one for culling?",
      "Bridge vs Flipic Lens",
      "Adobe Bridge is a free asset browser with deep metadata and batch tools. Flipic Lens is a small Mac culler that opens a folder and pages with the arrow keys.",
      "Bridge for metadata and batch work, Flipic Lens for a quick folder cull",
      f"""<p>Choose Adobe Bridge if you want a free asset browser with deep metadata editing, keywords, collections and batch tools inside the Adobe ecosystem. Choose <a href="/en/">Flipic Lens</a> if you want to open a folder, page through photos with the arrow keys, check focus and rate them without a catalog. You can use both: Bridge for metadata and batch work, Flipic Lens for a quick culling pass.</p>
<table><thead><tr><th></th><th>Adobe Bridge</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Free</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>Folder browser; optional Photo Downloader; no catalog required</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>Opens RAW in Adobe Camera Raw from Bridge</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>Star ratings in XMP metadata</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Grid and preview; synced two-up not listed on its site</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Not listed on its official site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS and Windows</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where Adobe Bridge is stronger</h2>
<ul><li><strong>Metadata and asset management.</strong> Bridge edits metadata, adds keywords, labels and ratings, and finds files with filters, collections and metadata search.</li><li><strong>Adobe Camera Raw.</strong> Bridge opens RAW files in Camera Raw and sits next to Photoshop and the rest of Creative Cloud.</li><li><strong>Batch work.</strong> Batch rename and batch export, plus PDF contact sheets and publishing to Adobe Stock or Portfolio.</li></ul>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>No import step.</strong> Open the folder, double-click a photo and press the arrow keys. There is no catalog to create or maintain.</li><li><strong>Focus and comparison.</strong> Press 0 to zoom to 100% at the pointer; press C for two photos or Shift-C for four, with zoom and pan synced.</li><li><strong>Ratings and marks in the file.</strong> 1 to 5 stars are written as standard XMP, with a same-name .xmp sidecar for proprietary RAW. P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of similar bursts, duplicates, closed eyes and blurry shots. Nothing is deleted until you choose Move to Trash.<br><strong>Small and local.</strong> An 8 MB MIT-licensed Mac app that keeps photos on your Mac. Pro is a one-time purchase with a 7-day trial; the Workbench adds a project grid.</p>
<h2>Using them together</h2>
<p>Use Bridge when the job is metadata, keywords, Adobe Camera Raw or batch delivery. Use Flipic Lens when you want to open the same folder and cull without importing. Flipic Lens writes standard XMP ratings, so the ratings can travel with the files; Bridge remains the place for the heavier metadata work.</p>
<p>See the full comparison at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Is Adobe Bridge free?',
           'Yes. Adobe offers Bridge as a free download, separate from the paid Creative Cloud apps.'),
          ('Do I need Photoshop to use Bridge?',
           'No. Bridge is a standalone file browser and asset manager; it integrates with Adobe apps when you use them.'),
          ('Can both Bridge and Flipic Lens rate photos?',
           'Yes. Both can apply star ratings; Flipic Lens writes them as standard XMP so other apps can read them.'),
          ('Which should I use for culling?',
           'Use Bridge if metadata, keywords and Adobe batch work are part of the same pass. Use Flipic Lens if you want a simple folder view, arrow-key paging and a first cull without a catalog.'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("en", "/en/guides/fastrawviewer-alternative-mac/", "FastRawViewer vs Flipic Lens: which RAW tool fits?",
      "FastRawViewer vs Flipic Lens",
      "FastRawViewer reads RAW data for histograms, exposure and focus peaking. Flipic Lens is a free folder viewer for paging, ratings and culling.",
      "RAW-data checks in FastRawViewer, quick culling in Flipic Lens",
      f"""<p>Choose FastRawViewer if you need to judge the sensor-level RAW data before demosaic: a true RAW histogram, raw highlight headroom, Shadow Boost and exposure compensation checks. Choose <a href="/en/">Flipic Lens</a> if you want a free, lighter Mac folder culler with display-referred histogram (<kbd>H</kbd>), clipping (<kbd>J</kbd>), focus peaking (<kbd>K</kbd>), camera AF point (<kbd>A</kbd>), synced side-by-side compare, XMP ratings &amp; color labels, Cleanup Mode and external drive SSD caching. They can sit in the same workflow: FastRawViewer for raw-headroom checks, Flipic Lens for the broader selection.</p>
<table><thead><tr><th></th><th>FastRawViewer</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Paid license</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>No catalog; browse folders directly</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW &amp; inspection</td><td>Decodes sensor RAW data; true RAW histogram, Shadow Boost, per-channel view, focus peaking</td><td>Opens camera RAW; 0 zooms to 100%; display RGB histogram (H), clipping (J), focus peaking (K), camera AF point (A)</td></tr><tr><td>Ratings &amp; labels</td><td>Ratings and labels in XMP sidecars</td><td>1–5 stars &amp; color labels as standard XMP; RAW uses same-name .xmp sidecars</td></tr><tr><td>Side-by-side compare</td><td>Grid and single-file view; synced two-up not listed on its site</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Not listed on its official site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS and Windows</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where FastRawViewer is stronger</h2>
<ul><li><strong>Sensor-level RAW data, not an embedded preview.</strong> It renders the RAW directly and computes a true RAW-data histogram and statistics before tone mapping.</li><li><strong>Exposure recovery tools.</strong> Shadow Boost, per-channel view and exposure compensation help you judge how many stops a RAW converter can still pull back.</li><li><strong>Cross-platform RAW+JPEG workflow.</strong> Runs on both macOS and Windows without a catalog.</li></ul>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>Simple paging &amp; everyday inspection.</strong> Double-click one photo and use the arrow keys; press <kbd>H</kbd> for RGB histogram, <kbd>J</kbd> for clipping, <kbd>K</kbd> for focus peaking, <kbd>A</kbd> for camera AF point, and <kbd>0</kbd> to zoom to 100% at the pointer.</li><li><strong>Synced comparison &amp; external drive cache.</strong> C and Shift-C compare two or four frames with synced zoom and pan; external hard drive previews cache to your Mac’s internal SSD.</li><li><strong>Ratings &amp; color labels in standard XMP.</strong> 1 to 5 stars and color labels write standard XMP (sidecar for proprietary RAW); P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of bursts, duplicates, closed eyes and blur, with you deciding what to delete.<br><strong>Small and local.</strong> About 8.4 MB, MIT-licensed on Mac; Pro is a one-time purchase with a 7-day trial adding the Workbench grid, custom .cube 3D LUTs and client filename list matching.</p>
<h2>Using them together</h2>
<p>Open a shoot in FastRawViewer when you need a true pre-demosaic RAW histogram to check whether clipped highlights can still be recovered. Use Flipic Lens for the broader culling pass: page, check focus, rate, color-label and let Cleanup Mode group the obvious rejects. Both write standard XMP, so pick one app for the rating pass to keep sidecars predictable.</p>
<p>See the full comparison at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Is FastRawViewer free?',
           'No. It is a paid license with a fully functional 30-day trial; check LibRaw for current licensing.'),
          ('How is Flipic Lens’s histogram different from FastRawViewer’s?',
           'FastRawViewer computes a sensor-level RAW-data histogram before tone mapping so you can judge true highlight recovery headroom. Flipic Lens computes a fast display-referred RGB & luma histogram (H) plus clipping zebras (J), focus peaking (K) and camera AF point (A) on the rendered image.'),
          ('Can I use FastRawViewer and Flipic Lens together?',
           'Yes. Use FastRawViewer for RAW-data exposure checks and Flipic Lens for paging, ratings, marks and Cleanup Mode.'),
          ('Do both write XMP ratings and labels?',
           'Yes. Both write standard XMP ratings and color labels, using same-name .xmp sidecars for proprietary RAW.'),
      ], title_suffix=False, updated="2026-11-22", published="2026-11-08")

guide("en", "/en/guides/xnview-mp-alternative-mac/", "XnView MP vs Flipic Lens: which viewer fits?",
      "XnView MP vs Flipic Lens",
      "XnView MP brings a long format list, batch tools and an optional catalog on Mac, Windows and Linux. Flipic Lens is a Mac culler for folders and XMP ratings.",
      "XnView MP for formats and batch, Flipic Lens for a quick cull",
      f"""<p>Choose XnView MP if you need a cross-platform viewer and organizer with a very long format list, batch conversion, rename tools and an optional catalog. Choose <a href="/en/">Flipic Lens</a> if you mainly want to open a folder, page with the arrow keys, check focus and rate a shoot without a catalog. You can keep XnView MP for conversion and organizing, and use Flipic Lens for the first cull.</p>
<table><thead><tr><th></th><th>XnView MP</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Free for private, educational, public and non-profit use; paid license for commercial use</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>Folder browser; optional catalog</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>Views camera RAW; not a RAW development module</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>XMP sidecars, ratings exchanged with Lightroom and Bridge</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Image Compare up to 4 images</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Not listed on its official site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS, Windows and Linux</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where XnView MP is stronger</h2>
<ul><li><strong>Format breadth.</strong> It opens a long list of image and camera RAW formats, plus PDF, DICOM and more.</li><li><strong>Batch tools.</strong> Batch convert, batch rename and a batch processing module shared with XnConvert.</li><li><strong>Cross-platform and catalog.</strong> macOS, Windows and Linux, with an optional SQLite catalog for searching ratings, labels, keywords and metadata.</li></ul>
<p><strong>Image Compare.</strong> Compare up to four images in one view.</p>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>No catalog to manage.</strong> Open the folder and start paging; no import and no library.</li><li><strong>Focus and comparison.</strong> 0 zooms to 100% at the pointer; C and Shift-C compare two or four photos with synced zoom and pan.</li><li><strong>Ratings in standard XMP.</strong> 1 to 5 stars, with a same-name .xmp sidecar for proprietary RAW; P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of similar bursts, duplicates, closed eyes and blur, with you deciding what goes.<br><strong>Small, free and local.</strong> An 8 MB MIT-licensed Mac app. Pro is a one-time purchase with a 7-day trial and adds the Workbench grid.</p>
<h2>Using them together</h2>
<p>Use XnView MP for format conversion, batch rename, catalog searches and cross-platform work. Use Flipic Lens when you want to sit in one folder and cull. Both can write XMP ratings, so choose one app for the rating pass if you want to keep the sidecars simple.</p>
<p>See the full comparison at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Is XnView MP free?',
           'It is free for private, educational, public and non-profit use. Commercial use in a company requires a paid license.'),
          ('Does XnView MP open more formats than Flipic Lens?',
           'Yes. XnView MP has a very broad format list, including PDF, DICOM and many camera RAW formats.'),
          ('Do I need the XnView catalog?',
           'No. You can browse folders without it; the catalog is optional and adds search across a large collection.'),
          ('Can I use XnView MP and Flipic Lens together?',
           'Yes. Use XnView MP for conversion and organizing, and Flipic Lens for a quick folder cull.'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("en", "/en/guides/apolloone-alternative/", "ApolloOne vs Flipic Lens: two Mac photo viewers",
      "ApolloOne vs Flipic Lens",
      "ApolloOne offers metadata editing, stacks, split view, HDR and quick edits without importing. Flipic Lens is a free, open-source Mac culler with Cleanup Mode.",
      "ApolloOne for metadata and edits, Flipic Lens for the first cull",
      f"""<p>Choose ApolloOne if you want a Mac-native viewer with full metadata editing, IPTC keywords, split-view comparison, stacks, HDR and quick edits, all without importing. Choose <a href="/en/">Flipic Lens</a> if you want a smaller, free, open-source app focused on paging, focus checks, ratings and Cleanup Mode. You can use ApolloOne for metadata and edits, and Flipic Lens for the first cull.</p>
<table><thead><tr><th></th><th>ApolloOne</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Free edition; paid Max Edition with subscription or perpetual license</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>No import; reads folders</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>RawBridge engine; RAW, HEIF, TIFF and more</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>Star ratings, color labels and Finder tags written as XMP</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Split-view comparison</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Auto-Stack and Focus Score; closed-eye detection not listed on its site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where ApolloOne is stronger</h2>
<ul><li><strong>Metadata and keywords.</strong> Full EXIF and IPTC editing, hierarchical keywords and code replacements written as XMP.</li><li><strong>More viewing tools.</strong> Tabs and windows, split-view comparison, HDR display and export, video playback and non-destructive Quick Edit.</li><li><strong>Burst organization.</strong> Stacks and Auto-Stack collapse a burst into one thumbnail, while Focus Score helps compare sharpness.</li></ul>
<p><strong>Batch work.</strong> Batch rename and conversion are built in.</p>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>Simple and open source.</strong> An 8 MB MIT-licensed Mac app with no import and no catalog.</li><li><strong>Culling without setup.</strong> Double-click a photo, arrow through the folder, press 0 to check focus, C or Shift-C to compare, 1 to 5 to rate and P to mark.</li><li><strong>Ratings and marks in standard places.</strong> Stars are standard XMP with a same-name .xmp sidecar for proprietary RAW; P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of bursts, duplicates, closed eyes and blur, with you deciding what to delete.<br><strong>Pro when needed.</strong> The Workbench adds a project grid, zoom to the eyes, content and text search, and more, as a one-time purchase with a 7-day trial.</p>
<h2>Using them together</h2>
<p>Use ApolloOne when you need IPTC editing, keywords, HDR or a quick non-destructive edit. Use Flipic Lens when the job is to open a folder and make a first selection. Flipic Lens shows the IPTC caption stored in a file and can crop and straighten, but it does not edit metadata or adjust color. Both write ratings as XMP, so decide which app owns the rating pass if keeping sidecars tidy matters to you.</p>
<p>See the full comparison at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Is ApolloOne free?',
           'There is a free edition. The Max Edition is a paid upgrade with a 14-day trial; subscriptions and perpetual licenses are offered.'),
          ('Does ApolloOne import photos?',
           'No. Its own description says it works without importing a single file.'),
          ('Which app finds closed eyes?',
           "Flipic Lens's Cleanup Mode groups closed eyes, blur, bursts and duplicates on your Mac. ApolloOne documents stacks and Focus Score, not closed-eye detection."),
          ('Can I use both?',
           'Yes. ApolloOne for metadata, HDR and quick edits; Flipic Lens for a quick, catalog-free cull.'),
      ], title_suffix=False, updated="2026-11-14", published="2026-11-08")

guide("en", "/en/guides/cull-before-lightroom/", "Cull before Lightroom: why add another app?",
      "Cull before Lightroom",
      "Already use Lightroom Classic? A first cull in Flipic Lens avoids importing rejects, keeps ratings in XMP and sends only the keepers into the catalog.",
      "Skip the import of rejects; rate first, import keepers",
      f"""<p>If you already use Lightroom Classic, you can import everything and cull there. But import builds a catalog record for every photo, including the ones you will reject. Culling first in <a href="/en/">Flipic Lens</a> lets you open the folder, rate and mark, then import only the keepers. Lightroom Classic also has Assisted Culling, which sorts photos by eye and subject sharpness, open eyes and exposure; it is a good option if you are happy to cull inside the catalog. Use Flipic Lens for the first pass when you would rather not catalog the rejects, and Lightroom Classic for editing and the catalog.</p>
<table><thead><tr><th></th><th>Lightroom Classic</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Subscription</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>Requires import into a catalog</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>RAW processing through Camera Raw</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>Catalog metadata, written to XMP or sidecars</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Compare view for two; Survey view for more</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Assisted Culling scores subject and eye sharpness, eyes open and exposure, in the Library module and the Import window (<a href="https://www.adobe.com/learn/lightroom-cc/web/ai-assisted-culling-lightroom">Adobe</a>)</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS and Windows</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where Lightroom Classic is stronger</h2>
<ul><li><strong>Editing and RAW processing.</strong> Develop controls, local adjustments, presets, masks and the rest of the Lightroom toolset.</li><li><strong>The catalog.</strong> Collections, keywords, smart collections, history and search across a long-term library.</li><li><strong>Output.</strong> Prints, books, slideshows, web galleries and export presets.</li></ul>
<p><strong>Compare and survey.</strong> Compare view for two photos and Survey view for a larger set.</p>
<h2>Where Flipic Lens fits before Lightroom</h2>
<ul><li><strong>No import for the rejects.</strong> Open the folder and page with the arrow keys; there is no catalog entry to remove later.</li><li><strong>Focus and compare.</strong> 0 zooms to 100% at the pointer; C and Shift-C compare two or four frames with synced zoom and pan.</li><li><strong>Ratings that Lightroom can read.</strong> 1 to 5 stars are standard XMP, with a same-name .xmp sidecar for proprietary RAW. Lightroom Classic reads XMP metadata and sidecars.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of bursts, duplicates, closed eyes and blur; nothing is deleted until you choose Move to Trash.<br><strong>Pro if you need a project grid.</strong> The Workbench adds a grid per shoot and other pro tools, as a one-time purchase with a 7-day trial.</p>
<h2>A simple cull-first flow</h2>
<p>Copy the card to a folder. Open it in Flipic Lens, page through, check focus, rate and mark. Use Cleanup Mode for the obvious rejects if the shoot is large. Then import only the marked or rated photos into Lightroom Classic. The XMP ratings and sidecars travel with the files, so Lightroom sees the stars when it imports.</p>
<p>See the full comparison at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Do I have to import every photo into Lightroom before culling?',
           'No. You can cull in Flipic Lens first and import only the keepers into Lightroom Classic.'),
          ('Will Lightroom Classic read Flipic Lens ratings?',
           'Yes. Flipic Lens writes star ratings as standard XMP, and Lightroom Classic reads XMP metadata and same-name sidecar files.'),
          ('Does this work for JPEG and HEIC too?',
           'Yes. Flipic Lens writes ratings into JPEG, HEIC and TIFF metadata, and uses a sidecar for proprietary RAW.'),
          ('Can I still edit the keepers in Lightroom?',
           'Yes. Import the keepers, or set Lightroom as the editor in Flipic Lens and press Cmd-E on the current photo.'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("zh", "/guides/adobe-bridge-mac/", "Bridge 和 Flipic Lens 怎么选",
      "Bridge 和 Flipic Lens 怎么选",
      "Adobe Bridge 是免费的素材浏览器，元数据和批处理很完整；Flipic Lens 是不用导入、打开文件夹就用方向键翻的 Mac 挑片工具。这篇写清各自适合谁。",
      "Bridge 管元数据和批处理，Flipic Lens 做第一轮挑片",
      f"""<p>选 Bridge，如果你要的是免费的素材浏览器、完整的元数据和关键词、收藏夹和批处理，而且工作流在 Adobe 里。选 Flipic Lens，如果你想打开文件夹就用方向键翻、看焦点、打星，不建图库。两个可以一起用：Bridge 管元数据和批量，Flipic Lens 做第一轮挑片。</p>
<table><thead><tr><th></th><th>Adobe Bridge</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>价格模式</td><td>免费</td><td>免费；可选一次买断的 Pro</td></tr><tr><td>要不要导入或建库</td><td>文件夹浏览；可选 Photo Downloader；不需要建库</td><td>不导入、不建库，直接读文件夹</td></tr><tr><td>看 RAW</td><td>从 Bridge 用 Adobe Camera Raw 打开</td><td>直接打开相机 RAW；按 0 看 100% 焦点</td></tr><tr><td>星级存在哪</td><td>星级写进 XMP 元数据</td><td>1 到 5 星写标准 XMP；RAW 写同名 .xmp</td></tr><tr><td>并排比较</td><td>网格和预览；官网未列出同步对比</td><td>C 两张、⇧C 四张，缩放同步</td></tr><tr><td>闭眼 / 模糊 / 连拍</td><td>官网未列出</td><td>有：清理模式在本机分连拍、重复、闭眼、模糊</td></tr><tr><td>平台</td><td>macOS 和 Windows</td><td>macOS 13 或更新</td></tr><tr><td>开源</td><td>否</td><td>是，MIT</td></tr></tbody></table>
<h2>Bridge 更强的地方</h2>
<ul><li><strong>元数据和素材管理。</strong> 改元数据、加关键词、标签和星级，用筛选、收藏夹和元数据搜索找文件。</li><li><strong>Adobe Camera Raw。</strong> 从 Bridge 把 RAW 交给 Camera Raw，和 Photoshop、Creative Cloud 连在一起。</li><li><strong>批处理。</strong> 批量重命名、批量导出、PDF 联系表，也能发 Adobe Stock 或 Portfolio。</li></ul>
<h2>Flipic Lens 更适合的地方</h2>
<ul><li><strong>不用导入。</strong> 打开文件夹，双击一张，方向键就翻；没有图库要建，也没有导入步骤。</li><li><strong>看焦点和并排比较。</strong> 按 0 在鼠标处放大到 100%；按 C 两张、⇧C 四张，缩放和拖动同步。</li><li><strong>星级和标记落在文件里。</strong> 1 到 5 星写标准 XMP，专有 RAW 写同名 .xmp；P 标记是访达标签。</li></ul>
<p><strong>清理模式。</strong> 免费，在本机分相似连拍、重复、闭眼和模糊；你按「移到废纸篓」之前不会删。<br><strong>小、免费、不用账号。</strong> 约 8 MB，MIT 开源。Pro 一次买断，下载后可以先试用 7 天，工作台多一个项目宫格。</p>
<h2>一起用</h2>
<p>要写关键词、改元数据、跑 Camera Raw 或做批量交付，用 Bridge。要在同一个文件夹里先挑一遍，用 Flipic Lens。Flipic Lens 写的是标准 XMP 星级，文件带得走；更重的元数据工作还是回 Bridge 做。</p>
<p>完整对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""",
      faq=[
          ('Adobe Bridge 免费吗？',
           '免费。Adobe 提供 Bridge 的免费下载，和付费的 Creative Cloud 应用是分开的。'),
          ('用 Bridge 一定要装 Photoshop 吗？',
           '不用。Bridge 本身是独立的文件浏览器和素材管理工具，装了 Adobe 应用时会和它们配合。'),
          ('Bridge 和 Flipic Lens 都能打星吗？',
           '都能。Flipic Lens 把星级写成标准 XMP，其他软件可以读。'),
          ('挑片用哪个？',
           '要同时改元数据、关键词、跑 Adobe 批处理，用 Bridge；只想打开文件夹翻一遍、看焦点、打星，用 Flipic Lens。'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("zh", "/guides/photo-mechanic-mac/", "Photo Mechanic 的 Mac 替代",
      "Photo Mechanic 的 Mac 替代",
      "Photo Mechanic 是成熟的付费专业工具，强在拷卡、IPTC、关键词和交付；Flipic Lens 是不导入、用方向键翻页挑片的免费 Mac 软件。",
      "Photo Mechanic 管拷卡和交付，Flipic Lens 管快速挑片",
      f"""<p>Photo Mechanic 适合要把拷卡、浏览、挑片、IPTC、关键词和交付放在一条流程里的人；它成熟，覆盖的流程更长。Flipic Lens 适合只想打开一个文件夹，用方向键翻、看焦点、打星、标记的人。两个可以一起用，也可以只留一个。</p>
<table><thead><tr><th></th><th>Photo Mechanic</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>价格模式</td><td>付费；订阅或永久授权</td><td>免费；可选一次买断的 Pro</td></tr><tr><td>要不要导入或建库</td><td>按文件夹浏览；可选拷卡；Plus 版带图库</td><td>不导入、不建库，直接读文件夹</td></tr><tr><td>看 RAW</td><td>可以预览 RAW，再交给后期软件</td><td>直接打开相机 RAW；按 0 看 100% 焦点</td></tr><tr><td>星级存在哪</td><td>写在 XMP / IPTC 元数据里</td><td>1 到 5 星写标准 XMP；RAW 写同名 .xmp</td></tr><tr><td>并排比较</td><td>支持并排比较</td><td>C 两张、⇧C 四张，缩放同步</td></tr><tr><td>闭眼 / 模糊 / 连拍</td><td>官网未列出</td><td>有：清理模式在本机分连拍、重复、闭眼、模糊</td></tr><tr><td>平台</td><td>macOS 和 Windows</td><td>macOS 13 或更新</td></tr><tr><td>开源</td><td>否</td><td>是，MIT</td></tr></tbody></table>
<h2>Photo Mechanic 更强的地方</h2>
<ul><li><strong>拷卡和导入。</strong> 从多张卡拷照片，边拷边看缩略图，边挑边打标签。</li><li><strong>元数据和 IPTC。</strong> 标题、版权、关键词、Code Replacements，批量改元数据。</li><li><strong>完整的交付流程。</strong> 批量重命名、联系表、并排比较，直接发邮件或传到图库服务。</li></ul>
<p><strong>Plus 版的图库。</strong> 需要跨硬盘管理大量照片时，Plus 版多了图像数据库。</p>
<h2>Flipic Lens 更适合的地方</h2>
<ul><li><strong>打开就能挑。</strong> 不导入，不建图库，双击一张就按方向键翻。</li><li><strong>看焦点和比较。</strong> 按 0 在鼠标处放大到 100%；C 两张、⇧C 四张，缩放同步。</li><li><strong>星级和标记。</strong> 1 到 5 星写标准 XMP，专有 RAW 写同名 .xmp；P 标记存成访达标签。</li></ul>
<p><strong>清理模式。</strong> 免费，在本机分连拍、重复、闭眼和模糊，删哪些还是你决定。<br><strong>小、免费、不用账号。</strong> 约 8 MB，MIT 开源。Pro 一次买断，带 7 天试用，工作台有项目宫格。</p>
<h2>一起用</h2>
<p>要拷卡、写 IPTC、批量改关键词、直接交付，用 Photo Mechanic。照片已经在硬盘上、只想先挑一遍，就用 Flipic Lens。Flipic Lens 能显示文件里写的 IPTC 标题和说明，说明还能翻译，但它不编辑元数据。两边的星级都走 XMP，但建议固定一个软件负责打星，免得 sidecar 被两边反复改。</p>
<p>完整对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""",
      faq=[
          ('Photo Mechanic 有免费版吗？',
           '没有免费版，提供试用；授权可以订阅，也可以买永久授权，具体看 Camera Bits 官网。'),
          ('Photo Mechanic 能做的，Flipic Lens 都能做吗？',
           '不能。拷卡、写 IPTC、关键词、Code Replacements 和交付是 Photo Mechanic 的强项；Flipic Lens 只做打开文件夹、翻页、看焦点、打星、标记和清理这一小段。'),
          ('两个都用会不会重复打星？',
           '可以只用一边打星。两边的评分都写 XMP，但固定一个软件负责评分，sidecar 更可控。'),
          ('只挑 RAW 用哪个？',
           '要拷卡和写 IPTC 用 Photo Mechanic；只想打开文件夹先看一遍，用 Flipic Lens。'),
      ], title_suffix=False, updated="2026-11-14", published="2026-11-08")

guide("zh", "/guides/xnview-mp-mac/", "XnView MP 和 Flipic Lens 怎么选",
      "XnView MP 和 Flipic Lens 怎么选",
      "XnView MP 强在格式多、批处理、可选图库和跨平台；Flipic Lens 强在不用导入、打开文件夹就用方向键挑片。如果你只需要挑片，Flipic Lens 可以只做后半段。",
      "XnView MP 管格式和批量，Flipic Lens 管挑片",
      f"""<p>XnView MP 适合需要超长格式列表、批量转换、批量重命名、可选图库和跨平台的人。Flipic Lens 适合只想在 Mac 上打开一个文件夹，用方向键翻、看焦点、打星、做第一轮清理的人。两个不冲突：XnView MP 管格式和批量，Flipic Lens 管挑片。</p>
<table><thead><tr><th></th><th>XnView MP</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>价格模式</td><td>个人、教育、公共和非营利免费；公司商用要付费授权</td><td>免费；可选一次买断的 Pro</td></tr><tr><td>要不要导入或建库</td><td>文件夹浏览；可选图库</td><td>不导入、不建库，直接读文件夹</td></tr><tr><td>看 RAW</td><td>能看相机 RAW，但不是 RAW 开发软件</td><td>直接打开相机 RAW；按 0 看 100% 焦点</td></tr><tr><td>星级存在哪</td><td>XMP sidecar，和 Lightroom、Bridge 交换星级</td><td>1 到 5 星写标准 XMP；RAW 写同名 .xmp</td></tr><tr><td>并排比较</td><td>Image Compare 最多四张</td><td>C 两张、⇧C 四张，缩放同步</td></tr><tr><td>闭眼 / 模糊 / 连拍</td><td>官网未列出</td><td>有：清理模式在本机分连拍、重复、闭眼、模糊</td></tr><tr><td>平台</td><td>macOS、Windows、Linux</td><td>macOS 13 或更新</td></tr><tr><td>开源</td><td>否</td><td>是，MIT</td></tr></tbody></table>
<h2>XnView MP 更强的地方</h2>
<ul><li><strong>格式多。</strong> 常见图片、相机 RAW、PDF、DICOM 等都在列表里。</li><li><strong>批量处理。</strong> 批量转换、批量重命名，和 XnConvert 共用一套批处理。</li><li><strong>跨平台和图库。</strong> macOS、Windows、Linux 都能用，可选 SQLite 图库，按星级、标签、关键词搜索。</li></ul>
<p><strong>四张比较。</strong> Image Compare 最多同时看四张。</p>
<h2>Flipic Lens 更适合的地方</h2>
<ul><li><strong>不用图库。</strong> 打开文件夹就翻，不导入，不建库。</li><li><strong>看焦点和比较。</strong> 0 在鼠标处放大到 100%；C 两张、⇧C 四张，缩放和拖动同步。</li><li><strong>星级写标准 XMP。</strong> 1 到 5 星，专有 RAW 写同名 .xmp；P 标记是访达标签。</li></ul>
<p><strong>清理模式。</strong> 免费，在本机分连拍、重复、闭眼、模糊，删哪些由你决定。<br><strong>小、免费、不用账号。</strong> 约 8 MB，MIT 开源。Pro 一次买断，带 7 天试用和工作台宫格。</p>
<h2>一起用</h2>
<p>要转格式、批量改名、跨平台看图或在图库里搜，用 XnView MP。要在一个文件夹里先挑一遍，用 Flipic Lens。两边都能写 XMP 星级，固定一个软件打星会更省心。</p>
<p>完整对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""",
      faq=[
          ('XnView MP 免费吗？',
           '个人、教育、公共和非营利用途免费；公司商用需要付费授权，具体看 XnView 官网。'),
          ('XnView MP 支持多少种格式？',
           '官方说支持大量常见图片和相机 RAW，还包括 PDF、DICOM 等；具体列表以官网为准。'),
          ('XnView MP 需要建图库吗？',
           '不需要。图库是可选的，不建也能按文件夹浏览。'),
          ('挑片用哪个？',
           '要格式转换、批量改名、跨平台和图库搜索，用 XnView MP；只想打开文件夹翻一遍、打星和清理，用 Flipic Lens。'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("zh", "/guides/fastrawviewer-mac/", "FastRawViewer 和 Flipic Lens",
      "FastRawViewer 和 Flipic Lens 怎么选",
      "FastRawViewer 看 RAW 本身的数据和曝光，Flipic Lens 负责打开文件夹、用方向键翻页、打星和第一轮清理。这篇写清各自适合谁，以及怎么一起用。",
      "FastRawViewer 看 RAW 数据，Flipic Lens 做挑片",
      f"""<p>FastRawViewer 适合要看传感器级 RAW 原始数据的人：去马赛克前的真 RAW 直方图、原始高光余量、暗部提亮与曝光补偿判断。Flipic Lens 适合想在 Mac 上免费打开文件夹就用方向键挑片的人，内置显示级直方图（<kbd>H</kbd>）、过曝/暗部斑马纹（<kbd>J</kbd>）、焦点峰值（<kbd>K</kbd>）、相机对焦框（<kbd>A</kbd>）、并排对比、XMP 星级与颜色标签、清理模式及外接硬盘 SSD 缓存。两个可以一起用：FastRawViewer 看 RAW 原始宽容度，Flipic Lens 做快速挑片。</p>
<table><thead><tr><th></th><th>FastRawViewer</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>价格模式</td><td>付费授权</td><td>免费；可选一次买断的 Pro</td></tr><tr><td>要不要导入或建库</td><td>不建图库；直接浏览文件夹</td><td>不导入、不建库，直接读文件夹</td></tr><tr><td>RAW 与质检</td><td>直接解传感器 RAW 数据；真 RAW 直方图、Shadow Boost、分通道、峰值对焦</td><td>直接打开相机 RAW；0 看 100% 焦点；显示级 RGB 直方图 (H)、过曝警示 (J)、焦点峰值 (K)、对焦框 (A)</td></tr><tr><td>星级与颜色标签</td><td>星级和标签写 XMP sidecar</td><td>1–5 星与颜色标签写标准 XMP；RAW 写同名 .xmp</td></tr><tr><td>并排比较</td><td>网格和单张；官网未列出同步对比</td><td>C 两张、⇧C 四张，缩放同步</td></tr><tr><td>闭眼 / 模糊 / 连拍</td><td>官网未列出</td><td>有：清理模式在本机分连拍、重复、闭眼、模糊</td></tr><tr><td>平台</td><td>macOS 和 Windows</td><td>macOS 13 或更新</td></tr><tr><td>开源</td><td>否</td><td>是，MIT</td></tr></tbody></table>
<h2>FastRawViewer 更强的地方</h2>
<ul><li><strong>看的是去马赛克前的 RAW 原始数据。</strong> 给出真 RAW 直方图、RAW 统计和原始高光溢出，判断高光还能不能拉回来比显示直方图更直接。</li><li><strong>曝光宽容度工具。</strong> Shadow Boost、分通道查看、曝光补偿预览，帮你判断后期宽容度。</li><li><strong>跨平台。</strong> macOS 和 Windows 都能用，不建图库。</li></ul>
<h2>Flipic Lens 更适合的地方</h2>
<ul><li><strong>打开就翻 + 常用质检免费。</strong> 双击一张方向键翻完文件夹，按 <kbd>H</kbd> 看 RGB 直方图、<kbd>J</kbd> 看过曝死黑、<kbd>K</kbd> 看焦点峰值、<kbd>A</kbd> 看相机对焦框、<kbd>0</kbd> 鼠标处放大 100%。</li><li><strong>同步对比与外接盘加速。</strong> C 两张、⇧C 四张缩放同步；外接硬盘预览自动缓存到本机 SSD。</li><li><strong>星级和颜色标签写标准 XMP。</strong> 1–5 星与颜色标签和 Lightroom / Capture One 互通；P 标记是访达标签。</li></ul>
<p><strong>清理模式。</strong> 免费，在本机分连拍、重复、闭眼和模糊，删哪些由你决定。<br><strong>小、免费、不用账号。</strong> 约 8.4 MB，MIT 开源。Pro 一次买断，带 7 天试用，增加工作台、自定义 .cube 3D LUT 和按客户文件名清单挑图。</p>
<h2>一起用</h2>
<p>需要判断 RAW 传感器高光还能拉回几档时用 FastRawViewer；日常快速翻片、看焦点与对焦框、打星标色、清理连拍废片用 Flipic Lens。两边都能写标准 XMP，建议固定一个软件负责评分，sidecar 更可控。</p>
<p>完整对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""",
      faq=[
          ('FastRawViewer 免费吗？',
           '不是免费软件，是付费授权，提供完整功能的试用；具体授权方式看 LibRaw 官网。'),
          ('Flipic Lens 的直方图和 FastRawViewer 的有什么区别？',
           'FastRawViewer 算的是去马赛克前的传感器级 RAW 直方图，专门判断高光还能拉回多少档；Flipic Lens 提供的是显示级 RGB/亮度直方图（H）、过曝/死黑警示（J）、焦点峰值（K）和相机对焦框（A），主打挑片顺手、全部免费。'),
          ('FastRawViewer 和 Flipic Lens 能一起用吗？',
           '能。FastRawViewer 看 RAW 原始曝光余量，Flipic Lens 翻页、打星、标记和清理。'),
          ('两边都写 XMP 星级和颜色标签吗？',
           '都写。两边都支持标准 XMP 评分与颜色标签（专有 RAW 写同名 .xmp）。'),
      ], title_suffix=False, updated="2026-11-22", published="2026-11-08")

guide("en", "/en/compare/", "Compare Mac photo viewers and culling tools",
      "Compare Mac photo tools",
      "Compare Flipic Lens, Preview, Photos, Bridge, Photo Mechanic, FastRawViewer, XnView MP, ApolloOne, FlowVision and Lightroom Classic by price model and main use.",
      "A map of Mac viewers, cullers and catalog tools",
      f"""<p>There is no single app that is the right fit for every Mac photo workflow. This table is a map: use it to pick by the job you have, then follow the link to the full comparison. Flipic Lens is the one for opening a folder and culling with the arrow keys; the other tools are stronger when the job includes a catalog, metadata, RAW data or a delivery workflow.</p>
<table><thead><tr><th>Tool</th><th>Price model</th><th>Import or library</th><th>Best for</th></tr></thead><tbody><tr><td><a href="/en/">Flipic Lens</a></td><td>Free; optional one-time Pro</td><td>No import; reads the folder</td><td>A quick, catalog-free cull with arrows, XMP stars, marks and Cleanup Mode.</td></tr><tr><td><a href="/en/guides/mac-preview-next-image/">Preview</a></td><td>Included with macOS</td><td>No library; opens files</td><td>Reading and annotating a few images or PDFs, not paging a folder.</td></tr><tr><td><a href="https://support.apple.com/guide/photos/welcome/mac">Photos</a></td><td>Included with macOS</td><td>Imports into a library</td><td>A personal photo library across Apple devices, not a culling tool.</td></tr><tr><td><a href="/en/guides/adobe-bridge-alternative-mac/">Adobe Bridge</a></td><td>Free</td><td>Folder browser; optional Photo Downloader</td><td>Metadata, keywords, Camera Raw and Adobe batch work.</td></tr><tr><td><a href="/en/guides/photo-mechanic-alternative-mac/">Photo Mechanic</a></td><td>Paid license; subscription or perpetual</td><td>Folder-based; optional ingest; Plus adds a catalog</td><td>High-volume ingest, IPTC, keywording and delivery.</td></tr><tr><td><a href="/en/guides/fastrawviewer-alternative-mac/">FastRawViewer</a></td><td>Paid license</td><td>No catalog; browse folders</td><td>RAW-data histogram, exposure checks and focus peaking.</td></tr><tr><td><a href="/en/guides/xnview-mp-alternative-mac/">XnView MP</a></td><td>Free for personal and non-commercial use; paid commercial license</td><td>Folder browser; optional catalog</td><td>A very long format list, batch tools and cross-platform work.</td></tr><tr><td><a href="/en/guides/apolloone-alternative/">ApolloOne</a></td><td>Free edition; paid Max Edition</td><td>No import; reads folders</td><td>Mac-native metadata, HDR, stacks, split view and quick edits.</td></tr><tr><td><a href="/en/guides/flowvision-alternative/">FlowVision</a></td><td>Free, open source (GPL-3.0)</td><td>Folder browser</td><td>Waterfall or grid browsing of photos and video.</td></tr><tr><td><a href="/en/guides/cull-before-lightroom/">Lightroom Classic</a></td><td>Subscription</td><td>Requires import into a catalog</td><td>Editing, RAW processing and long-term catalog management.</td></tr></tbody></table>
<h2>A quick way to choose</h2>
<ul><li><strong>Just open a folder and cull:</strong> Flipic Lens, with no import and XMP ratings. Preview can open a file but does not browse a folder on its own.</li><li><strong>Metadata, keywords or Adobe batch work:</strong> Adobe Bridge.</li><li><strong>High-volume ingest, IPTC and delivery:</strong> Photo Mechanic.</li></ul>
<p><strong>RAW histogram, exposure and focus peaking:</strong> FastRawViewer.<br><strong>Many formats, batch conversion or Linux:</strong> XnView MP.<br><strong>Mac-native metadata, HDR, stacks and quick edits:</strong> ApolloOne.<br><strong>Waterfall or grid browsing with video:</strong> FlowVision.<br><strong>Editing and a long-term catalog:</strong> Lightroom Classic.</p>
<h2>What Flipic Lens covers</h2>
<p>Flipic Lens reads the folder you open, double-click any photo and page with the arrow keys. Press 0 to zoom to 100% at the pointer, C or Shift-C to compare two or four frames with synced zoom, H/J/K/A for histogram, clipping, focus peaking and camera AF point, 1 to 5 to rate, 6 to 9 to color-label and P to mark. Ratings and color labels write standard XMP (same-name .xmp sidecar for proprietary RAW); marks are Finder tags. Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac, and external drive previews cache to your Mac’s internal SSD. The app is about 8.4 MB, MIT-licensed and keeps photos on your Mac. Pro is a one-time purchase with a 7-day trial adding the Workbench grid, zoom to the eyes, content/text search, client filename list matching and custom .cube 3D LUTs. See <a href="/en/guides/mac-photo-viewer-benchmark/">reproducible speed &amp; memory benchmarks</a>.</p>
<h2>What this table does not cover</h2>
<p>Price amounts, camera compatibility and plugin ecosystems change. The table only compares the pricing model and the main job each app is built for; check the vendor page before you buy. For the detailed rows, open the individual comparison pages linked above.</p>
<p>For the full open-source list, see <a href="/en/guides/open-source-image-viewers-mac/">open-source image viewers for Mac</a>.</p>""",
      faq=[
          ('Which app should I use to cull a folder on a Mac?',
           'Start with Flipic Lens if you want to open the folder, page with the arrow keys, check focus and rate without importing. Use Bridge, Photo Mechanic or Lightroom Classic when the same pass also needs metadata, ingest or a catalog.'),
          ('Do I have to import into Lightroom before culling?',
           'No. You can cull in Flipic Lens first and import only the keepers into Lightroom Classic; the XMP ratings travel with the files.'),
          ('Which of these apps has a grid?',
           "Flipic Lens's Pro Workbench has a project grid; Bridge, XnView MP, ApolloOne and FlowVision also offer grid or thumbnail views. The free Flipic Lens still has a thumbnail strip."),
          ('Are prices shown here?',
           'No. The table shows only the pricing model. Check each vendor for current amounts and licensing.'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("zh", "/compare/", "Mac 看图与挑片软件对比",
      "Mac 看图与挑片软件对比",
      "十款 Mac 看图、挑片和目录工具放在一张表里，按价格模式、导入方式、RAW 和用途对比，包括 Flipic Lens、Bridge 和 Lightroom Classic。",
      "一张表看清 Mac 看图、挑片和目录工具",
      f"""<p>没有一个软件适合所有 Mac 照片流程。这张表按「你要做的事」来分：先看哪一列像你，再点进对应的对比页。Flipic Lens 负责打开文件夹、用方向键挑片；需要目录、元数据、RAW 数据或交付流程时，别的工具更合适。</p>
<table><thead><tr><th>软件</th><th>价格模式</th><th>要不要导入或建库</th><th>适合谁</th></tr></thead><tbody><tr><td><a href="/">Flipic Lens</a></td><td>免费；可选一次买断的 Pro</td><td>不导入，直接读文件夹</td><td>打开文件夹，用方向键翻页、看焦点、打星、标记和清理。</td></tr><tr><td><a href="/guides/mac-next-image/">预览</a></td><td>macOS 自带</td><td>不建库，直接打开文件</td><td>看几张图片或 PDF、做标注，不是翻整个文件夹的挑片工具。</td></tr><tr><td><a href="https://support.apple.com/zh-cn/guide/photos/welcome/mac">照片</a></td><td>macOS 自带</td><td>导入照片图库</td><td>在 Apple 设备之间管理个人照片图库，不是挑片工具。</td></tr><tr><td><a href="/guides/adobe-bridge-mac/">Adobe Bridge</a></td><td>免费</td><td>文件夹浏览；可选 Photo Downloader</td><td>元数据、关键词、Camera Raw 和 Adobe 批处理。</td></tr><tr><td><a href="/guides/photo-mechanic-mac/">Photo Mechanic</a></td><td>付费；订阅或永久授权</td><td>按文件夹；可选拷卡；Plus 带图库</td><td>大量拷卡、IPTC、关键词和交付。</td></tr><tr><td><a href="/guides/fastrawviewer-mac/">FastRawViewer</a></td><td>付费授权</td><td>不建图库，直接浏览文件夹</td><td>RAW 直方图、曝光检查、峰值对焦。</td></tr><tr><td><a href="/guides/xnview-mp-mac/">XnView MP</a></td><td>个人和非商用免费；商用付费授权</td><td>文件夹浏览；可选图库</td><td>格式多、批处理、跨平台。</td></tr><tr><td><a href="/en/guides/apolloone-alternative/">ApolloOne</a></td><td>免费版；付费 Max 版</td><td>不导入，直接读文件夹</td><td>Mac 原生元数据、HDR、堆栈、分屏比较和快速编辑。</td></tr><tr><td><a href="/en/guides/flowvision-alternative/">FlowVision</a></td><td>免费，开源（GPL-3.0）</td><td>文件夹浏览</td><td>瀑布流或网格浏览照片和视频。</td></tr><tr><td><a href="/en/guides/cull-before-lightroom/">Lightroom Classic</a></td><td>订阅</td><td>需要导入目录</td><td>修图、RAW 处理和长期目录管理。</td></tr></tbody></table>
<h2>怎么快速选</h2>
<ul><li><strong>只想打开文件夹挑一遍：</strong> Flipic Lens，不导入，星级写 XMP。预览能打开文件，但不适合翻整个文件夹。</li><li><strong>元数据、关键词或 Adobe 批处理：</strong> Adobe Bridge。</li><li><strong>大量拷卡、IPTC 和交付：</strong> Photo Mechanic。</li></ul>
<p><strong>RAW 直方图、曝光和峰值对焦：</strong> FastRawViewer。<br><strong>格式多、批量转换或 Linux：</strong> XnView MP。<br><strong>Mac 原生元数据、HDR、堆栈和快速编辑：</strong> ApolloOne。<br><strong>瀑布流或网格浏览，还要看视频：</strong> FlowVision。<br><strong>修图和长期目录管理：</strong> Lightroom Classic。</p>
<h2>Flipic Lens 覆盖什么</h2>
<p>Flipic Lens 直接读你打开的文件夹，双击一张就用方向键翻。按 0 在鼠标处放大到 100%，C 两张、⇧C 四张缩放同步；H/J/K/A 看直方图、过曝死黑、焦点峰值与相机对焦框；1–5 打星、6–9 颜色标签写标准 XMP（专有 RAW 写同名 .xmp），P 标记是访达标签；外接硬盘预览缓存到本机 SSD。清理模式在本机分连拍、重复、闭眼和模糊。安装包约 8.4 MB，MIT 开源，不用账号。Pro 一次买断，带 7 天试用，增加工作台宫格、放大到眼睛、按内容和文字搜索、按客户文件名清单挑图和自定义 .cube 3D LUT。性能数据见 <a href="/guides/mac-photo-viewer-benchmark/">实测性能与内存占用</a>。</p>
<h2>这张表不覆盖什么</h2>
<p>具体价格、相机兼容性和插件生态会变。表里只写价格模式和主要用途，买之前看各家官网。每一行的详细对比，点上面对应链接。</p>
<p>开源看图清单见 <a href="/guides/mac-image-viewer-recommend/">Mac 看图软件推荐</a>。</p>""",
      faq=[
          ('Mac 上只想挑一个文件夹，用哪个？',
           '先用 Flipic Lens：打开文件夹，方向键翻，0 看焦点，1 到 5 打星，不用导入。要同时写元数据、拷卡或进目录，再考虑 Bridge、Photo Mechanic 或 Lightroom Classic。'),
          ('一定要先导入 Lightroom 才能挑片吗？',
           '不用。可以先在 Flipic Lens 里挑，再把留下的导入 Lightroom Classic；XMP 星级会跟着文件走。'),
          ('这些软件里有宫格吗？',
           'Flipic Lens 的 Pro 工作台有项目宫格；Bridge、XnView MP、ApolloOne 和 FlowVision 也有网格或缩略图视图。免费版 Flipic Lens 也有底部缩略图栏。'),
          ('表里有价格吗？',
           '没有。这里只写价格模式，具体金额和授权方式看各家官网。'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

IPTC_SPEC = "https://iptc.org/std/photometadata/specification/IPTC-PhotoMetadata-2025.1.html"
IPTC_STD = "https://iptc.org/standards/photo-metadata/iptc-standard/"

guide("en", "/en/guides/read-iptc-caption-mac/", "How to read an IPTC caption on a Mac",
      "Read an IPTC caption on Mac",
      "A photo's caption is stored in the file as the IPTC Description field. How to look for it in Preview's Inspector, read it in Flipic Lens and translate it.",
      "Where the caption is stored, and how to read and translate it",
      f"""<p>A caption written for a photo is stored inside the image file, in a metadata field that the IPTC Photo Metadata Standard calls Description. On a Mac you can look for it in Preview's Inspector, or open the photo in Flipic Lens and press <kbd>I</kbd>, which shows the caption at the top of the photo info panel.</p>
<h2>Where the caption is stored</h2>
<p>The IPTC specification defines Description as "A textual description, including captions, of the image" and labels the field Caption/Description. In XMP it is saved as <code>dc:description</code>; in the older IIM format it is <code>2:120 Caption/Abstract</code> (<a href="{IPTC_SPEC}#description">IPTC Photo Metadata Standard 2025.1, Description</a>).</p>
<p>Headline is a separate field next to it, defined as "A brief synopsis of the caption", and the specification adds that Headline is not the same as Title (<a href="{IPTC_SPEC}#headline">Headline</a>). Both belong to IPTC Core, one of the two schemas in the standard; the other is IPTC Extension (<a href="{IPTC_STD}">IPTC Photo Metadata Standard</a>).</p>
<h2>Look for it in Preview</h2>
<p>Apple's Preview guide describes the Inspector window as the place to view information about an image "such as file size, the author name, and the image resolution". Open the photo in Preview and click the Info button in the toolbar. Among the Inspector's tools, More Info is described as "View information about an image in different formats, and about where a photo was taken", and the Keywords inspector shows the keywords assigned to the image (<a href="https://support.apple.com/guide/preview/view-information-about-pdfs-and-images-prvw9c94f0a4/mac">View information about PDFs and images in Preview</a>).</p>
<p>Apple's page does not list the individual fields, so look through More Info for the description in your own file.</p>
<h2>Read it in Flipic Lens</h2>
<ol><li>Open the photo in Flipic Lens. The arrow keys page through the rest of the folder.</li><li>Press <kbd>I</kbd> to open the photo info panel. The headline (IPTC Headline) and caption (IPTC Description) written into the file are at the top, followed by the creator, credit, copyright, place and keywords.</li><li>Press <kbd>⇧I</kbd>, or use the control at the top right of the panel, to switch from Essentials to All.</li></ol>
<p>All is split into six groups: Description, Credit &amp; Rights, Capture, Image, Location and File. It includes the color model, orientation, resolution and a wire service's transmission reference. Text in the panel can be selected and copied, and a link inside a caption can be clicked. All of this is in the free version.</p>
<h2>Translate a caption</h2>
<p>When the caption is in a different language from the interface, a Translate button appears under it. The translation is shown below the original, and the original stays in place.</p>
<p>Flipic Lens uses the translation built into macOS. It runs on your Mac and the text is not sent to any server. The first time you translate from a language, macOS asks to download that language. Caption translation needs macOS 15 or later.</p>
<p>To translate every caption without clicking, turn on Settings › Viewing › Translate photo captions automatically. It is off by default.</p>
<h2>Reading, not editing</h2>
<p><a href="/en/">Flipic Lens</a> reads IPTC data and does not edit it or any other metadata. To write a caption, change a copyright notice or add keywords, use a tool that writes IPTC: a metadata editor, an asset browser with metadata tools, or an ingest and delivery app. The <a href="/en/compare/">comparison of Mac photo viewers and culling tools</a> lists which apps cover that work.</p>""",
      howto=["Open the photo in Flipic Lens", "Press I to open the photo info panel; the headline and caption stored in the file are at the top",
             "Press ⇧I to switch the panel between Essentials and All", "If the caption is in another language, click Translate under it (macOS 15 or later)"],
      faq=[
          ("Where is a photo's caption stored?",
           "In the file's metadata, in the IPTC Description field, labelled Caption/Description. It is saved as dc:description in XMP and as 2:120 Caption/Abstract in the older IIM format."),
          ("How do I view photo description metadata on a Mac?",
           "In Preview, open the photo and click the Info button in the toolbar to open the Inspector, then look through More Info. In Flipic Lens, press I; the caption stored in the file is at the top of the photo info panel."),
          ("Can Flipic Lens edit the caption?",
           "No. It reads IPTC data and does not edit it. Use a tool that writes IPTC metadata to change a caption."),
          ("Is the caption sent to a server when it is translated?",
           "No. Translation uses the one built into macOS and runs on your Mac. The first time you translate from a language, macOS asks to download that language. It needs macOS 15 or later."),
          ("Is reading captions a Pro feature?",
           "No. The photo info panel, IPTC captions and caption translation are in the free version."),
      ], title_suffix=False, updated="2026-11-14", published="2026-11-14")

guide("zh", "/guides/read-iptc-caption-mac/", "Mac 上怎么看照片里的说明（IPTC 图说）",
      "Mac 看照片说明和 IPTC",
      "照片的说明写在文件的 IPTC Description 字段里。这篇讲在 Mac 上怎么查看 IPTC：用「预览」的检查器找，或者在 Flipic Lens 里按 I 看，外文说明还能翻译。",
      "照片图说存在哪里，在 Mac 上怎么看、怎么翻译",
      f"""<p>照片的说明（也有人叫图说）可以直接写在照片文件里，跟着文件走。在 Mac 上可以打开系统自带的「预览」，到检查器里找；也可以用 Flipic Lens 打开，按 <kbd>I</kbd>，说明就显示在照片信息的最上面。</p>
<h2>说明存在文件的哪里</h2>
<p>IPTC 照片元数据标准里有一个字段叫 Description，界面上的名字是 Caption/Description。规范给它的定义是“A textual description, including captions, of the image”，就是对这张照片的文字描述，图说也写在这里。它在 XMP 里存成 <code>dc:description</code>，在老的 IIM 格式里是 <code>2:120 Caption/Abstract</code>（<a href="{IPTC_SPEC}#description">IPTC 照片元数据标准 2025.1，Description</a>）。</p>
<p>旁边还有一个 Headline 字段，定义是“A brief synopsis of the caption”，相当于说明的一句话概要，规范里还写明它和 Title 不一样（<a href="{IPTC_SPEC}#headline">Headline</a>）。这两个字段都属于 IPTC Core，标准的另一部分叫 IPTC Extension（<a href="{IPTC_STD}">IPTC Photo Metadata Standard</a>）。</p>
<h2>在「预览」里找</h2>
<p>按 Apple 的使用手册，用「预览」打开照片，点工具栏里的简介按钮（英文页面叫 Info button），会出来检查器窗口，里面能看文件大小、作者姓名、图像分辨率这类信息。检查器里的「更多信息」用来查看不同格式图像的信息和照片的大致拍摄地点，「关键词检查器」看分配给图像的关键词（<a href="https://support.apple.com/zh-cn/guide/preview/prvw9c94f0a4/mac">在 Mac 上的「预览」中查看 PDF 和图像的相关信息</a>）。</p>
<p>Apple 这一页没有逐个列出字段，照片里的说明要自己到「更多信息」里找一下。</p>
<h2>在 Flipic Lens 里看</h2>
<ol><li>用 Flipic Lens 打开照片，按方向键可以翻到同一个文件夹的其他照片。</li><li>按 <kbd>I</kbd> 打开照片信息面板。文件里写的标题（IPTC Headline）和说明（IPTC Description）显示在面板最上面，下面是作者、署名、版权、地名和关键词。</li><li>想看全部字段，按 <kbd>⇧I</kbd> 或者点面板右上角，从「常用」切到「全部」。</li></ol>
<p>「全部」分成六组：说明、署名与版权、拍摄、图像、地点、文件，色彩模型、方向、分辨率、通讯社的传输编号这些都在里面。面板上的文字可以选中复制，说明里带网址的话可以直接点开。这些都是免费功能。</p>
<h2>说明是外文的话</h2>
<p>说明的语言和界面语言不一样时，说明下面会出现「翻译」按钮。点一下，译文显示在原文下方，原文一直留着。</p>
<p>翻译用的是 macOS 自带的翻译，在本机完成，文字不会发到任何服务器。第一次翻某种语言时，系统会提示下载语言包。这个功能需要 macOS 15 或更新。</p>
<p>想让每张照片的说明都自动翻译，可以在「设置 › 看图」里打开「自动翻译照片说明」，默认是关的。</p>
<h2>Flipic Lens 只读这些信息</h2>
<p>Flipic Lens 只读 IPTC，不编辑它，其他元数据也不改。要写说明、改版权或者加关键词，得用能写 IPTC 的软件，比如元数据编辑软件、带元数据功能的素材浏览器，或者拷卡交付类的软件。哪些软件做这些事，<a href="/compare/">Mac 看图与挑片软件对比</a> 里有一张表。</p>""",
      howto=["用 Flipic Lens 打开照片", "按 I 打开照片信息面板，文件里写的标题和说明显示在最上面",
             "按 ⇧I 在「常用」和「全部」之间切换", "说明是外文时，点说明下面的「翻译」（需要 macOS 15 或更新）"],
      faq=[
          ("照片的图说存在哪里？",
           "存在照片文件的元数据里，字段是 IPTC Description（界面名 Caption/Description）。XMP 里存成 dc:description，老的 IIM 格式里是 2:120 Caption/Abstract。"),
          ("Mac 上怎么查看 IPTC？",
           "用「预览」打开照片，点工具栏里的简介按钮打开检查器，到「更多信息」里找。用 Flipic Lens 的话按 I，文件里写的标题和说明显示在照片信息面板最上面，按 ⇧I 切到「全部」能看到所有字段。"),
          ("Flipic Lens 能改照片说明吗？",
           "不能。Flipic Lens 只读 IPTC，不编辑。要改说明，得用能写 IPTC 元数据的软件。"),
          ("翻译的时候，说明会被传到网上吗？",
           "不会。翻译用的是 macOS 自带的翻译，在本机完成。第一次翻某种语言时系统会提示下载语言包，需要 macOS 15 或更新。"),
          ("看照片说明要买 Pro 吗？",
           "不用。照片信息面板、IPTC 说明和说明翻译都是免费功能。"),
      ], title_suffix=False, updated="2026-11-14", published="2026-11-14")

guide("zh", "/guides/external-drive-slow-photos-mac/", "Mac 外接硬盘打开照片和 RAW 很慢？原因与提速办法",
      "外接硬盘看图慢怎么解决",
      "为什么外接机械硬盘或移动硬盘在 Mac 上打开照片和 RAW 特别慢？从休眠、NTFS 驱动、Spotlight 索引到 Flipic Lens 本机 SSD 缓存的实操提速办法。",
      "排查外接硬盘看图卡顿的硬件、系统与缓存方案",
      f"""<p>把几百 GB 照片放在外接移动硬盘上，在 Mac 上双击开图往往要转圈好几秒，换别的看图软件也同样慢。这通常不是某一个软件的 Bug，而是外接盘硬件特性、文件系统驱动和看图解码方式叠加的结果。</p>
<h2>为什么外接硬盘在所有软件里都慢？</h2>
<ul>
<li><strong>机械硬盘休眠唤醒与低随机 IOPS：</strong>USB 机械硬盘闲置几分钟会停转，再次唤醒要等 3–8 秒；而且机械盘随机读只有约 80–150 IOPS（Mac 内置 SSD 在十万级），只要看图软件同时开多线程读缩略图、查扩展属性，磁头来回寻道就会卡顿。</li>
<li><strong>文件系统与第三方 NTFS 驱动：</strong>Windows 常用的 NTFS 盘在 macOS 上依赖第三方 FUSE/内核驱动，每次 <code>stat()</code> 和打开文件开销成倍放大；exFAT 上查访达扩展属性还会触发成百上千次隐藏的 <code>._*</code>（AppleDouble）文件寻道。</li>
<li><strong>刚插盘时 Spotlight（<code>mds_stores</code>）抢带宽：</strong>硬盘刚挂载后 macOS 会在后台扫描建索引，把本来有限的 USB 带宽占满。</li>
<li><strong>全量 RAW 解码：</strong>许多看图软件没有取内嵌预览，直接通过 USB 读完整张 50–100 MB RAW 再解马赛克，单张耗时很容易拉到 5–10 秒。</li>
</ul>
<h2>Flipic Lens 针对外接硬盘做了哪些优化？</h2>
<p><a href="/">Flipic Lens</a> 1.0.59–1.0.60 内置了一套专门面向外接机械硬盘、ExFAT 存储卡与网络盘的冷读取加速链路（免费 + 工作台共用）：</p>
<ol>
<li><strong>本机 SSD 持久化预览缓存（500 MB LRU）：</strong>外接盘的屏幕级预览图（最高 2560px）与缩略图（含工作台宫格/胶片条缩略图）会自动缓存在 Mac 内置 SSD（<code>~/Library/Caches</code>），上限 500 MB，超限时按最久未访问自动清理。再次打开文件夹、甚至拔盘重插同一块硬盘后，翻图直接读 Mac 本机 SSD，接近本地速度；原图改动过会自动失效重解，放大到 100% 仍读原图。可在「设置 › 看图 › 外接盘加速」随时开关或清空。</li>
<li><strong>POSIX 顺序大块读盘 + 单次打开解码 + RAW 前 4 MB 预览快扫：</strong>首次冷读外接盘文件时采用大块顺序读取并合并单次打开解码；读相机 RAW 时先只扫文件头前 4 MB 快速定位相机内嵌大图预览，不再把整张 60–100 MB RAW 映射过 USB，首次翻 RAW 也能快速上屏。</li>
<li><strong>按卷优先级单通道顺序调度与首图优先：</strong>检测到外接慢存储时自动按卷收窄为单通道顺序读，高优先级永远让给当前正在看的那张图，减少机械盘磁头抖动，等首图上屏后再做后台缩略图预热。</li>
<li><strong>跳过非 APFS 卷的 <code>._*</code> 寻道与目录级 <code>.xmp</code> 索引：</strong>列目录时直接复用 <code>getattrlistbulk</code> 预取结果并一次建好目录级 <code>.xmp</code> 索引，在 exFAT / FAT / NTFS / SMB 卷上统一跳过访达扩展属性和无效的 <code>._*</code> / <code>.xmp</code> 逐文件探测。</li>
</ol>
<h2>系统侧还能顺手做的 3 件事</h2>
<ul>
<li><strong>纯 Mac 工作盘优先格成 APFS：</strong>如果这块移动 SSD 只接 Mac，APFS 的目录遍历与元数据速度远高于 exFAT 和 NTFS。</li>
<li><strong>跨系统优先 exFAT，少用老旧 NTFS 驱动：</strong>必须兼顾 Windows 和 Mac 时，exFAT 是系统原生支持，比第三方 NTFS 驱动稳定且少一层转发开销。</li>
<li><strong>把归档机械盘排除出 Spotlight：</strong>在「系统设置 › 聚焦 › 搜索隐私」里加入不常搜的归档硬盘，避免每次插盘都被 <code>mds_stores</code> 占满 IO。</li>
</ul>
<p>想了解 Flipic Lens 在本机上的实测速度与内存数据，见 <a href="/guides/mac-photo-viewer-benchmark/">Flipic Lens 实测性能与内存占用</a>；RAW 看图流程见 <a href="/guides/mac-view-raw/">Mac 上怎么快速看 RAW 照片</a>。</p>""",
      howto=["将 Flipic Lens 更新到 1.0.59 或更新版本，确认「设置 › 看图 › 外接盘加速」已开启（默认开启）",
             "首次打开外接硬盘里的照片文件夹：Flipic Lens 会用单通道顺序读和 RAW 前 4 MB 快扫优先显示当前照片，并后台将预览缓存到 Mac 内置 SSD",
             "再次打开该文件夹或拔盘重插同一块硬盘时，翻页直接命中本机 SSD 缓存，放大到 100% 时才回源读原图",
             "如外接盘是归档机械盘，可在 macOS「系统设置 › 聚焦 › 搜索隐私」中排除该盘以减少后台抢占"],
      faq=[
          ("外接硬盘缓存会占满 Mac 硬盘吗？",
           "不会。缓存放在系统标准 Caches 目录，默认上限 500 MB，超过后按最久未访问自动清理回 400 MB，也可以在「设置 › 看图 › 外接盘加速」里看实时占用并一键清空。"),
          ("拔掉硬盘重插以后缓存还有效吗？",
           "有效。缓存按「卷唯一标识 + 相对路径 + 文件大小 + 修改时间」做键，重插甚至挂载路径变化都能命中；如果原图被后期软件改过，缓存会自动失效并重新生成。"),
          ("命中本机 SSD 缓存后，放大看焦点会糊吗？",
           "不会。本机缓存用于窗口适应浏览（最高 2560px）；当你按 0 或捏合放大到 100% 时，Flipic Lens 仍会按需读取外接盘上的全分辨率原图。"),
          ("这个外接盘加速功能收费吗？",
           "免费，直接包含在开源核心版里，官网版与 Mac App Store 版都可用。"),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-22")

guide("en", "/en/guides/fast-photo-viewer-external-hard-drive-mac/", "Why photos open slowly from an external hard drive on Mac",
      "Fast viewing on external drives",
      "Why photos and camera RAW files open slowly from an external hard drive on Mac (HDD spin-up, NTFS drivers, Spotlight, full RAW decode) and how local SSD caching fixes it.",
      "Causes of slow external-drive photo browsing and how local SSD caching helps",
      f"""<p>If double-clicking a photo on an external USB hard drive takes several seconds in every Mac viewer you try, the slowdown is rarely just one app. It is usually the combination of mechanical drive physics, file-system overhead, background indexing and full RAW decoding over USB.</p>
<h2>Why every viewer feels slow on an external drive</h2>
<ul>
<li><strong>HDD spin-up and low random IOPS:</strong> A portable spinning drive parks its heads after a few minutes of idle time (3–8 seconds to wake up) and only delivers around 80–150 random IOPS compared to 100,000+ on a Mac’s internal SSD. Multi-threaded thumbnail and metadata reads cause constant head thrashing.</li>
<li><strong>File system &amp; third-party NTFS drivers:</strong> NTFS drives mounted via third-party drivers on macOS add heavy per-syscall overhead. On exFAT, querying Finder extended attributes triggers thousands of seeks for hidden <code>._*</code> AppleDouble sidecar files.</li>
<li><strong>Spotlight (<code>mds_stores</code>) indexing on mount:</strong> Right after plugging a drive in, macOS often scans it in the background, saturating USB bandwidth.</li>
<li><strong>Full RAW demosaic over USB:</strong> Reading an entire 50–100 MB RAW file across USB just to fit a photo on screen can easily take 5–10 seconds per frame.</li>
</ul>
<h2>How Flipic Lens speeds up external hard drives</h2>
<p>In 1.0.59–1.0.60, <a href="/en/">Flipic Lens</a> ships a free external-drive cold-read pipeline designed for USB HDDs, ExFAT SD cards, external SSDs and network shares (shared by both the Viewer and Pro Workbench):</p>
<ol>
<li><strong>Persistent local SSD preview &amp; thumbnail cache (500 MB LRU):</strong> Screen-sized previews (up to 2560px) and thumbnails for external drives cache on your Mac’s internal SSD under <code>~/Library/Caches</code>, capped at 500 MB with automatic oldest-first eviction. Reopening a folder—or ejecting and reconnecting the same drive—browses at near-local speed. Modified files refresh automatically, and 100% zoom always reads the original. Toggle or clear anytime in Settings › Viewing › External drives.</li>
<li><strong>POSIX large-chunk sequential reads + single-open decode + 4 MB RAW prefix scan:</strong> Cold reads pull large sequential chunks and decode from a single open handle; for camera RAW files, Flipic Lens scans only the first 4 MB to extract the embedded preview instead of mapping a 60–100 MB file over USB.</li>
<li><strong>Per-volume priority serial I/O &amp; first-photo priority:</strong> On slow external volumes, decoding and thumbnail jobs serialize per volume with the active photo always jumping the queue, stopping HDD head thrashing and deferring background thumbnails until your first frame is sharp.</li>
<li><strong>Zero double-stat, directory-level <code>.xmp</code> index &amp; skip <code>._*</code> probes:</strong> Reuses prefetched metadata from <code>getattrlistbulk</code>, indexes existing <code>.xmp</code> sidecars once per folder, and skips Finder extended-attribute seeks on exFAT, FAT, NTFS and SMB volumes.</li>
</ol>
<h2>Three system-side checks worth doing</h2>
<ul>
<li><strong>Use APFS for Mac-only work drives:</strong> Directory enumeration and metadata lookups are dramatically faster on APFS than exFAT or NTFS.</li>
<li><strong>Prefer exFAT over third-party NTFS drivers for Mac+Windows drives:</strong> exFAT is native to both systems and avoids FUSE bridge overhead.</li>
<li><strong>Exclude archive HDDs from Spotlight:</strong> Add rarely searched archive drives under System Settings › Spotlight › Search Privacy so <code>mds_stores</code> does not fight your viewer right after mount.</li>
</ul>
<p>For reproducible speed and memory numbers on Mac, see the <a href="/en/guides/mac-photo-viewer-benchmark/">Flipic Lens speed &amp; memory benchmark</a>. For RAW culling workflows, see <a href="/en/guides/view-raw-files-mac/">how to quickly view RAW files on a Mac</a>.</p>""",
      howto=["Update to Flipic Lens 1.0.59 or later and confirm Settings › Viewing › External drives cache is on (enabled by default)",
             "Open a folder on your external drive: Flipic Lens prioritizes the first photo using 4 MB RAW preview scan and single-lane sequential I/O, writing previews asynchronously to your Mac’s SSD",
             "Reopen the folder or reconnect the same drive later to page directly from the local SSD cache; hold 0 to zoom to 100% and read the original",
             "Optionally exclude large archive spinning drives in macOS System Settings › Spotlight › Search Privacy"],
      faq=[
          ("Will the external-drive cache fill up my Mac’s SSD?",
           "No. It lives in macOS’s standard Caches folder with a 500 MB cap, automatically evicting the least recently used previews down to 400 MB. You can check current usage or click Clear Cache anytime in Settings › Viewing."),
          ("Does the cache still work after ejecting and reconnecting the drive?",
           "Yes. Keys use the volume UUID (or name + capacity on FAT/exFAT), relative path, file size and modification timestamp, so reconnecting still hits—and any photo edited externally refreshes automatically."),
          ("Does caching affect 100% zoom sharpness?",
           "No. Cached previews (up to 2560px) are used for fit-to-window browsing; zooming to 100% still decodes the full-resolution original from the drive."),
          ("Is external-drive caching a Pro feature?",
           "No, it is free and included in both the website version and the Mac App Store version."),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-22")

guide("zh", "/guides/mac-photo-viewer-benchmark/", "Flipic Lens 实测性能与内存占用（可自行复现）",
      "实测性能与内存数据",
      "Flipic Lens 1.0.59 在 50 张 2400 万像素 JPEG 下的真实翻页延迟、主线程卡顿、内存占用与安装包体积，附完整复现命令。",
      "真实 --bench 翻页耗时、内存峰值与自行复现命令",
      f"""<p>看图软件说「快」和「轻量」很容易空口无凭。Flipic Lens 内置了诊断参数 <code>--bench</code>，可以在你自己的 Mac 和真实照片文件夹上直接测出首图耗时、连续翻页延迟、1:1 放大卡顿和内存峰值。</p>
<h2>1.0.59 实测数据（2026-11-22）</h2>
<p><strong>测试环境：</strong>Apple M5 Pro · 64 GB 内存 · macOS 26.3.1 · Flipic Lens 1.0.59（arm64 + x86_64 通用版）<br>
<strong>测试素材：</strong>内置 SSD 上 50 张 6000×4000（2400 万像素）JPEG 照片</p>
<table><thead><tr><th>指标</th><th>实测值</th><th>说明</th></tr></thead><tbody>
<tr><td>安装包体积（DMG）</td><td>8.4 MB</td><td>通用二进制（Apple 芯片 + Intel）+ 14 种语言</td></tr>
<tr><td>首图打开（<code>firstOpen</code>）</td><td>50 ms</td><td>打开文件夹到第一张清晰图上屏</td></tr>
<tr><td>连按方向键翻页（40 步）</td><td>p50 = 1 ms · max = 2 ms</td><td>40/40 步均出图，空白帧 <code>blankSamples = 0</code></td></tr>
<tr><td>常规慢翻（<code>slowNav</code>）</td><td>p50 = 2 ms · max = 4 ms</td><td>后台单队列顺序预取命中</td></tr>
<tr><td>1:1 全分辨率放大卡顿</td><td>17 ms（主线程停顿）</td><td>后台解码画入 IOSurface 直接交给显卡，原图 6000px</td></tr>
<tr><td>内存占用（物理足迹）</td><td>打开 167 MB → 翻页 245–302 MB → 1:1 放大峰值 579 MB</td><td>缓存上限按本机物理内存比例封顶（8 GB / 16 GB 机器会自动更低）</td></tr>
</tbody></table>
<h2>如实说明边界</h2>
<ul>
<li>以上为内置 SSD 上 2400 万像素合成 JPEG 的基线读数；不同相机 RAW（如 4500–6000 万像素 ARW/RAF/CR3）、老款 Intel Mac 或外接 USB 机械硬盘耗时一定不同。</li>
<li>在 8 GB / 16 GB 内存 Mac 上，预览与全图缓存天花板会按物理内存比例自动缩窄（预览上限 <code>mem/48</code>、全图上限 <code>mem/24</code>），并在收到系统内存压力信号时优先淘汰远离当前页的缓存，不把机器拖死。</li>
<li>外接机械硬盘首次翻图受限于 USB 带宽与硬盘寻道，建议配合 <a href="/guides/external-drive-slow-photos-mac/">外接盘本机 SSD 缓存</a>（1.0.59 起默认开启）。</li>
</ul>
<h2>在你自己的照片文件夹上复现</h2>
<p>装好 Flipic Lens 后，在终端运行这一行（把末尾路径换成你自己的照片文件夹）：</p>
<pre><code>"/Applications/Flipic Lens.app/Contents/MacOS/Flipic" --bench ~/Pictures/你的照片文件夹</code></pre>
<p>程序会自动走完打开、40 步快速连翻、慢翻和 1:1 放大，并在终端打印 <code>BENCH</code> 汇总行后退出，不会修改任何照片。</p>
<p>完整版本变化见 <a href="/changelog/">更新记录</a>；软件选型对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""",
      faq=[
          ("为什么不放和竞争对手的跑分对比图？",
           "不同软件的缓存预热、缩略图数据库、RAW 解码精度（内嵌预览 vs 全量解马赛克）差异很大，实验室里单方面对比别家很容易失真。Flipic Lens 只公开自己可一键复现的 --bench 数据与测试条件，欢迎用你自己的真实拍摄文件夹直接对比体感。"),
          ("8 GB 内存的 MacBook Air 跑得动吗？",
           "跑得动。Flipic Lens 的预览与全图内存缓存按本机物理内存比例自动封顶（8 GB Mac 上预览上限约 170 MB），且全图只在放大到 100% 时才按需解码，只保留当前与上一张。"),
      ], title_suffix=False, updated="2026-11-22", published="2026-11-22")

guide("en", "/en/guides/mac-photo-viewer-benchmark/", "Flipic Lens speed & memory benchmark (reproducible on your Mac)",
      "Speed & memory benchmark",
      "Real, reproducible --bench measurements for Flipic Lens 1.0.59 on 50×24 MP JPEGs: open latency, rapid arrow-key paging, 1:1 zoom stall, memory footprint and exact CLI command.",
      "Reproducible --bench paging latency, memory footprint and exact command",
      f"""<p>Speed claims are easy to write and hard to verify. Flipic Lens ships with a built-in <code>--bench</code> flag so you can measure open latency, rapid arrow-key paging, 1:1 zoom stalls and memory footprint on your own Mac and your own shoot folder.</p>
<h2>1.0.59 baseline measurement (2026-11-22)</h2>
<p><strong>Hardware:</strong> Apple M5 Pro · 64 GB RAM · macOS 26.3.1 · Flipic Lens 1.0.59 (universal arm64 + x86_64)<br>
<strong>Dataset:</strong> 50 distinct 6000×4000 (24 MP) JPEGs on internal SSD</p>
<table><thead><tr><th>Metric</th><th>Measured</th><th>Notes</th></tr></thead><tbody>
<tr><td>Installer size (DMG)</td><td>8.4 MB</td><td>Universal binary (Apple silicon + Intel) + 14 languages</td></tr>
<tr><td>First photo open (<code>firstOpen</code>)</td><td>50 ms</td><td>Folder open to sharp first frame on screen</td></tr>
<tr><td>Rapid arrow-key hold (40 steps)</td><td>p50 = 1 ms · max = 2 ms</td><td>40/40 sharp steps, <code>blankSamples = 0</code></td></tr>
<tr><td>Deliberate paging (<code>slowNav</code>)</td><td>p50 = 2 ms · max = 4 ms</td><td>Single-lane background prefetch hit</td></tr>
<tr><td>1:1 full-res zoom stall</td><td>17 ms main-thread max</td><td>Decoded off-thread into IOSurface (6000px backing)</td></tr>
<tr><td>Physical memory footprint</td><td>167 MB open → 245–302 MB paging → 579 MB peak at 1:1</td><td>Cache caps scale with machine RAM (lower on 8 GB / 16 GB Macs)</td></tr>
</tbody></table>
<h2>Honest boundaries</h2>
<ul>
<li>These numbers are a baseline on internal SSD with 24 MP synthetic JPEGs. Large 45–60 MP camera RAWs (ARW/RAF/CR3), older Intel Macs and USB spinning drives will measure differently.</li>
<li>On 8 GB and 16 GB Macs, preview and full-image caches automatically cap as a fraction of physical RAM (<code>mem/48</code> preview, <code>mem/24</code> full) and shed distant frames under macOS memory pressure.</li>
<li>For external USB drives and SD cards, see <a href="/en/guides/fast-photo-viewer-external-hard-drive-mac/">how Flipic Lens accelerates external drives with a 500 MB local SSD cache</a>.</li>
</ul>
<h2>Reproduce it on your own photos</h2>
<p>After installing Flipic Lens, run this command in Terminal (point the path at any folder of your own photos):</p>
<pre><code>"/Applications/Flipic Lens.app/Contents/MacOS/Flipic" --bench ~/Pictures/your-folder</code></pre>
<p>It opens the folder, runs 40 rapid steps, slow paging and a 1:1 zoom, prints the <code>BENCH</code> summary and exits without modifying any file.</p>
<p>See what changed recently in the <a href="/en/changelog/">Changelog</a>, or compare tools at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ("Why not publish side-by-side benchmark bars against competitors?",
           "Viewers differ widely in thumbnail databases, warm caches and whether they show an embedded preview or full RAW demosaic, making vendor-run competitor charts easy to skew. We publish only reproducible --bench numbers with exact conditions so you can test on your own folder."),
          ("Does it run well on an 8 GB MacBook Air?",
           "Yes. Preview and full-image caches scale down automatically with system memory (about 170 MB preview cap on an 8 GB Mac), and full-resolution originals are decoded only when zoomed in and kept to two frames."),
      ], title_suffix=False, updated="2026-11-22", published="2026-11-22")

guide("zh", "/guides/exif-photo-frame-mac/", "Mac 给照片加 EXIF 参数边框（白边、机身镜头与快门光圈水印）",
      "Mac 加 EXIF 参数边框",
      "在 Mac 上免费给照片加白边、黑边或模糊背景并自动排版 EXIF 相机型号、镜头、焦距、光圈、快门与 ISO，支持单张预览另存和整组批量导出。",
      "一键加白边并自动排版机身、镜头、光圈快门与 ISO，免费支持批量",
      f"""<p>发小红书、朋友圈、Instagram 或做摄影作品集时，很多摄影师习惯给照片加一圈干净的白边或黑边，在底边标出机身、镜头、焦距、光圈、快门和 ISO。在手机上做要来回传图、压缩画质，用 Photoshop 套模板又太慢。在 Mac 上用 <a href="/">Flipic Lens</a>，看图时按一下 <kbd>⇧B</kbd> 就能实时预览并出图，而且完全免费。</p>
<figure>{shot('exif-frame.webp', 'Flipic Lens EXIF 参数相框：圣托里尼照片配上白色留白边框，底边自动排版 SONY ILCE-7M4、FE 35mm F1.4 GM 与拍摄参数')}<figcaption>按 ⇧B 打开加边框条，勾选「拍摄参数」后实时看到排版与导出像素尺寸。</figcaption></figure>
<h2>会自动读取并排版哪些 EXIF 参数？</h2>
<p>勾选「拍摄参数」后，Flipic Lens 直接从照片文件头读取原始 EXIF，不需要手工打字：</p>
<ul>
<li><strong>左侧：</strong>相机型号（例如 <code>SONY ILCE-7M4</code>、<code>Canon EOS R5</code>、<code>NIKON Z 8</code>、<code>FUJIFILM X-T5</code>）与镜头型号（例如 <code>FE 35mm F1.4 GM</code>）。</li>
<li><strong>右侧：</strong>焦距、光圈、快门速度、ISO（例如 <code>35mm · ƒ/8 · 1/2000s · ISO 100</code>）与拍摄日期。</li>
<li><strong>字色自适应：</strong>白底和浅色自选底用深灰/黑字，黑底和深色背景自动切换浅字，不需要手动调对比度。</li>
</ul>
<h2>支持哪些边框比例与背景？</h2>
<ul>
<li><strong>比例：</strong>原比例（等宽留白）、<code>4:5</code>（小红书/Instagram 竖图常用）、<code>1:1</code>、<code>3:4</code>、<code>16:9</code>、<code>9:16</code> 或自定义比例/像素。</li>
<li><strong>背景：</strong>纯白、纯黑、原图高斯模糊背景（竖屏发横图很实用）、或任意自定义颜色。</li>
<li><strong>输出尺寸：</strong>支持保留原尺寸，或直接限定长边（如 2048px / 1440px）另存副本，<strong>原图和 RAW 永远不会被覆盖</strong>。</li>
</ul>
<h2>怎么一次给整组照片批量加 EXIF 参数相框？</h2>
<ol>
<li>单张快速出图：在 Flipic Lens 看图窗口按 <kbd>⇧B</kbd>，挑好比例、底色、边宽并勾选「拍摄参数」，按 <kbd>回车</kbd> 另存一份；下次按 <kbd>⇧B</kbd> 会记住上次的样式。</li>
<li>整组批量出图：先用 <kbd>1–5</kbd> 打星或 <kbd>P</kbd> 标记筛出要发的照片，按 <kbd>⇧⌘C</kbd> 打开「批量转换格式」（或在 <kbd>⌘S</kbd> 导出里）开启边框与拍摄参数，一次输出到指定文件夹。</li>
<li>经常发同一套规格（比如「小红书 4:5 白边 + 长边 2048 + 去 GPS」）的话，在 <a href="/pro/">Pro 导出预设</a> 里存成一条预设，以后按 <kbd>⌥⌘1</kbd> 一步出图。</li>
</ol>
<p>如果想在发样片给客户时顺便加平铺防盗水印或 <code>{{index}}</code> 序号，也可以配合 Flipic Lens 免费的导出水印功能一起使用。看图质检流程见 <a href="/guides/check-focus-histogram-zebra-mac/">Mac 挑片怎么看对焦框、直方图与过曝警示</a>。</p>""",
      howto=["在 Mac 上用 Flipic Lens 打开需要加边框的照片（支持 JPEG、HEIC、PNG 与常见相机 RAW）",
             "按 ⇧B 打开底部「加边框」控制条，勾选「拍摄参数」",
             "选择边框比例（如原比例等宽、4:5 或 1:1）、底色（白、黑、模糊背景或自选）与输出长边尺寸",
             "按回车直接另存为带参数边框的新副本，或在 ⇧⌘C 批量转换中对整个文件夹一键套用"],
      faq=[
          ("给照片加 EXIF 参数边框会改动原图或压缩 RAW 吗？",
           "不会。加边框始终另存为新文件（文件名自动带「-边框」后缀），原 JPEG 和相机 RAW 一个字节都不会改。"),
          ("如果照片之前被微信压过、没有 EXIF 怎么办？",
           "没有拍摄参数时底边不会出现乱码或空白占位，照常生成干净的纯色或模糊留白边框。"),
          ("导出的带边框照片还能去掉 GPS 定位或机身序列号吗？",
           "可以。通过 ⌘S 导出或 ⇧⌘C 批量转换加边框时，可以单独勾选抹掉位置信息和相机/镜头序列号，发到网上更安心。"),
          ("EXIF 参数相框需要买 Pro 吗？",
           "不需要，单张 ⇧B、⌘S 导出和 ⇧⌘C 批量加 EXIF 参数相框全部免费。只有一键保存成多套快捷键导出预设（⌥⌘1–⌥⌘9）属于 Pro。"),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("en", "/en/guides/exif-photo-frame-mac/", "Add an EXIF Photo Frame on Mac (Camera, Lens & Settings Border)",
      "EXIF photo frame on Mac",
      "Add a clean white, black or blurred border with automatic camera, lens, focal length, aperture, shutter speed and ISO EXIF caption on Mac—free, single or batch.",
      "Frame photos with automatic camera, lens and exposure EXIF on Mac",
      f"""<p>When sharing photos on Instagram, portfolios or print proofs, adding a clean white or black border with camera, lens and exposure details along the bottom is a classic touch. Doing it on a phone means AirDropping files back and forth and losing quality; building templates in Photoshop takes too long. In <a href="/en/">Flipic Lens</a> on Mac, press <kbd>⇧B</kbd> while viewing any photo to frame it live and export—completely free.</p>
<figure>{shot('exif-frame-en.webp', 'Flipic Lens EXIF photo frame on a Santorini photo inside a white border showing SONY ILCE-7M4, FE 35mm F1.4 GM, and 35mm f/8 1/2000s ISO 100')}<figcaption>Press ⇧B to open the live border bar, tick Photo info, and see exact export pixel dimensions before saving.</figcaption></figure>
<h2>What EXIF metadata is typeset automatically?</h2>
<p>With Photo info checked, Flipic Lens reads the file header directly—no manual typing:</p>
<ul>
<li><strong>Bottom left:</strong> Camera body (such as <code>SONY ILCE-7M4</code>, <code>Canon EOS R5</code>, <code>NIKON Z 8</code>, <code>FUJIFILM X-T5</code>) and lens model (such as <code>FE 35mm F1.4 GM</code>).</li>
<li><strong>Bottom right:</strong> Focal length, aperture, shutter speed, ISO (<code>35mm · ƒ/8 · 1/2000s · ISO 100</code>) and date taken.</li>
<li><strong>Automatic contrast:</strong> Dark type on white or light custom borders, light type on black or dark backgrounds.</li>
</ul>
<h2>Supported aspect ratios &amp; backgrounds</h2>
<ul>
<li><strong>Aspect ratios:</strong> Original ratio (even margins), <code>4:5</code> (Instagram portrait), <code>1:1</code>, <code>3:4</code>, <code>16:9</code>, <code>9:16</code>, or any custom ratio/pixel size.</li>
<li><strong>Backgrounds:</strong> White, black, blurred photo fill (great for landscape shots inside a vertical 4:5 frame), or any custom color.</li>
<li><strong>Safe copies:</strong> Keep full resolution or cap the long edge (e.g., 2048px or 1440px). <strong>Originals and RAW files are never overwritten.</strong></li>
</ul>
<h2>Single-shot and batch EXIF framing</h2>
<ol>
<li><strong>Single photo:</strong> Press <kbd>⇧B</kbd> in the viewer, choose ratio, color, margin width and tick Photo info, then press <kbd>Return</kbd> to save a copy. Your last settings are remembered next time.</li>
<li><strong>Whole shoot in one pass:</strong> Filter your keepers with <kbd>1–5</kbd> stars or <kbd>P</kbd>, open Export (<kbd>⌘S</kbd>) or Batch Convert (<kbd>⇧⌘C</kbd>), turn on Border + Photo info, and export to a clean subfolder.</li>
<li><strong>One-key delivery preset:</strong> If you always export the same Instagram spec (e.g. 4:5 white EXIF frame + 2048px + strip GPS), save it as a <a href="/en/pro/">Pro Export Preset</a> and fire it anytime with <kbd>⌥⌘1</kbd>.</li>
</ol>
<p>Before framing your keepers, see how to verify sharpness and exposure in <a href="/en/guides/check-focus-histogram-zebra-mac/">Check focus peaking, AF point, histogram &amp; clipping on Mac</a>.</p>""",
      howto=["Open any photo (JPEG, HEIC, PNG or camera RAW) in Flipic Lens on Mac",
             "Press ⇧B to open the Border bar and check Photo info",
             "Pick an aspect ratio (Original even border, 4:5, 1:1, etc.), background fill (White, Black, Blurred or Custom) and output size",
             "Press Return to save a framed copy, or apply the same EXIF frame to a whole folder in Batch Convert (⇧⌘C)"],
      faq=[
          ("Does adding an EXIF frame modify my original photo or RAW file?",
           "Never. Flipic Lens always writes a new copy (with a border suffix) and leaves your original JPEG or RAW untouched."),
          ("What if a photo has no EXIF metadata?",
           "Flipic Lens skips empty metadata gracefully and renders a clean solid or blurred border without broken placeholders."),
          ("Can I strip GPS location and camera serial numbers when exporting framed photos?",
           "Yes. In Export (⌘S) and Batch Convert (⇧⌘C) you can strip GPS coordinates and camera/lens serial numbers independently while keeping your camera/exposure caption."),
          ("Is the EXIF photo frame free?",
           "Yes. Single framing (⇧B), Export (⌘S) and Batch Convert (⇧⌘C) EXIF frames are all free. Only multi-step saved Export Presets (⌥⌘1–⌥⌘9) are Pro."),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("zh", "/guides/check-focus-histogram-zebra-mac/", "Mac 挑片怎么看对焦框、直方图、焦点峰值与过曝警示",
      "挑片看对焦框与直方图",
      "在 Mac 上不导入 Lightroom 也能看实时 RGB 直方图（H）、过曝红/暗部蓝斑马纹（J）、焦点峰值（K）与索尼/富士相机对焦框（A），免费快速完成技术挑片。",
      "H/J/K/A 四键单图质检：直方图、过曝斑马纹、焦点峰值与相机对焦框",
      f"""<p>拍完几百张 RAW 回到 Mac 上，如果只看缩略图或整张全图，很容易把轻微跑焦、高光死白拉不回来的废片误留进精修文件夹；可为了查这几项专门导入 Lightroom，又得先等半天建预览。在 <a href="/">Flipic Lens</a> 里，打开文件夹直接按 <kbd>H</kbd>、<kbd>J</kbd>、<kbd>K</kbd>、<kbd>A</kbd> 就能在看图窗口里做完一整套摄影技术质检，而且四项全部免费。</p>
<figure>{shot('inspect-suite.webp', 'Flipic Lens 单图摄影质检：左下角 RGB 直方图显示死黑与过曝占比，高光红斜纹、青绿焦点峰值与绿色相机对焦框同屏叠加')}<figcaption>单图窗口同时开启直方图（H）、过曝警示（J）、焦点峰值（K）与相机对焦框（A），顶部可一键改排序或进工作台。</figcaption></figure>
<h2>四个快捷键对应什么质检需求？</h2>
<table><thead><tr><th>快捷键</th><th>工具</th><th>挑片时怎么用</th></tr></thead><tbody>
<tr><td><kbd>H</kbd></td><td>实时 RGB / 亮度直方图</td><td>叠加在角落，底部直接标出死黑占比（<code>S %</code>）和过曝占比（<code>H %</code>），不用猜屏幕亮度是否骗了眼睛。</td></tr>
<tr><td><kbd>J</kbd></td><td>高光 / 暗部斑马纹警示</td><td>高光溢出区域用红色斜纹标出、死黑区域用蓝色斜纹标出，逆光婚纱、雪景、天空云层有没有「死白」一眼看穿。</td></tr>
<tr><td><kbd>K</kbd></td><td>焦点峰值（Focus Peaking）</td><td>用青绿色高亮画面里锐度最高的边缘轮廓，配合连拍快速扫过几十张，立刻看出焦平面落在睫毛、耳朵还是背景墙上。</td></tr>
<tr><td><kbd>A</kbd></td><td>相机原始对焦框（AF Point）</td><td>在画面上画出拍摄瞬间相机锁定的对焦区域，方便复盘到底是对焦偏了还是手抖糊了。</td></tr>
</tbody></table>
<h2>相机对焦框（A）支持哪些品牌与元数据？</h2>
<p>Flipic Lens 会按顺序解析标准与主流相机私有对焦元数据，并且当你按 <kbd>R</kbd> / <kbd>L</kbd> 旋转 90° 后，对焦框、斑马纹和焦点峰值都会自动跟着旋转对齐：</p>
<ul>
<li>标准 EXIF <code>SubjectArea</code>（如 iPhone、部分无反与标准导出文件）</li>
<li>XMP <code>mwg-rs:Regions</code>（区域焦点/主体区域元数据）</li>
<li>Sony MakerNotes（<code>0x2027</code> 对焦位置标签）</li>
<li>Fujifilm MakerNotes（<code>0x1023</code> 对焦像素坐标标签）</li>
</ul>
<h2>配合 100% 放大与多图对比，挑片效率翻倍</h2>
<ul>
<li><strong>按住 <kbd>0</kbd>：</strong>鼠标指在绿色对焦框或人物眼睛上按住 <kbd>0</kbd>，原地放大到 100% 原分辨率看细节，松手瞬间回到全图。</li>
<li><strong><kbd>C</kbd> / <kbd>⇧C</kbd> 并排对比：</strong>连拍两三张拿不准，直接并排同步缩放比较同一块细节；如果需要一次同屏比 5–9 张连拍，可以在 <a href="/pro/">Pro 工作台</a> 里框选最多 9 张自适应铺满对比，右侧独立照片信息栏和直方图会实时跟着当前白框焦点走。</li>
<li><strong><kbd>⇅</kbd> 快捷排序 + 滚轮翻图：</strong>看图右上角随时切按拍摄时间或文件名排序，鼠标移到底部缩略图栏直接滚轮就能翻片。</li>
</ul>
<p>如果是整场活动几百张人像，还可以先按 <kbd>⇧⌘K</kbd> 用 <a href="/guides/burst-closed-eyes-cleanup/">清理模式把闭眼和糊片筛出来</a>，再用 H/J/K/A 精检留下的候选片。</p>""",
      howto=["用 Flipic Lens 双击打开照片文件夹里的任意一张（RAW 或 JPG 均可）",
             "按 H 显示实时 RGB/亮度直方图与死黑/过曝百分比，按 J 开启红蓝过曝暗部斑马纹",
             "按 K 开启青绿焦点峰值检查合焦平面，按 A 叠加相机原始对焦框",
             "将鼠标移至对焦位置按住 0 放大至 100% 复核细节，满意后按 1–5 打星（Lightroom 与 Capture One 直接识别）"],
      faq=[
          ("看直方图、焦点峰值、过曝警示和相机对焦框要付费吗？",
           "不用，H / J / K / A 四项单图质检工具全部免费，包含在开源核心版里。"),
          ("相机 RAW 文件也能显示直方图、焦点峰值和对焦框吗？",
           "可以。直方图、斑马纹和焦点峰值基于当前显示的图像实时计算，对焦框直接读取 RAW 文件头里的 EXIF / MakerNotes（如索尼 ARW、富士 RAF），不修改原文件。"),
          ("为什么有些照片按 A 没有显示对焦框？",
           "部分相机在手动对焦、特定连拍模式或经过剥离 MakerNotes 的后期导出后，文件里不再保留对焦框坐标，此时不会误画假框；可配合 K 焦点峰值和按住 0 放大 100% 检查清晰度。"),
          ("开启这些质检叠加层会不会拖慢翻页？",
           "不会。计算在后台线程完成，切到下一张时立刻取消上一张的旧任务，连按方向键翻页依然跟手。"),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("en", "/en/guides/check-focus-histogram-zebra-mac/", "Check Focus Peaking, Camera AF Point, Histogram & Clipping on Mac",
      "Histogram, peaking & AF point",
      "Check live RGB histogram (H), highlight/shadow clipping zebras (J), focus peaking (K) and camera AF focus point (A) on Mac before importing into Lightroom—free.",
      "Inspect exposure and focus with H/J/K/A before importing to Lightroom",
      f"""<p>Checking a shoot on thumbnails alone lets slightly front-focused frames and unrecoverable blown highlights slip straight into your editing catalog. Importing everything into Lightroom just to verify exposure and sharpness wastes time. With <a href="/en/">Flipic Lens</a>, press <kbd>H</kbd>, <kbd>J</kbd>, <kbd>K</kbd> or <kbd>A</kbd> right inside the folder viewer to run a complete technical check—all four overlays are free.</p>
<figure>{shot('inspect-suite-en.webp', 'Flipic Lens single-viewer inspection suite with RGB histogram, red highlight zebras, cyan focus peaking and green camera AF point box')}<figcaption>Live RGB histogram (H), highlight clipping zebras (J), cyan focus peaking (K) and camera AF reticle (A) running directly on a folder of photos.</figcaption></figure>
<h2>Four single-key inspection overlays</h2>
<table><thead><tr><th>Key</th><th>Overlay</th><th>How it helps while culling</th></tr></thead><tbody>
<tr><td><kbd>H</kbd></td><td>Live RGB &amp; luminance histogram</td><td>Shows RGB + luma curves along with exact shadow (<code>S %</code>) and highlight (<code>H %</code>) clipping percentages so bright displays never fool your exposure check.</td></tr>
<tr><td><kbd>J</kbd></td><td>Highlight &amp; shadow clipping zebras</td><td>Paints clipped highlights in red diagonal stripes and crushed shadows in blue—spot blown wedding dresses, skies or snow instantly.</td></tr>
<tr><td><kbd>K</kbd></td><td>Focus peaking</td><td>Highlights the sharpest high-contrast edges in cyan so you can see immediately across a burst whether focus landed on the eye, ear or background.</td></tr>
<tr><td><kbd>A</kbd></td><td>Camera AF point reticle</td><td>Overlays the autofocus box recorded by the camera at capture so you can separate missed AF from motion blur.</td></tr>
</tbody></table>
<h2>Supported AF point metadata</h2>
<p>Flipic Lens reads both standard and camera-specific AF metadata and keeps every overlay aligned when you rotate photos 90°:</p>
<ul>
<li>Standard EXIF <code>SubjectArea</code></li>
<li>XMP <code>mwg-rs:Regions</code></li>
<li>Sony MakerNotes (<code>0x2027</code> focus position)</li>
<li>Fujifilm MakerNotes (<code>0x1023</code> focus pixel coordinates)</li>
</ul>
<h2>Pair with 100% peek and multi-photo compare</h2>
<ul>
<li><strong>Hold <kbd>0</kbd>:</strong> Point right at the green AF box or subject’s eye and hold <kbd>0</kbd> to zoom to 100% at the pointer; release to snap back to fit.</li>
<li><strong><kbd>C</kbd> / <kbd>⇧C</kbd> side-by-side compare:</strong> Put 2 or 4 frames side by side with synced zoom and pan. For heavier bursts, <a href="/en/pro/">Pro Workbench</a> compares up to 9 photos at once with a live Photo Info card and RGB histogram following the active frame.</li>
<li><strong>Quick sort (<kbd>⇅</kbd>) &amp; filmstrip wheel paging:</strong> Switch sort order right from the top-right bar and roll the mouse wheel over the bottom filmstrip to page smoothly.</li>
</ul>
<p>See also <a href="/en/guides/view-raw-files-mac/">how to quickly view RAW files on a Mac</a> and <a href="/en/guides/compare-photos-side-by-side-mac/">how to compare similar photos side by side</a>.</p>""",
      howto=["Double-click any RAW or JPEG in your shoot folder to open it in Flipic Lens",
             "Press H for the live RGB/luminance histogram and J for red/blue highlight and shadow clipping zebras",
             "Press K for cyan focus peaking and A to overlay the camera’s recorded AF focus box",
             "Point at the subject and hold 0 to verify 100% sharpness, then rate keepers 1–5 (written as Lightroom-compatible XMP)"],
      faq=[
          ("Are histogram, focus peaking, clipping warnings and AF point free?",
           "Yes. All four single-viewer overlays (H, J, K, A) are completely free and part of the open-source core."),
          ("Do they work on camera RAW files?",
           "Yes. Histogram, zebras and peaking compute live from the viewed image, and the AF reticle reads EXIF and Sony/Fujifilm MakerNotes straight from the RAW header without touching the file."),
          ("Why does pressing A show no AF box on some photos?",
           "Manual focus shots, certain camera models or exported images whose MakerNotes were stripped don’t store AF coordinates. Flipic Lens omits the box instead of guessing; use focus peaking (K) and hold 0 at 100% instead."),
          ("Do these overlays slow down rapid arrow-key paging?",
           "No. Overlay computation runs asynchronously off the main thread and cancels stale frames immediately when you keep paging."),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("zh", "/guides/match-client-photo-list-mac/", "客户发来一堆照片编号，Mac 怎么一键挑出对应 RAW 原图？",
      "按客户编号清单挑 RAW 原图",
      "婚礼、人像和商业摄影交付最常遇到客户从微信或邮件发来一串照片编号。用 Flipic Lens「按文件名清单挑图」，整段粘贴自动跨扩展名匹配同名 RAW 原图并一键导出。",
      "微信/邮件粘贴客户选片编号，自动跨扩展名匹配同名 RAW 原图导出",
      f"""<p>拍完婚礼、棚拍或商业活动，发给客户的是带水印压缩 JPG 样片，客户在微信里回过来一段文字：「精修选这几张：DSC04218、4252，还有 4317.jpg 和 IMG_0899，一共 45 张」。如果打开访达或者 Lightroom 一个编号一个编号搜，不仅枯燥，还非常容易漏选或选错同名 JPG 而不是 RAW。</p>
<h2>为什么手动搜编号特别容易踩坑？</h2>
<ul>
<li><strong>客户发来的格式五花八门：</strong>有的写全名 <code>DSC04218.JPG</code>，有的只写数字后四位 <code>4252</code>，中间夹杂中文说明、逗号、顿号或换行。</li>
<li><strong>扩展名对不上：</strong>客户看的是 <code>.jpg</code> 样片，但你精修要提取的是文件夹里的 <code>.ARW</code> / <code>.CR3</code> / <code>.NEF</code> / <code>.RAF</code> 原图，直接按完整文件名搜索根本搜不到 RAW。</li>
<li><strong>RAW + JPG 同名成对：</strong>既要不漏掉 RAW，又不想导出重复张数，还得检查客户有没有手打错一个数字导致某张没匹配上。</li>
</ul>
<h2>用 Flipic Lens 一键按文件名清单挑出原图</h2>
<p>在 <a href="/pro/">Flipic Lens Pro</a>（下载即带 7 天完整试用）里，整个流程只要十几秒：</p>
<ol>
<li>用 Flipic Lens 打开存放 RAW 原图的拍摄文件夹（或在工作台选中这场拍摄项目）。</li>
<li>点顶部菜单「照片 › 按文件名清单挑图…」。</li>
<li>把客户发来的整段微信聊天记录、Excel 列或邮件内容<strong>直接粘贴进去</strong>——不需要先手工删掉中文、逗号或 <code>.jpg</code> 后缀，Flipic Lens 会自动提取里面的文件名与编号。</li>
<li>点匹配后，软件自动忽略扩展名差异（把 <code>DSC04218.jpg</code> 精准对应到 <code>DSC04218.ARW</code>，也支持仅用末尾数字如 <code>4252</code> 匹配，并兼容 RAW+JPG 合并对），并清清楚楚列出「命中多少张」以及「哪几个编号没找到」方便立刻核对。</li>
<li>一键「只看命中照片」复查，然后直接「全部标记（P）」、按 <kbd>⇧⌘E</kbd> 拷贝到精修文件夹，或按 <kbd>⌘E</kbd> 整批送进 Lightroom / Capture One 开始精修。</li>
</ol>
<h2>发样片前的小技巧：让客户选图零出错</h2>
<ul>
<li>发压缩样片前，可以在 Flipic Lens 的免费导出水印里保留原文件名，或者勾选 <code>{{index}}</code> 自动序号，方便客户按编号回复。</li>
<li>如果是多机位婚礼拍摄，建议先把所有机位用 <a href="/guides/exif-batch-rename-photos-mac/">EXIF 模板批量重命名</a> 统一成「拍摄时间 + 序号」，彻底避免两台机身撞文件名（例如同时出现 <code>DSC01234</code>）。</li>
</ul>
<p>如果是你自己先初筛几百张活动照，见 <a href="/guides/cull-event-photos/">Mac 上怎么挑活动照片</a>；批量挑片工具详见 <a href="/pro/">Flipic Lens Pro 介绍</a>。</p>""",
      howto=["在 Flipic Lens 中打开存放 RAW 原图的拍摄文件夹",
             "打开菜单「照片 › 按文件名清单挑图…」",
             "将客户从微信、飞书或邮件发来的整段照片编号直接粘贴进输入框，无需清理逗号或 .jpg 后缀",
             "确认匹配数量与未命中提示，一键筛选命中照片并标记（P）、导出（⇧⌘E）或批量送进 Lightroom / Capture One（⌘E）"],
      faq=[
          ("客户只发了后四位数字（比如 4218、4252），没有前缀 DSC 能匹配吗？",
           "能。文件名清单匹配支持完整文件名、去掉扩展名的词干以及末尾编号匹配，同时会标出没匹配到或一拖多的条目供核对。"),
          ("客户清单里写的是 .jpg，能挑出文件夹里的 .ARW / .CR3 / .NEF / .RAF 吗？",
           "可以，这就是核心设计场景：匹配会自动跨扩展名对应到同名 RAW 原图，开启 RAW+JPG 合并显示时也不会算重。"),
          ("按客户文件名清单挑图是免费功能还是 Pro 功能？",
           "属于 Flipic Lens Pro（官网 ¥68 一次买断），但每次下载安装包都自带 7 天完整免费试用，刚好有单子要交片可以直接先试。"),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("en", "/en/guides/match-client-photo-list-mac/", "Match Photos from a Client’s Filename List on Mac (JPG to RAW)",
      "Match client photo list",
      "Paste a client’s messy list of photo filenames or trailing numbers from chat or email on Mac to match and extract the original RAW files (.ARW, .CR3, .NEF, .RAF) in one step.",
      "Paste client filenames from chat or email to extract matching RAWs",
      f"""<p>Every wedding, portrait and commercial photographer knows this message: you deliver watermarked JPG proofs, and the client replies in email or chat with “Please retouch DSC04218, 4252, 4317.jpg and IMG_0899 (45 total).” Hunting down dozens of files one by one in Finder or Lightroom is tedious, slow and prone to missed frames.</p>
<h2>Why manual filename searching breaks down</h2>
<ul>
<li><strong>Messy client formatting:</strong> Clients mix full names (<code>DSC04218.JPG</code>), trailing digits (<code>4252</code>), commas, bullet points and comments in one paragraph.</li>
<li><strong>Extension mismatch:</strong> Clients read <code>.jpg</code> proofs, while you need the matching <code>.ARW</code>, <code>.CR3</code>, <code>.NEF</code> or <code>.RAF</code> originals for retouching.</li>
<li><strong>Typo risk:</strong> If a client mistypes one digit, manual searches rarely give you a clear unmatched list at the end.</li>
</ul>
<h2>Match and extract RAWs in seconds with Flipic Lens</h2>
<p>In <a href="/en/pro/">Flipic Lens Pro</a> (every download includes a full 7-day trial), the workflow takes seconds:</p>
<ol>
<li>Open your shoot’s RAW folder in Flipic Lens (or pick the shoot project in Workbench).</li>
<li>Choose <strong>Photo › Match from Filename List…</strong>.</li>
<li>Paste the client’s entire email or chat block straight into the box—no need to strip commentary, commas or <code>.jpg</code> extensions.</li>
<li>Flipic Lens automatically matches across extensions (<code>DSC04218.jpg</code> → <code>DSC04218.ARW</code>), handles trailing numbers and RAW+JPG pairs, and clearly lists both matched files and any unmatched typos.</li>
<li>Click to filter down to the matched keepers, mark them all (<kbd>P</kbd>), copy the RAWs to a retouch folder (<kbd>⇧⌘E</kbd>), or open the whole batch directly in Lightroom or Capture One (<kbd>⌘E</kbd>).</li>
</ol>
<h2>Two workflow tips before sending proofs</h2>
<ul>
<li>When exporting proof JPGs with Flipic Lens’s free export watermark, keep original filenames or add the <code>{{index}}</code> sequence token so clients can reference exact frames unambiguously.</li>
<li>For multi-camera weddings, run <a href="/en/guides/exif-batch-rename-photos-mac/">EXIF template batch rename</a> first so two bodies never produce colliding numbers like <code>DSC01234</code>.</li>
</ul>
<p>For first-pass culling before sending proofs, see <a href="/en/guides/cull-photos-on-mac/">how to cull hundreds of event photos on a Mac</a>.</p>""",
      howto=["Open your shoot folder containing the original RAW files in Flipic Lens",
             "Select Photo › Match from Filename List… from the menu bar",
             "Paste the client’s raw text list from email, WhatsApp or Slack without cleaning punctuation or .jpg extensions",
             "Review matched vs unmatched items, filter to the matches, then copy out (⇧⌘E) or open the batch in Lightroom / Capture One (⌘E)"],
      faq=[
          ("Does it work if the client only sends the last four digits like 4218 instead of DSC04218.ARW?",
           "Yes. Flipic Lens matches full filenames, stems without extensions, and trailing sequence digits, flagging any unmatched or ambiguous entries clearly."),
          ("Will a list of .jpg filenames match my .ARW, .CR3, .NEF or .RAF RAW files?",
           "Yes—cross-extension matching is built in, and merged RAW+JPG pairs are handled cleanly without duplicates."),
          ("Is Match from Filename List free or Pro?",
           "It is part of Flipic Lens Pro ($12.99 one-time), and every download includes a full 7-day trial so you can test it on a real client delivery first."),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("zh", "/guides/exif-batch-rename-photos-mac/", "Mac 按拍摄日期、相机与焦距批量重命名照片（同步 .xmp）",
      "EXIF 批量重命名同步 .xmp",
      "访达自带改名读不了拍摄时间，还会把 RAW 和 .xmp、实况照片 .MOV 拆散。用 Flipic Lens 免费按 EXIF 变量模板批量重命名，支持前 3 张实时预览并同步改名附属文件。",
      "用 {date} {camera} {focal} 模板免费批量改名，同步 .xmp 与 .MOV",
      f"""<p>婚礼双机位合轨、商业活动按场次归档，或者要把相机默认的 <code>DSC01234.ARW</code> 改成「日期_机身_序号」时，macOS 访达自带的「重新命名」很快就会碰到两个硬伤：</p>
<ul>
<li><strong>读不了 EXIF 拍摄时间与器材参数：</strong>访达只能填死固定文字加序号，按文件修改时间排还常常因为复制拷盘被改乱。</li>
<li><strong>把附属文件拆散：</strong>只选照片改名时，旁边同名的 Lightroom 评分/调色文件 <code>.xmp</code>、以及 iPhone 实况照片的 <code>.MOV</code> 不会跟着改名，改完星级和实况全丢了。</li>
</ul>
<h2>用 Flipic Lens EXIF 模板免费批量重命名</h2>
<p>在 <a href="/">Flipic Lens</a> 里打开文件夹，按 <kbd>⇧⌘B</kbd>（菜单「文件 › 批量重命名…」）就能按拍摄信息一次改完，<strong>完全免费</strong>：</p>
<table><thead><tr><th>变量</th><th>含义</th><th>示例结果</th></tr></thead><tbody>
<tr><td><code>{{date}}</code></td><td>EXIF 拍摄日期（缺 EXIF 自动回落创建日期）</td><td><code>20261123</code></td></tr>
<tr><td><code>{{time}}</code></td><td>EXIF 拍摄时分秒（多机位合轨排序神器）</td><td><code>143508</code></td></tr>
<tr><td><code>{{camera}}</code></td><td>机身型号</td><td><code>ILCE-7M4</code></td></tr>
<tr><td><code>{{focal}}</code></td><td>镜头焦距</td><td><code>35mm</code></td></tr>
<tr><td><code>{{name}}</code></td><td>保留原文件名词干</td><td><code>DSC04218</code></td></tr>
<tr><td><code>{{seq}}</code></td><td>自动补零递增序号（支持起始编号）</td><td><code>001</code>、<code>002</code></td></tr>
</tbody></table>
<h2>5 套常用摄影预设 + 实时预览，不怕改坏</h2>
<ol>
<li>按 <kbd>⇧⌘B</kbd> 打开批量重命名窗口，可以直接点内置的 5 套常用摄影模板（如 <code>{{date}}_{{seq}}</code>、<code>{{date}}_{{time}}_{{seq}}</code>、<code>{{date}}_{{camera}}_{{seq}}</code>、<code>{{date}}_{{focal}}_{{seq}}</code>），也可以自由组合变量，或者只填一个纯前缀自动编号。</li>
<li>窗口下方实时列出<strong>前 3 张改名前后的完整对照</strong>，确认格式无误再点应用。</li>
<li>遇到重名会自动安全避让，绝不覆盖已有文件；同名的 <code>.xmp</code> 评分/修图附属文件和实况照片 <code>.MOV</code> 会同步改成一致的新文件名（在 <a href="/pro/">Pro</a> 中还可以自定义关联 <code>.dop</code>、<code>.pp3</code> 等更多后期附属文件）。</li>
</ol>
<p>改完名配合 <a href="/guides/star-rating-lightroom/">Lightroom 互通打星</a> 或 <a href="/guides/match-client-photo-list-mac/">按客户文件名清单挑图</a>，整套交付链路清晰不会撞号。</p>""",
      howto=["在 Flipic Lens 中打开要整理的照片文件夹，先用右上角 ⇅ 按拍摄时间或你需要的顺序排好",
             "按 ⇧⌘B 打开「批量重命名」对话框",
             "选择内置摄影模板或输入 {date}、{time}、{camera}、{focal}、{name}、{seq} 自由组合",
             "核对下方前 3 张实时预览结果后点确定，照片与同名 .xmp / .MOV 会同步改名"],
      faq=[
          ("批量重命名会自动同步 RAW 旁边的 .xmp 文件吗？",
           "会。无论免费版还是 Pro，同名的 .xmp 与实况照片 .MOV 都会跟着照片一起改名，Lightroom 和 Capture One 里的星级与调色不会断链。"),
          ("如果文件夹里混有截图或没有 EXIF 的 PNG 怎么办？",
           "缺少 EXIF 拍摄日期时自动回落文件创建日期，缺少相机或焦距标签的占位段会自动省略，不会拼出多余的下划线或空字段。"),
          ("多机位照片怎么按实际拍摄顺序统一编号？",
           "先在看图窗口右上角点 ⇅ 选「按拍摄时间」排序，再按 ⇧⌘B 用 {date}_{time}_{camera}_{seq} 模板一次改名即可。"),
          ("EXIF 模板批量重命名收费吗？",
           "完全免费，包含在 Flipic Lens 开源核心版中。"),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("en", "/en/guides/exif-batch-rename-photos-mac/", "Batch Rename Photos by EXIF Date, Camera & Focal Length on Mac",
      "EXIF batch rename on Mac",
      "Finder’s batch rename can’t read EXIF capture time or camera models and breaks .xmp and Live Photo .MOV pairs. Rename photos with {date}, {camera}, {focal} and {seq} tokens for free in Flipic Lens.",
      "Free EXIF template rename keeping .xmp and Live Photo .MOV in sync",
      f"""<p>Merging two camera bodies from a wedding, archiving commercial shoots by date, or turning generic <code>DSC01234.ARW</code> files into clean names quickly exposes two flaws in macOS Finder’s built-in Rename tool:</p>
<ul>
<li><strong>No EXIF access:</strong> Finder cannot read Date Taken, camera body or focal length, and file modification times change whenever files are copied across drives.</li>
<li><strong>Broken sidecars:</strong> Renaming RAW files in Finder leaves companion Lightroom <code>.xmp</code> sidecars and iPhone Live Photo <code>.MOV</code> clips behind, breaking ratings and edits.</li>
</ul>
<h2>Free EXIF template batch rename in Flipic Lens</h2>
<p>Open any folder in <a href="/en/">Flipic Lens</a> and press <kbd>⇧⌘B</kbd> (File › Batch Rename…)—completely free:</p>
<table><thead><tr><th>Token</th><th>Meaning</th><th>Example</th></tr></thead><tbody>
<tr><td><code>{{date}}</code></td><td>EXIF capture date (falls back to creation date)</td><td><code>20261123</code></td></tr>
<tr><td><code>{{time}}</code></td><td>EXIF capture time HHMMSS (great for multi-camera sync)</td><td><code>143508</code></td></tr>
<tr><td><code>{{camera}}</code></td><td>Camera model</td><td><code>ILCE-7M4</code></td></tr>
<tr><td><code>{{focal}}</code></td><td>Focal length</td><td><code>35mm</code></td></tr>
<tr><td><code>{{name}}</code></td><td>Original filename stem</td><td><code>DSC04218</code></td></tr>
<tr><td><code>{{seq}}</code></td><td>Zero-padded sequence number</td><td><code>001</code>, <code>002</code></td></tr>
</tbody></table>
<h2>Five presets, live preview and companion sidecar sync</h2>
<ol>
<li>Press <kbd>⇧⌘B</kbd> and pick one of five built-in photography presets (such as <code>{{date}}_{{seq}}</code>, <code>{{date}}_{{time}}_{{seq}}</code>, <code>{{date}}_{{camera}}_{{seq}}</code>) or compose your own template. Plain prefixes still auto-number just like before.</li>
<li>Check the live preview of the first 3 files before touching disk.</li>
<li>Name collisions are avoided safely, and matching <code>.xmp</code> sidecars and Live Photo <code>.MOV</code> files rename in lockstep (<a href="/en/pro/">Pro</a> also lets you link custom sidecars like <code>.dop</code> and <code>.pp3</code>).</li>
</ol>
<p>Pair with <a href="/en/guides/match-client-photo-list-mac/">matching client filename lists</a> so two cameras from the same event never collide on delivery.</p>""",
      howto=["Open your photo folder in Flipic Lens and sort by Capture Date using the top-right ⇅ sort menu",
             "Press ⇧⌘B to open Batch Rename",
             "Pick a preset or combine {date}, {time}, {camera}, {focal}, {name} and {seq} tokens",
             "Verify the live 3-file preview and confirm; companion .xmp and .MOV sidecars rename together"],
      faq=[
          ("Will batch renaming keep my Lightroom .xmp sidecars linked to my RAW files?",
           "Yes. Companion .xmp files and Live Photo .MOV clips automatically receive the exact same new base name."),
          ("What happens if a folder contains screenshots or PNGs without EXIF?",
           "Missing EXIF capture dates fall back to file creation date, and missing camera/focal tokens are omitted cleanly without ugly double separators."),
          ("Is EXIF template batch rename free?",
           "Yes, it is completely free in both the website version and the Mac App Store version."),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("zh", "/guides/cube-lut-preview-photos-mac/", "Mac 上怎么实时套用 .cube 3D LUT 与胶片滤镜看图和批量导出",
      "Mac 套用 .cube LUT 看图导出",
      "在 Mac 上不用进 Lightroom 或达芬奇，直接给 JPG 和相机 RAW 实时预览十款胶片滤镜或自定义 .cube 3D LUT，支持强度/颗粒/光晕调节与整组批量导出。",
      "⇧F 实时预览胶片色与自定义 .cube 3D LUT，不伤原图，一键批量导出",
      f"""<p>手里存了一堆富士胶片模拟、索尼 S-Log/创意风格或者达芬奇导出的 <code>.cube</code> 3D LUT，想直接套在一组静物或旅拍照片上看看成片氛围、甚至顺手导出一批直出图，过去只能先导入 Lightroom 建配置文件，或者拉进 Photoshop / 达芬奇一张张处理。在 <a href="/">Flipic Lens</a> 里按 <kbd>⇧F</kbd>，看图翻页时就能实时套色并整批导出，而且原图一个字节都不改。</p>
<figure>{shot('film.webp', 'Flipic Lens 胶片滤镜面板：十款胶片效果缩略图预览与强度、颗粒、光晕滑块')}<figcaption>按 ⇧F 打开胶片滤镜面板，每格都是当前照片的真实套色缩略图，翻到下一张效果持续保持。</figcaption></figure>
<h2>十款内置胶片滤镜 + 自定义 .cube 3D LUT</h2>
<ul>
<li><strong>免费内置 2 款：</strong>「暖调人像」和「经典黑白」直接免费使用，开箱即可调强度、颗粒与光晕。</li>
<li><strong>Pro 解锁全部 10 款 + 导入自定义 <code>.cube</code>：</strong>包含日常暖色、浓郁反转片、清冷薄荷、细腻鲜艳、电影夜色、纪实灰调、柔和黑白、粗颗粒黑白，并支持直接导入任意标准 3D <code>.cube</code> LUT 文件（17 / 33 / 64 / 65 级全部兼容，超过 64 级自动高质量重采样）。下载后自带 7 天免费试用。</li>
</ul>
<h2>高效翻片预览与批量套色导出</h2>
<ol>
<li>看图时按 <kbd>⇧F</kbd> 打开面板，点缩略图切换胶片或点「导入 .cube…」加载自己的 LUT，下面拖滑块调强度（颗粒与光晕也可独立调节）。</li>
<li>继续按 <kbd>←</kbd> <kbd>→</kbd> 翻看整组照片：选中的滤镜/LUT 会一路保持；按住 <kbd>\\</kbd> 随时对比原图，按 <kbd>G</kbd> 快速开关，按 <kbd>,</kbd> / <kbd>.</kbd> 切换上一款或下一款。</li>
<li>想保留成片时：单张直接点「另存一份…」（完整保留 EXIF、图说与 GPS），整批导出在 <kbd>⌘S</kbd> 导出、<kbd>⇧⌘C</kbd> 批量转换或 <a href="/pro/">Pro 导出预设（⌥⌘1–⌥⌘9）</a> 里勾选对应胶片/LUT，一次全部输出。</li>
</ol>
<p>导出时还可以叠加 <a href="/guides/exif-photo-frame-mac/">EXIF 参数相框（⇧B）</a> 与水印，一步完成发图前的所有处理。</p>""",
      howto=["用 Flipic Lens 打开照片文件夹，按 ⇧F 打开胶片滤镜面板",
             "点击内置胶片缩略图，或点击导入自己的 17/33/64/65 级 .cube 3D LUT 文件",
             "调节强度、颗粒和光晕滑块，按 ← → 翻看整组照片实时效果（按住 \\ 对比原图）",
             "点击「另存一份…」保存单张，或在 ⇧⌘C 批量转换与导出预设中对整组照片批量套用导出"],
      faq=[
          ("导入的 .cube 3D LUT 支持哪些尺寸？会改坏原图吗？",
           "支持标准 3D .cube 文件（常见的 17、33、64、65 级均可，超过 64 级自动重采样到 Metal/CoreImage 64 级上限）。预览完全非破坏性，原图和 RAW 永远不会被修改。"),
          ("视频、GIF 动图和 HDR 照片会套用滤镜吗？",
           "不会，Flipic Lens 会自动跳过视频、动图与 HDR 照片，避免色彩空间映射失真。"),
          ("哪些胶片滤镜免费，哪些需要 Pro？",
           "「暖调人像」和「经典黑白」永久免费；其余八款胶片滤镜和导入自定义 .cube 3D LUT 属于 Pro（一次买断，下载安装包自带 7 天完整试用）。"),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("en", "/en/guides/cube-lut-preview-photos-mac/", "Preview & Batch Export Photos with .cube 3D LUTs on Mac",
      "Preview .cube LUTs on Mac",
      "Preview built-in film looks or your own 17/33/64/65-point .cube 3D LUTs live while paging through JPGs and RAWs on Mac, with non-destructive Strength/Grain sliders and batch export.",
      "Apply film looks or custom .cube 3D LUTs live on Mac without touching originals",
      f"""<p>If you collect Fujifilm film recipes, Sony Look LUTs or DaVinci Resolve <code>.cube</code> files and want to preview how they look across a folder of stills—or batch-export a graded set—you usually have to wrap them into Lightroom profiles or load them into Photoshop one by one. In <a href="/en/">Flipic Lens</a>, press <kbd>⇧F</kbd> to preview film looks and custom <code>.cube</code> 3D LUTs live as you page through a shoot, without touching your originals.</p>
<figure>{shot('film-en.webp', 'Flipic Lens Film Looks panel showing live photo swatches with Strength, Grain and Halation sliders')}<figcaption>Press ⇧F to compare swatches of the current photo; the look stays active as you page through the whole shoot.</figcaption></figure>
<h2>Ten built-in film looks + custom .cube 3D LUT import</h2>
<ul>
<li><strong>Free built-in looks:</strong> Warm Portrait and Classic B&amp;W are completely free, including Strength, Grain and Halation sliders.</li>
<li><strong>Pro unlocks all 10 looks + custom <code>.cube</code> import:</strong> Adds Everyday Warm, Rich Slide, Cool Mint, Fine Color, Cinema Night, Muted Gray, Soft B&amp;W and Coarse B&amp;W, plus importing your own 3D <code>.cube</code> LUTs (17, 33, 64 and 65-point tables supported; grids above 64 resample cleanly). Everything is unlocked during the 7-day trial.</li>
</ul>
<h2>Live shoot preview and batch export</h2>
<ol>
<li>Press <kbd>⇧F</kbd> in the viewer, pick a swatch or import your <code>.cube</code> file, and dial in Strength, Grain and Halation.</li>
<li>Page through the folder with <kbd>←</kbd> <kbd>→</kbd> while the look stays on. Hold <kbd>\\</kbd> anytime to peek at the original, press <kbd>G</kbd> to toggle on/off, and <kbd>,</kbd> / <kbd>.</kbd> to cycle looks.</li>
<li>Click Save a Copy… for a single photo (EXIF, captions and GPS stay intact), or apply any built-in look or imported <code>.cube</code> LUT across a folder via Export (<kbd>⌘S</kbd>), Batch Convert (<kbd>⇧⌘C</kbd>) or <a href="/en/pro/">Pro Export Presets (⌥⌘1–⌥⌘9)</a>.</li>
</ol>
<p>You can even combine a film look or LUT with an <a href="/en/guides/exif-photo-frame-mac/">EXIF photo frame (⇧B)</a> and watermark in a single export pass.</p>""",
      howto=["Open your shoot folder in Flipic Lens and press ⇧F to open the Film Looks panel",
             "Pick a built-in look or import a 17/33/64/65-point .cube 3D LUT file",
             "Adjust Strength, Grain and Halation and page through the shoot with ← → (hold \\ to compare with the original)",
             "Click Save a Copy… for one photo, or apply the look/LUT to a whole folder in Batch Convert (⇧⌘C) or Export Presets"],
      faq=[
          ("Which .cube 3D LUT sizes are supported, and are originals modified?",
           "Standard 3D .cube files (17, 33, 64 and 65-point cubes) work directly; grids larger than 64 resample automatically. Previewing is 100% non-destructive and never alters your JPEG or RAW originals."),
          ("Are videos, animated GIFs and HDR photos affected?",
           "No. Flipic Lens automatically skips videos, animated images and HDR photos to avoid color-space clipping."),
          ("Which film looks are free and which need Pro?",
           "Warm Portrait and Classic B&W are free forever. The other eight looks and custom .cube 3D LUT import are Pro ($12.99 one-time, with a full 7-day trial in every download)."),
      ], title_suffix=False, updated="2026-11-23", published="2026-11-23")

guide("zh", "/guides/fix-wrong-image-extension-mac/", "Mac 访达不显示 JPG 缩略图？豆包/网页图片实际是 PNG 或 WebP 一键修复",
      "Mac 访达不显示假 JPG 缩略图",
      "豆包、即梦、小红书或微信网页保存的图片经常后缀是 .jpg，但实际内容是 PNG 或 WebP，导致 Mac 访达只显示通用 JPG 图标、Photoshop 报错。用 Flipic Lens 免费一键检测并批量修复。",
      "一键检测并无损修正 PNG/WebP 伪装的 .jpg，立刻恢复 Mac 访达缩略图",
      f"""<p>用豆包、即梦、Midjourney 或者从网页保存图片到 Mac，经常遇到一整个文件夹里的 <code>.jpg</code> 在访达里<strong>全都不显示缩略图</strong>，只剩一张空白的通用 JPG 文档图标；拖进 Photoshop 还会弹出「无法完成请求，因为找到了未知或无效的 JPEG 标记类型」。</p>
<h2>为什么 Mac 访达显示不出缩略图？</h2>
<p>并不是图片坏了，而是<strong>文件后缀和实际图像格式不符</strong>——很多 AI 绘图工具或图床实际下发的是 <code>PNG</code>（文件头 <code>89 50 4E 47</code>）或 <code>WebP</code>（文件头 <code>RIFF…WEBP</code>），下载时却顺手命名成了 <code>.jpg</code>。</p>
<p>macOS 访达生成缩略图时依赖系统的 <code>QLThumbnailGenerator</code>，先按后缀 <code>.jpg</code> 调用 JPEG 解码器，读到 PNG/WebP 数据直接失败（返回 <code>QLThumbnailErrorDomain error 0</code>），于是只能退回通用 JPG 图标。无论默认看图软件是系统「预览」还是其他软件，都会出现同样的问题。</p>
<h2>用 Flipic Lens 免费一键修复（单张 + 整文件夹批量）</h2>
<p><a href="/">Flipic Lens</a> 1.0.63 起内置免费「错误图片后缀检测与修复」，只读每张图文件头前 32 字节（几百张只需几十毫秒，跳过所有相机 RAW 与视频零误报）：</p>
<ol>
<li><strong>单张打开即修：</strong>双击文件夹里任意一张「假 JPG」，Flipic Lens 正常显示画面的同时，会在顶部弹出一条轻提示（照片信息栏 <kbd>I</kbd> 与右键菜单也会同步标出），点一下「修正为 .png」即可无损改名，回到访达缩略图立刻出现。</li>
<li><strong>整文件夹批量修复：</strong>点顶部轻提示里的「修复整个文件夹…」，或在菜单栏打开「工具 › 修复错误的图片后缀…」（Pro 工作台同样可用），一次列出文件夹里所有错配文件（支持 PNG / JPEG / WebP / GIF / HEIC / AVIF / TIFF 互相检测）。</li>
<li><strong>两种修复方式按需选：</strong>
<ul>
<li><strong>修正为真实后缀（推荐，无损最快）：</strong>只改后缀（如 <code>.jpg → .png</code>），不重新压缩、不损画质，重名自动避让并保留创建时间、访达标签与同名 <code>.xmp</code> / <code>.MOV</code>。</li>
<li><strong>转为真正的 JPEG（保留 <code>.jpg</code> 文件名）：</strong>如果你要把图传给只收 JPG 的平台，可以一键重编码为标准 JPEG（质量 92%，带透明通道的 PNG 自动铺白底不变黑），保留 EXIF 与访达标签，访达缩略图同样立刻恢复。</li>
</ul></li>
</ol>
<p>另外，如果之后你需要给修复好的照片批量转格式或按 EXIF 批量改名，见 <a href="/guides/heic-to-jpg-mac/">Mac 批量转 JPG</a> 与 <a href="/guides/exif-batch-rename-photos-mac/">EXIF 模板批量重命名</a>。</p>""",
      howto=["用 Flipic Lens 打开访达里不显示缩略图的图片文件夹（或双击其中一张图片）",
             "看到顶部提示「实际为 PNG（后缀是 .jpg）」时，单张直接点「修正为 .png」",
             "整个文件夹有多张错配图时，点「修复整个文件夹…」或菜单「工具 › 修复错误的图片后缀…」",
             "选择「修正为真实后缀（无损）」或「转为真正的 JPEG（保留 .jpg）」，点开始修复后回到访达即可看到全部缩略图"],
      faq=[
          ("为什么换了默认看图软件后，这些图上显示的是该软件的 JPG 图标？",
           "访达生成缩略图失败时，会回退显示「该后缀默认打开软件」的文档图标。并不是看图软件弄坏了缩略图，只要把假后缀修正为真实格式或转为真 JPEG，缩略图就会立刻恢复。"),
          ("把 .jpg 改成 .png 会不会损失画质？",
           "完全不会。文件本来就是 PNG 编码，修正后缀只是把文件名改对，不重新压缩，一个像素都不会变。"),
          ("批量扫描会不会误改我的相机 RAW（ARW / CR3 / NEF / DNG）？",
           "不会。检测逻辑会明确跳过所有相机 RAW 和视频文件，只检查常见静图格式的文件头魔数。"),
          ("这个功能收费吗？",
           "完全免费，包含在 Flipic Lens 开源核心版里，不需要买 Pro。"),
      ], title_suffix=False, updated="2026-11-24", published="2026-11-24")

guide("en", "/en/guides/fix-wrong-image-extension-mac/", "JPG Files Not Showing Thumbnails in Mac Finder? Fix Mismatched Extensions",
      "Fix missing Finder JPG thumbnails",
      "AI generators and websites often save PNG or WebP images with a .jpg extension, causing macOS Finder thumbnails to fail and Photoshop to report invalid JPEG markers. Detect and batch-fix them for free with Flipic Lens.",
      "Detect and fix PNG/WebP files saved as .jpg so Mac Finder thumbnails work again",
      f"""<p>Images saved from AI generators or web downloads often end in <code>.jpg</code> even though the file inside is actually <code>PNG</code> or <code>WebP</code>. In macOS Finder, those files refuse to show image previews—displaying only a generic JPG document icon—and Photoshop fails to open them with “an unknown or invalid JPEG marker type is found.”</p>
<h2>Why macOS Finder fails to generate thumbnails</h2>
<p>Finder’s thumbnail service (<code>QLThumbnailGenerator</code>) chooses its decoder from the file extension first. When a file named <code>.jpg</code> starts with PNG (<code>89 50 4E 47</code>) or WebP (<code>RIFF…WEBP</code>) magic bytes, macOS fails with <code>QLThumbnailErrorDomain error 0</code> and falls back to the default app’s generic JPG icon.</p>
<h2>Fix one photo or an entire folder for free in Flipic Lens</h2>
<p>Starting in 1.0.63, <a href="/en/">Flipic Lens</a> includes free mismatched-extension detection and batch repair. It inspects only the first 32 header bytes (scanning hundreds of files in milliseconds while safely skipping all camera RAW and video files):</p>
<ol>
<li><strong>Fix on sight while viewing:</strong> Double-click any broken <code>.jpg</code>. Flipic Lens displays the image normally and shows a dismissible banner at the top (plus an inline card in Photo Info <kbd>I</kbd> and the right-click menu). Click <strong>Rename to .png</strong> for an instant lossless fix.</li>
<li><strong>Batch-fix a whole folder:</strong> Click <strong>Fix Folder…</strong> on the banner or choose <strong>Tools › Fix Mismatched Extensions…</strong> (also available in Workbench) to list every mismatched PNG, JPEG, WebP, GIF, HEIC, AVIF or TIFF file in the folder.</li>
<li><strong>Choose lossless rename or real JPEG:</strong>
<ul>
<li><strong>Rename to actual extension (recommended, lossless):</strong> Changes only the extension (<code>.jpg → .png</code>) with zero recompression, collision-safe naming, and synchronized <code>.xmp</code> / <code>.MOV</code> sidecars. Finder thumbnails appear immediately.</li>
<li><strong>Convert to real JPEG (keep <code>.jpg</code> filename):</strong> Re-encodes to standard JPEG (92% quality, automatically flattening transparent PNG backgrounds to white) while preserving EXIF and Finder tags.</li>
</ul></li>
</ol>
<p>Need to convert real HEIC folders to JPG too? See <a href="/en/guides/batch-convert-heic-to-jpg-mac/">how to batch convert HEIC to JPG on Mac</a>.</p>""",
      howto=["Open a folder with missing JPG thumbnails in Flipic Lens on Mac",
             "Click Rename to .png on the top banner for a single file, or choose Tools › Fix Mismatched Extensions… for the whole folder",
             "Pick Rename to actual extension (lossless) or Convert to real JPEG (keep .jpg filename)",
             "Click Fix Selected—macOS Finder immediately renders thumbnails for every repaired photo"],
      faq=[
          ("Why do the broken JPG files show my viewer app’s icon instead of a photo preview?",
           "Whenever macOS QuickLook fails to decode a thumbnail, Finder falls back to the generic document icon of whichever app is set as default for .jpg. Fixing the extension or converting to real JPEG restores previews immediately."),
          ("Does renaming .jpg to .png reduce image quality?",
           "Not at all. The pixels are already PNG—renaming only fixes the file extension with zero recompression."),
          ("Will batch scanning ever touch my camera RAW files (ARW, CR3, NEF, DNG)?",
           "No. All camera RAW formats and videos are explicitly excluded from mismatch detection."),
          ("Is Fix Mismatched Extensions free?",
           "Yes, it is completely free in the open-source core of Flipic Lens."),
      ], title_suffix=False, updated="2026-11-24", published="2026-11-24")



# ---------------------------------------------------------------- 渲染

WAITLIST = {
    "zh": {
        "h": "想要 Windows 版吗",
        "p": "现在只有 Mac 版，Windows 版还没有，也不一定会做。想用的话留个邮箱，人够多我们就做。做出来只发一封邮件告诉你，邮箱不会用在别的地方。",
        "label": "邮箱", "ph": "你的邮箱", "btn": "留下邮箱", "link": "用 Windows？",
        "sending": "提交中", "ok": "记下了，做出来会告诉你。",
        "invalid": "这个邮箱看起来不对，检查一下再试。",
        "error": "没提交成功，过一会儿再试一次。",
        "busy": "今天提交的人太多了，明天再试一次。",
        "nojs": "提交需要开启 JavaScript。",
    },
    "en": {
        "h": "Want a Windows version?",
        "p": "Flipic Lens only runs on Mac for now. There is no Windows version yet, and no promise of one. If you would use it, leave your email. If enough people ask, we will build it, and we will send you one email when it is ready. We use the address for nothing else.",
        "label": "Email", "ph": "Your email", "btn": "Notify me", "link": "On Windows?",
        "sending": "Sending", "ok": "Got it. We will tell you if it gets made.",
        "invalid": "That email address doesn\u2019t look right. Please check it and try again.",
        "error": "That didn\u2019t go through. Please try again in a moment.",
        "busy": "Too many sign-ups today. Please try again tomorrow.",
        "nojs": "You need JavaScript turned on to submit this.",
    },
}


def waitlist_block(lang):
    w = WAITLIST[lang]
    msgs = {k: w[k] for k in ("sending", "ok", "invalid", "error", "busy")}
    return f"""<section class="wrap waitlist" id="windows">
  <h2>{w['h']}</h2>
  <p>{w['p']}</p>
  <form class="wl-form" data-lang="{lang}" data-msg="{esc(json.dumps(msgs, ensure_ascii=False))}" novalidate hidden>
    <label class="sr" for="wl-email">{w['label']}</label>
    <input id="wl-email" type="email" name="email" inputmode="email" autocomplete="email" maxlength="254" placeholder="{w['ph']}" required>
    <div class="wl-hp" aria-hidden="true"><input type="text" name="website" tabindex="-1" autocomplete="off"></div>
    <button class="btn" type="submit">{w['btn']}</button>
  </form>
  <p class="wl-status" role="status" aria-live="polite"></p>
  <noscript><p class="wl-status">{w['nojs']}</p></noscript>
</section>
"""


HOME_PRO = {
    "zh": ("免费版够用吗", "够用。上面说的看图、质检、打星、参数相框和批量工具都是免费的，以后也会一直免费。如果你经常一次要挑几百上千张照片，可以看看 Pro：里面有 5 视图多项目工作台（含 2–9 图同屏对比与独立照片信息栏）、放大到眼睛、按客户文件名清单挑图、自定义 .cube 3D LUT、另外八款胶片滤镜和导出预设，一次买断。平时看看照片的话用不上，不用买。", "/pro/", "看看 Pro 有什么"),
    "en": ("Is the free version enough?", "Yes. Everything above—viewing, inspection overlays, ratings, EXIF frames and batch tools—is free and will stay free. If you regularly cull hundreds or thousands of photos per shoot, take a look at Pro: it adds the 5-view Workbench (with 2–9 multi-photo compare and a docked Photo Info card), zoom to eyes, matching from a client’s filename list, custom .cube 3D LUTs, the other eight film looks and export presets for a one-time price.", "/en/pro/", "See what Pro adds"),
}


def render_home(lang):
    h = HOME[lang]
    t = T[lang]
    path = t["home"]
    schema = [app_schema(lang, h["desc"]), faq_schema(h["faq"] + (h["wm_faq"] if SHOW_WATERMARK else [])),
              {"@context": "https://schema.org", "@type": "WebSite", "name": "Flipic Lens", "url": f"{BASE}{path}", "inLanguage": t["lang"]}]
    out = head(lang, path, h["title"], h["desc"], schema) + header(lang, path)
    first = f'<img class="on" src="{SHOTS}browse-01.webp" alt="{esc(h["deck_alt"].format(n=1))}" width="1440" height="900" fetchpriority="high">'
    out += f"""<main id="main">
<section class="wrap hero">
  <p class="eyebrow rise">{h['eyebrow']}</p>
  <h1 class="rise">{h['h1']}</h1>
  <p class="lede rise">{h['lede']}</p>
  <div class="rise">{download_block(lang, brew=True, win=SHOW_WINDOWS_WAITLIST)}</div>
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
    feats = list(h["features"]) + [h["film_feature"]] + ([h["wm_feature"]] if SHOW_WATERMARK else [])
    for i, (img, alt, h2, body) in enumerate(feats):
        dims = shot_size(img)
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
    faqs = "".join(f"<details><summary>{esc(q)}</summary><p>{a}</p></details>" for q, a in h["faq"] + (h["wm_faq"] if SHOW_WATERMARK else []))
    out += f'<section class="wrap faq" id="faq"><h2>{t["faq"]}</h2>{faqs}</section>\n'
    out += f'<section class="wrap end"><h2>{h["end"]}</h2>{download_block(lang)}</section>\n'
    if SHOW_WINDOWS_WAITLIST:
        out += waitlist_block(lang)
    out += "</main>\n"
    return out + footer(lang)


def render_guide(lang, g):
    t = T[lang]
    schema = [crumbs_schema(lang, g["title"], g["path"]),
              {"@context": "https://schema.org", "@type": "Article", "headline": g["title"], "description": g["desc"],
               "inLanguage": t["lang"], "datePublished": g["published"], "dateModified": g["updated"], "image": f"{BASE}/og.jpg",
               "mainEntityOfPage": f"{BASE}{g['path']}", "author": {"@type": "Organization", "name": "Flipic Lens"},
               "publisher": {"@type": "Organization", "name": "Flipic Lens", "logo": {"@type": "ImageObject", "url": f"{BASE}/icon-256.png"}}}]
    if g["howto"]:
        schema.append({"@context": "https://schema.org", "@type": "HowTo", "name": g["title"], "inLanguage": t["lang"],
                       "tool": [{"@type": "HowToTool", "name": "Flipic Lens"}],
                       "step": [{"@type": "HowToStep", "position": i + 1, "text": s} for i, s in enumerate(g["howto"])]})
    if g["faq"]:
        schema.append(faq_schema(g["faq"]))
    suffix = ""
    if g["title_suffix"]:
        suffix = " | Flipic Lens"
    page_title = g["title"] + suffix
    out = head(lang, g["path"], page_title, g["desc"], schema, og_type="article") + header(lang, g["path"])
    related = "".join(f'<a href="{o["path"]}">{esc(o["title"])}</a>' for o in GUIDES[lang] if o is not g)
    faq_html = ""
    if g["faq"]:
        faq_items = "".join(f"<details><summary>{esc(q)}</summary><p>{a}</p></details>" for q, a in g["faq"])
        faq_html = f'<section class="faq"><h2>{t["faq"]}</h2>{faq_items}</section>\n'
    updated_line = ("更新于 " if lang == "zh" else "Updated ") + g["updated"]
    out += f"""<main id="main" class="narrow article">
<p class="crumbs"><a href="{t['home']}">{t['crumbs_home']}</a> › <a href="{t['home']}#guides">{t['crumbs_guides']}</a></p>
<h1>{esc(g['title'])}</h1>
<p class="updated">{updated_line}</p>
<div class="prose">{g['body']}</div>
{faq_html}<div class="cta"><p>{t['cta']}</p>{download_block(lang)}</div>
<nav class="related" aria-label="{t['related']}"><h2>{t['related']}</h2>{related}</nav>
</main>
"""
    return out + footer(lang)


# ---------------------------------------------------------------- Pro 页

PRO = {
    "zh": {
        "path": "/pro/",
        "title": "Flipic Lens Pro：Mac 挑片批量工具",
        "desc": "Flipic Lens 免费版已经够大多数人用。Pro 加了管拍摄的工作台、放大到眼睛、按内容和照片里的字找照片、修图前后对比这些功能，一次买断，下载就有 7 天试用。",
        "eyebrow": "给经常挑片的摄影师",
        "h1": "Flipic Lens Pro",
        "lede": "给一次要挑几百上千张照片的人多准备的几样东西。一次买断，下载 Flipic Lens 就能先试用 7 天。",
        "try": "下载，先试用 7 天",
        "hero_alt": "Flipic Lens Pro 工作台：左侧可折叠拍摄项目列表，中间胶片条视图配实时星级计数与 ⇅ 快捷排序，右侧一屏照片信息卡片显示 RGB 直方图、相机镜头、曝光参数与地点地图",
        "honest_title": "先说一句：大多数人用免费版就够了",
        "honest": [
            "看图、RAW 秒开、直方图与对焦框质检、EXIF 参数相框、打星、标记、按星级筛选、导出到文件夹、并排对比、清理相似和模糊的照片，这些都是免费的，代码也开源，以后不会改成要付费。",
            "Pro 是给经常一次处理几百上千张照片的人准备的。平时只是看看照片、偶尔挑几张的话，用不到它，不用买。卖 Pro 的收入用来继续维护 Flipic Lens，免费版也会一直更新。",
        ],
        "skip_title": "这些情况用不到 Pro",
        "skip": ["只是想双击图片，用方向键看完一个文件夹", "偶尔给照片打星、标记几张，再导出到一个文件夹", "清理手机里导出来的重复、模糊照片"],
        "workbench": {
            "h": "工作台：5 种视图 + 一屏照片信息栏",
            "body": [
                "另开一个窗口管一场一场的拍摄（菜单「窗口 › 工作台」，快捷键 <kbd>⌥⌘B</kbd>）。左侧每个拍摄文件夹是一个项目，可置顶、分组、标颜色、改状态（待挑 / 挑片中 / 已交付），按 <kbd>⌃⌘S</kbd> 随时折叠腾出整块屏幕。",
                "提供宫格、宫格 + 大图、胶片条（<kbd>T</kbd> 切换，底部缩略图支持鼠标滚轮直接翻片）、单张和 2–9 图多图对比 5 种视图。顶部一排实时统计 1★–5★ 数量角标，一键精确筛星，右上角 <kbd>⇅</kbd> 随时改排序，点 <kbd>ⓘ</kbd> 或按 <kbd>I</kbd> 在最右侧贴边展开完整照片信息卡片（直方图、全参数、IPTC 翻译与地图一屏看完，窄屏自动切浮层）。",
                "还能按已标记、闭眼、模糊、连拍一键筛选：点「闭眼」，闭着眼的照片就单独列出来并框出人脸。",
            ],
            "img": "pro-closed-eyes.webp",
            "alt": "工作台按「闭眼」筛选，只剩 4 张，每张闭眼的脸上有橙色框",
        },
        "compare": {
            "h": "2–9 张多图同屏对比，信息栏随焦点联动",
            "body": "在工作台宫格或胶片条里选中 2 到 9 张相似连拍，一键进入自适应多图同屏对比（5 张自动上 3 下 2 铺满，不留黑空）。所有画面同步缩放、同步平移，按 <kbd>E</kbd> 一起放大到眼睛，用 <kbd>Tab</kbd> 或方向键切焦点格打星和标记，最右侧的照片信息栏与直方图实时跟着当前白框焦点切换。",
            "img": "pro-compare.webp",
            "alt": "Flipic Lens Pro 工作台 5 图同屏对比：上 3 下 2 铺满显示五张圣托里尼照片，当前白框焦点格与最右侧照片信息卡片同步显示直方图与拍摄参数",
        },
        "eyes": {
            "h": "放大到眼睛",
            "body": "按 <kbd>E</kbd> 一下放大到人物的两眼中间，往下翻页停在同一个位置，盯着眼睛看哪张对上了焦。",
            "shots": [("pro-eyes-fit.webp", "适应窗口的新娘照片", "整张看"), ("pro-eyes-zoom.webp", "按 E 以后放大到新娘的眼睛", "按 E 以后")],
        },
        "search": {
            "h": "按内容找照片",
            "body": [
                "按 <kbd>⌘F</kbd> 输入「猫」「海边」「夜景」，当前文件夹里拍到这些的照片就挑出来，底下的缩略图栏只剩找到的那几张。",
                "在设置里下载一次约 141 MB 的中文识别模型后，还能搜「布偶猫」这样的细分品种，或者一句话「海边奔跑的狗」。都在本机识别，照片不上传。",
            ],
            "img": "pro-search.webp",
            "alt": "搜「布偶猫」，在一个混着猫、狗、美食的文件夹里找到 10 张布偶猫",
        },
        "text": {
            "h": "按照片里的字找",
            "body": ["搜「发票」「会议纪要」「WiFi 密码」，图上有这几个字的照片排在最前面，简体繁体互通。拍过的菜单、通知、票据，不用一张张翻。"],
            "img": "pro-text.webp",
            "alt": "搜「发票」，找到一张拍下来的增值税发票",
        },
        "ba": {
            "h": "修图前后对比",
            "body": "原片和修过的那张叠在一起，按住 <kbd>\\</kbd> 看修图前，松开看修图后。也可以拖一条分割线左右对照，或者调修图后那张的透明度。Flipic Lens 会按文件名找到对应的两张，比如 IMG_1234.RAF 和 IMG_1234-编辑.jpg，或者导出文件夹里同名的那张。",
            "img": "pro-before-after.webp",
            "alt": "修图前后对比的分割视图：左边是原片，右边是调亮、调冷以后的版本",
        },
        "film": {
            "h": "十款胶片滤镜 + 自定义 .cube 3D LUT",
            "body": [
                "胶片滤镜面板里十款内置效果，「暖调人像」和「经典黑白」免费，另外八款是 Pro：日常暖色、浓郁反转片、清冷薄荷、细腻鲜艳、电影夜色、纪实灰调、柔和黑白、粗颗粒黑白。同时支持导入自己的 3D <code>.cube</code> LUT（索尼、富士、达芬奇、Adobe 导出的 17/33/64/65 级都支持，超过 64 级自动重采样）。下载后的 7 天试用里全部可用。",
                "按 <kbd>⇧F</kbd> 打开面板，强度、颗粒、光晕三个滑块可调，翻页时效果一直保持，原图不会被改。另存一份、⌘S 导出、批量转换和导出预设里都能直接套用内置胶片或已导入的 .cube LUT。",
            ],
            "img": "film.webp",
            "alt": "胶片滤镜面板：十款效果的缩略图，下面是强度、颗粒、光晕滑块",
        },
        "small_title": "还有这些",
        "small": [
            ("按客户文件名清单挑图", "客户从微信、飞书或邮件发来一串选片编号（哪怕夹杂文字或只写后四位），在「照片 › 按文件名清单挑图…」里整段粘贴，自动匹配文件夹里的原图（支持 .JPG 跨扩展名对应 .ARW/RAW 与 RAW+JPG 成对匹配），一键只看命中、全部标记或导出原图。"),
            ("导出预设", "把常用的导出方式存成预设，一步导出一批照片，快捷键是 ⌥⌘1 到 ⌥⌘9。预设除了格式、质量、尺寸上限和文件名模板，还能带上一款胶片/LUT、EXIF 参数相框{wm}。"),
            ("JPG 和 RAW 合并显示", "相机同时存 JPG 和 RAW 的话，同名的两个文件只显示成一张，张数不会翻倍，按 V 切换看哪一张。打星、标记、导出、删除都当成一张处理。"),
            ("按星级分到子文件夹", "打完星以后，可以把整个文件夹的照片按星级复制或移动到「5 星」「4 星」这样的子文件夹里。"),
            ("常用文件夹", "最多设 9 个常用文件夹，看图时按 ⌥1 到 ⌥9 就把当前照片复制或移动过去。"),
            ("删除没挑中的照片", "标记或打星挑完以后，可以把其余的照片一次移到废纸篓，删错了能马上放回来。"),
            ("一次在后期软件里打开多张", "把筛出来的照片一次在 Lightroom、Photoshop 或 Capture One 里打开，有 RAW 的打开 RAW。"),
            ("自定义同名文件", "复制、移动、删除照片时，同名的 xmp、dop、pp3 这类附属文件，或者 JPG 和 RAW，可以设置成跟着一起处理。"),
        ],
        "buy": "购买 Pro",
        "price_note": "一次买断，之后的更新都能用。付款后马上拿到激活码，不用注册账号。激活码只限本人使用，最多激活你自己的 2 台 Mac。",
        "trial": "下载 Flipic Lens 就带 7 天试用，到期后免费功能照常可用。",
        "free_title": "免费和 Pro",
        "free_head": ("功能", "免费", "Pro"),
        "free_rows": [("看图、RAW 秒开、外接盘 SSD 缓存、HDR、幻灯片", "有", "有"),
                      ("直方图 (H)、过曝警示 (J)、焦点峰值 (K)、对焦框 (A)", "有", "有"),
                      ("评星、颜色标签（XMP + 访达）、标记、筛选", "有", "有"),
                      ("导出到文件夹、EXIF 参数相框、并排对比、清理模式", "有", "有"),
                      ("批量转格式、EXIF 模板批量重命名、水印与去序列号", "有", "有"),
                      ("工作台（5 视图、2–9 图对比、独立照片信息栏）", "", "有"), ("放大到眼睛", "", "有"), ("按内容、按照片里的字找照片", "", "有"),
                      ("按客户文件名清单挑图", "", "有"), ("修图前后对比", "", "有"), ("JPG 和 RAW 合并显示", "", "有"),
                      ("按星级分到子文件夹", "", "有"), ("常用文件夹 ⌥1–⌥9", "", "有"), ("删除没挑中的照片", "", "有"),
                      ("批量送进后期软件", "", "有"), ("自定义同名关联", "", "有"),
                      ("胶片滤镜：暖调人像、经典黑白", "有", "有"), ("胶片滤镜：另外八款 + 自定义 .cube 3D LUT", "", "有"), ("导出预设", "", "有")],
        "faq": [
            ("激活码怎么用？", "付款成功的页面上有激活码和「在 Flipic Lens 中激活」按钮，点一下就激活了。也可以复制激活码，粘贴到 Flipic Lens「设置 › Pro」里。"),
            ("要联网验证吗？", "第一次激活需要联网，把激活码绑定到这台 Mac，只发订单号和设备号的哈希。之后离线也能用，每隔一段时间联网核对一次；长时间（60 天）没联上网，联网一次就恢复。"),
            ("能装在几台 Mac 上？", "一个激活码只限购买者本人使用，最多激活你自己的 2 台 Mac。换电脑时，先在旧 Mac 的「设置 › Pro」里停用，空出名额；旧 Mac 坏了没法操作的，在 App 里「关于 › 反馈建议」告诉我们解绑。"),
            ("激活码丢了怎么办？", "在 <a href=\"https://pay.flipic.app/recover?lang=zh\">找回激活码</a> 页面输入付款邮箱和卡号后四位就能找回。"),
            ("我是在 Mac App Store 下载的，能用这里的激活码吗？", "不能。<a href=\"" + APP_STORE_URL + "\">Mac App Store 版</a>的 Pro 在 App 里通过 Apple 购买（按月、按年订阅或一次买断），和官网的激活码是分开的，两边不能互通。想用激活码，请从本站下载官网版。"),
            ("Flipic Lens 还是开源的吗？", "是。看图和挑片的核心功能继续开源（MIT），Pro 功能的代码不在公开仓库里。"),
        ],
    },
    "en": {
        "path": "/en/pro/",
        "title": "Flipic Lens Pro: batch tools for heavy culling",
        "desc": "The free Flipic Lens is enough for most people. Pro adds a Workbench for your shoots, zoom to the eyes, search by what’s in a photo or the text on it, and before & after. One-time purchase, 7-day trial in every download.",
        "eyebrow": "For photographers who cull a lot",
        "h1": "Flipic Lens Pro",
        "lede": "A few extra tools for people who go through hundreds or thousands of photos at a time. One-time purchase, and every download includes a 7-day trial.",
        "try": "Download and try it for 7 days",
        "hero_alt": "Flipic Lens Pro Workbench: collapsible shoot project sidebar on the left, Filmstrip view with live star counts and ⇅ quick sort in the middle, and a one-screen Photo Info card on the right with RGB histogram, camera/lens EXIF and map",
        "honest_title": "First, most people will be fine with the free version",
        "honest": [
            "Viewing, quick RAW previews, histogram/peaking/AF inspection, EXIF photo frames, ratings, marks, filtering by rating, export to a folder, side-by-side comparison and cleaning up similar or blurry photos are all free, the code is open source, and none of it will become paid.",
            "Pro is for people who often go through hundreds or thousands of photos at a time. If you mostly look at photos and pick a few now and then, you won’t use it, so there’s no need to buy it. Pro sales pay for keeping Flipic Lens going, and the free version keeps getting updates too.",
        ],
        "skip_title": "You won’t need Pro if you",
        "skip": ["just want to double-click a photo and page through the folder", "rate or mark a few photos now and then and export them to a folder", "clean up duplicate or blurry photos from your phone"],
        "workbench": {
            "h": "Workbench: 5 views &amp; a one-screen Photo Info card",
            "body": [
                "A dedicated window for managing your shoots (Window › Workbench, or <kbd>⌥⌘B</kbd>). Each shoot folder on the left is a project you can pin, group, color-label and track as To cull, Culling or Delivered—collapse the sidebar anytime with <kbd>⌃⌘S</kbd>.",
                "Switch across five views: Grid, Grid + Preview, Filmstrip (<kbd>T</kbd>, with mouse-wheel paging right over the bottom strip), Single and 2–9 photo Compare. Live per-star counters (★1–★5) let you filter exact ratings in one click, <kbd>⇅</kbd> changes sort order on the fly, and <kbd>ⓘ</kbd> or <kbd>I</kbd> docks a full Photo Info card on the right (RGB histogram, camera/lens EXIF, IPTC + translation and map in one screen, floating automatically on narrow windows).",
                "Filter by Marked, Blinks, Blurry or Bursts in one click: Blinks isolates every shot with closed eyes and outlines the flagged face.",
            ],
            "img": "pro-closed-eyes-en.webp",
            "alt": "Workbench filtered to Blinks: four photos left, each closed-eye face outlined in orange",
        },
        "compare": {
            "h": "Compare 2 to 9 photos side by side",
            "body": "Select 2 to 9 frames from a burst in the Workbench to compare them in an adaptive full-bleed grid (5 photos fill 3 on top and 2 below with zero wasted space). Zoom, pan and press <kbd>E</kbd> to zoom to the eyes across all panes in sync, move focus with <kbd>Tab</kbd> or arrow keys to rate and mark, and watch the right Photo Info card and RGB histogram follow the active frame live.",
            "img": "pro-compare-en.webp",
            "alt": "Flipic Lens Pro Workbench comparing five Santorini photos side by side (three on top, two full-width below) with the docked Photo Info card synced to the active white-bordered frame",
        },
        "eyes": {
            "h": "Zoom to the eyes",
            "body": "Press <kbd>E</kbd> to zoom straight to the space between a subject’s eyes. Paging keeps the same spot, so you can check focus across a burst.",
            "shots": [("pro-eyes-fit.webp", "A bride, fitted to the window", "Whole photo"), ("pro-eyes-zoom.webp", "After pressing E, zoomed to the bride’s eyes", "After pressing E")],
        },
        "search": {
            "h": "Find photos by what’s in them",
            "body": [
                "Press <kbd>⌘F</kbd> and type “cat”, “beach” or “night” to pick out matching photos in the folder. The thumbnail strip shows only what was found.",
                "After a one-time 141 MB download in Settings you can also search for specific breeds or whole phrases (best in Chinese). Recognition runs on your Mac; nothing is uploaded.",
            ],
            "img": "pro-search-en.webp",
            "alt": "Searching for cat in a folder of cats, dogs and food; only the cats are left in the strip",
        },
        "text": {
            "h": "Find photos by the text in them",
            "body": ["Search for “invoice”, “meeting notes” or “WiFi password” and photos with those words on them come first. Menus, notices and receipts you took a picture of, without paging through them all."],
            "img": "pro-text-en.webp",
            "alt": "Searching for invoice finds a photo of a printed invoice",
        },
        "ba": {
            "h": "Before & after",
            "body": "The original and the edited version sit on top of each other. Hold <kbd>\\</kbd> to see the original and let go to see the edit. You can also drag a split line to compare side by side, or change the edit’s opacity. Flipic Lens finds the pair by file name, such as IMG_1234.RAF and IMG_1234-Edit.jpg, or a file with the same name in an export folder.",
            "img": "pro-before-after-en.webp",
            "alt": "Before and after split view: the original on the left, a brighter, cooler edit on the right",
        },
        "film": {
            "h": "All ten film looks + custom .cube 3D LUTs",
            "body": [
                "Of the ten built-in looks in the Film Looks panel, Warm Portrait and Classic B&amp;W are free. The other eight are Pro: Everyday Warm, Rich Slide, Cool Mint, Fine Color, Cinema Night, Muted Gray, Soft B&amp;W and Coarse B&amp;W. Pro also imports your own 3D <code>.cube</code> LUTs (17/33/64/65-point files from Sony, Fujifilm, DaVinci Resolve or Adobe; grids above 64 are automatically resampled). Everything works during the 7-day trial.",
                "Press <kbd>⇧F</kbd> to open the panel. Strength, Grain and Halation are adjustable, the look stays on as you page, and your originals are never changed. Save a Copy, Export (⌘S), Batch Convert and export presets all support both built-in looks and imported .cube LUTs.",
            ],
            "img": "film-en.webp",
            "alt": "Film Looks panel: ten swatches of the current photo above Strength, Grain and Halation sliders",
        },
        "small_title": "And also",
        "small": [
            ("Match from a client’s filename list", "Paste a client’s messy list of photo names or trailing numbers from chat or email (Photo › Match from Filename List…) to match across extensions (.JPG → .ARW/RAW) and RAW+JPG pairs, then filter, mark all or export originals."),
            ("Export presets", "Save the ways you usually export and deliver a batch in one step; the shortcuts are ⌥⌘1 to ⌥⌘9. Besides format, quality, size limits and a file name template, a preset can carry a film/LUT, EXIF frame{wm}."),
            ("Show JPG and RAW as one photo", "If your camera saves both JPG and RAW, each pair shows up as one photo, so the count doesn’t double. Press V to switch between them. Rating, marking, exporting and deleting treat the pair as one."),
            ("Sort into folders by rating", "After rating, copy or move the photos in a folder into subfolders like “5 stars” and “4 stars”."),
            ("Favorite folders", "Set up to nine folders, then press ⌥1 to ⌥9 while viewing to copy or move the current photo there."),
            ("Delete the photos you didn’t pick", "After marking or rating, move all the others to the Trash at once, and put them back right away if you made a mistake."),
            ("Open several photos in your editor", "Open the photos you filtered in Lightroom, Photoshop or Capture One at once, using the RAW file when there is one."),
            ("Same-name files", "Choose which files with the same name go along when you copy, move or delete a photo, such as xmp, dop and pp3 sidecars, or JPG and RAW."),
        ],
        "buy": "Buy Pro",
        "price_note": "One-time purchase with future updates included. You get your key right after paying. No account. The key is for your own use on up to 2 of your own Macs.",
        "trial": "Every download includes a 7-day trial; after it ends, the free features keep working.",
        "free_title": "Free and Pro",
        "free_head": ("Feature", "Free", "Pro"),
        "free_rows": [("Viewing, instant RAW, external drive SSD cache, HDR, slideshow", "Yes", "Yes"),
                      ("Histogram (H), clipping (J), focus peaking (K), AF point (A)", "Yes", "Yes"),
                      ("Ratings, color labels (XMP + Finder), marks, filtering", "Yes", "Yes"),
                      ("Export to folder, EXIF photo frame, side-by-side, Cleanup Mode", "Yes", "Yes"),
                      ("Batch convert, EXIF template rename, watermarks & serial stripping", "Yes", "Yes"),
                      ("Workbench (5 views, 2–9 compare, Photo Info card)", "", "Yes"), ("Zoom to the eyes", "", "Yes"), ("Find photos by content or text", "", "Yes"),
                      ("Match from a client’s filename list", "", "Yes"), ("Before & after", "", "Yes"), ("Merge JPG and RAW", "", "Yes"),
                      ("Sort into folders by rating", "", "Yes"), ("Favorite folders ⌥1–⌥9", "", "Yes"), ("Delete what you didn’t pick", "", "Yes"),
                      ("Send a batch to your editor", "", "Yes"), ("Custom linked files", "", "Yes"),
                      ("Film looks: Warm Portrait, Classic B&W", "Yes", "Yes"), ("Film looks: other eight + custom .cube 3D LUTs", "", "Yes"), ("Export presets", "", "Yes")],
        "faq": [
            ("How do I activate?", "The payment confirmation page shows your key and an Activate in Flipic Lens button. Or copy the key and paste it into Flipic Lens › Settings › Pro."),
            ("Does it need to go online?", "The first activation goes online to bind the key to this Mac, sending only hashes of the order number and device ID. After that it works offline and checks in now and then; if it has been offline for a long time (60 days), going online once restores it."),
            ("How many Macs?", "A key is for the buyer’s own use and can be activated on up to 2 of your own Macs. When you switch Macs, deactivate it on the old one in Settings › Pro to free the slot. If the old Mac is broken, let us know via About › Send Feedback in the app and we’ll release it."),
            ("I lost my key", "Use <a href=\"https://pay.flipic.app/recover?lang=en\">Recover Key</a> with your payment email and the last four digits of your card."),
            ("I got Flipic Lens from the Mac App Store. Can I use a key from here?", "No. In the <a href=\"" + APP_STORE_URL + "\">Mac App Store version</a>, Pro is bought through Apple inside the app (monthly, yearly or one-time) and is separate from flipic.app license keys; the two don’t carry over. To use a key, download the website version from this site."),
            ("Is Flipic Lens still open source?", "Yes. The core viewer and culling features stay open source (MIT). Pro code isn’t in the public repository."),
        ],
    },
}


def shot_size(name):
    """读 webp 文件头里的宽高，Pro 页的截图不用手写尺寸"""
    b = (DOCS / "shots" / name).read_bytes()[:30]
    kind = b[12:16]
    if kind == b"VP8X":
        return 1 + int.from_bytes(b[24:27], "little"), 1 + int.from_bytes(b[27:30], "little")
    if kind == b"VP8 ":
        return int.from_bytes(b[26:28], "little") & 0x3FFF, int.from_bytes(b[28:30], "little") & 0x3FFF
    if kind == b"VP8L":
        v = int.from_bytes(b[21:25], "little")
        return (v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1
    raise ValueError(name)


def pro_shot(name, alt, eager=False):
    return shot(name, alt, *shot_size(name), eager=eager)


def render_pro(lang):
    t = T[lang]
    p = PRO[lang]
    path = p["path"]
    schema = [faq_schema(p["faq"])]
    out = head(lang, path, p["title"], p["desc"], schema) + header(lang, path)
    price = PRO_PRICE[lang]
    value, currency = PRO_VALUE[lang]
    buy_btn = f'<a class="btn" href="{PRO_BUY_URL}" data-value="{value}" data-currency="{currency}">{p["buy"]}{" · " + esc(price) if price else ""}</a>'
    try_btn = f'<a class="btn line" href="/download/Flipic.dmg" download>{DOWNLOAD_ICON}{p["try"]}</a>'
    paras = lambda xs: "".join(f"<p>{x}</p>" for x in xs)
    wb, cmp_sec, ey, se, tx, ba, fl = p["workbench"], p["compare"], p["eyes"], p["search"], p["text"], p["ba"], p["film"]
    hero_img = "pro-workbench.webp" if lang == "zh" else "pro-workbench-en.webp"
    skip = "".join(f"<li>{esc(x)}</li>" for x in p["skip"])
    pair = "".join(f"<figure>{pro_shot(img, alt)}<figcaption>{esc(cap)}</figcaption></figure>" for img, alt, cap in ey["shots"])
    wm_tail = {"zh": "和一个水印", "en": " and a watermark"}[lang] if SHOW_WATERMARK else ""
    small = "".join(f"<li><h3>{esc(h)}</h3><p>{esc(b.replace('{wm}', wm_tail))}</p></li>" for h, b in p["small"])
    hd = p["free_head"]
    rows = "".join(f'<tr><td>{esc(a)}</td><td>{esc(b)}</td><td class="yes">{esc(c)}</td></tr>' for a, b, c in p["free_rows"])
    faqs = "".join(f"<details><summary>{esc(q)}</summary><p>{a}</p></details>" for q, a in p["faq"])
    price_tag = f'<p class="pro-price">{esc(price)}</p>' if price else ""
    out += f"""<main id="main" class="pro">
<section class="wrap pro-hero">
  <p class="eyebrow rise">{p['eyebrow']}</p>
  <h1 class="rise">{p['h1']}</h1>
  <p class="lede rise">{p['lede']}</p>
  <div class="get rise">{buy_btn}{try_btn}</div>
  <p class="alt pro-note-line">{p['price_note']}</p>
  <figure class="pro-hero-shot">{pro_shot(hero_img, p['hero_alt'], eager=True)}</figure>
</section>
<section class="wrap pro-honest">
  <div><h2>{p['honest_title']}</h2>{paras(map(esc, p['honest']))}</div>
  <aside><h3>{p['skip_title']}</h3><ul>{skip}</ul></aside>
</section>
<div class="wrap">
<section class="feature">
  <div class="copytext"><h2>{wb['h']}</h2>{paras(wb['body'])}</div>
  {pro_shot(wb['img'], wb['alt'])}
</section>
<section class="pro-wide">
  <div class="pro-split"><h2>{cmp_sec['h']}</h2><p>{cmp_sec['body']}</p></div>
  {pro_shot(cmp_sec['img'], cmp_sec['alt'])}
</section>
<section class="pro-pair">
  <div class="pro-split"><h2>{ey['h']}</h2><p>{ey['body']}</p></div>
  <div class="pair">{pair}</div>
</section>
<section class="feature flip">
  <div class="copytext"><h2>{se['h']}</h2>{paras(se['body'])}</div>
  {pro_shot(se['img'], se['alt'])}
</section>
<section class="feature pro-text">
  <div class="copytext"><h2>{tx['h']}</h2>{paras(tx['body'])}</div>
  {pro_shot(tx['img'], tx['alt'])}
</section>
<section class="pro-wide">
  <div class="pro-split"><h2>{ba['h']}</h2><p>{ba['body']}</p></div>
  {pro_shot(ba['img'], ba['alt'])}
</section>
<section class="feature flip">
  <div class="copytext"><h2>{fl['h']}</h2>{paras(fl['body'])}</div>
  {pro_shot(fl['img'], fl['alt'])}
</section>
</div>
<section class="wrap pro-small"><h2>{p['small_title']}</h2><ul>{small}</ul></section>
<section class="wrap pro-buy-row">
  <div><h2>{p['free_title']}</h2><table><thead><tr><th>{hd[0]}</th><th>{hd[1]}</th><th>{hd[2]}</th></tr></thead><tbody>{rows}</tbody></table></div>
  <aside class="pro-card">
    <p class="pro-price">{esc(price)}</p>
    <p>{p['price_note']}</p>
    <div class="get">{buy_btn}</div>
    <p class="alt">{p['trial']}</p>
  </aside>
</section>
<section class="wrap faq"><h2>{t['faq']}</h2>{faqs}</section>
</main>
"""
    return out + footer(lang)


STRIPE_PRIVACY = "https://stripe.com/privacy"
APPLE_PRIVACY = "https://www.apple.com/legal/privacy/"
APPLE_EULA = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
APPLE_REFUND = "https://reportaproblem.apple.com/"


def legal_pages(lang):
    """隐私政策和用户协议。只写软件、付款服务和网站实际做的事；改了代码里的联网或存储行为要同步改这里"""
    op = esc(LEGAL["operator"][lang])
    store = esc(STORE_NAME)
    if lang == "zh":
        both = "Flipic Lens"
        store_full = f"Mac App Store 上的 Flipic Lens（原名 {store}）" if store else "Mac App Store 上的 Flipic Lens"
        store_short = "Mac App Store 版"
    else:
        both = "Flipic Lens"
        store_full = f"Flipic Lens on the Mac App Store (formerly {store})" if store else "Flipic Lens on the Mac App Store"
        store_short = "The Mac App Store version"
    mail = esc(LEGAL["email"])
    m = f'<a href="mailto:{mail}">{mail}</a>'
    days = LEGAL["refund_days"]
    eff = LEGAL["effective"]
    wl_zh = """<h2>Windows 版候补名单</h2>
<p>如果你在首页的「想要 Windows 版吗」一栏留下邮箱，我们会保存你的邮箱地址、当时页面的语言、你所在的国家（由 Cloudflare 判断，只到国家）和提交日期，不保存 IP 地址。这些只用来在 Windows 版发布时给你发一封邮件，也用来估计有多少人想要，不会用于别的用途，也不会提供给第三方。数据存放在本站的 Cloudflare 数据库里。想从名单里删掉，发邮件到 {m}，写上你留的邮箱就行。</p>
""".replace("{m}", m) if SHOW_WINDOWS_WAITLIST else ""
    wl_en = """<h2>Windows version waitlist</h2>
<p>If you leave your email in the “Want a Windows version?” box on the home page, we store your email address, the language of the page you were on, your country (worked out by Cloudflare, country level only) and the date. We don’t store your IP address. We use this only to send you one email if a Windows version is released, and to gauge how many people want one. It isn’t used for anything else or given to anyone else, and it lives in this site’s Cloudflare database. To be removed from the list, email {m} with the address you left.</p>
""".replace("{m}", m) if SHOW_WINDOWS_WAITLIST else ""
    if lang == "zh":
        privacy = ("/privacy/", "隐私政策", f"{both} 的隐私政策：照片只在你的 Mac 上处理，不收集个人信息；购买 Pro 时付款信息由 Stripe 或 Apple 处理。", f"""
<p class="lede">生效日期：{eff}</p>
<div class="prose">
<p>这份政策适用于 Flipic Lens（从 flipic.app 和 GitHub 下载的版本）、{store_full}、flipic.app 网站和 pay.flipic.app 付款服务。运营者是{op}。</p>
<h2>软件本身</h2>
<p>照片只在你的 Mac 上读取和显示，不会上传到任何地方。软件不需要账号，没有广告，不会自动上报崩溃，不收集设备信息，也不统计你用了哪些功能。</p>
<p>你给照片打的星级写进照片的 XMP 信息，相机 RAW 写在同名的 .xmp 文件里；挑片标记是访达标签；设置保存在这台 Mac 上。这些都留在你自己的电脑上。</p>
<p>Flipic Lens 默认每天自动检查一次更新，可以在设置里关掉，也可以点「检查更新」手动检查。检查时向 flipic.app 请求一个写着最新版本号的文件，请求里带软件版本号、安装了多久（不到 7 天、7 到 29 天、30 天或以上，三档之一）和 Pro 是否已激活；手动检查时多带一个「手动」标记。请求里没有任何标识，没有确切的安装日期或天数，也不保存 cookie。服务器只按日期、国家、软件版本、时长档位和 Pro 标记累加次数，同时累加这个文件和官网安装包被请求的次数，不保存 IP 地址。你点「立即更新」时，安装包从 GitHub 下载。</p>
<p>另外几种情况会联网，都由你主动触发：在设置里下载「更准的中文识别」模型时，从 GitHub 下载；在「关于 Flipic Lens」里发送反馈时，发送你写的内容、你留的邮箱（可以不填）和 App、系统版本，存在 pay.flipic.app 的反馈记录里，用来回复你和改进软件，不含照片和文件；为了让开发者及时看到，你写的内容和 App、系统版本会通过推送通知服务 Bark 发到开发者的手机上，邮箱不会；为了防止刷屏，同时保存一个加盐处理过的 IP 哈希，不保存 IP 本身；软件意外退出后，下次打开时会问你要不要把崩溃报告发给开发者，点「发送」才会发出，可以先看到完整内容，也可以在设置里关掉这个询问。报告里是崩在哪里、软件和系统版本、Mac 型号，发出前会去掉用户名、文件名和路径，不含照片；它存在 pay.flipic.app，同样只保存加盐的 IP 哈希，新报告的摘要（崩溃位置和版本）会通过 Bark 推送到开发者手机。信息面板里的位置地图默认不加载，你点「显示地图」（或在设置里打开自动显示）后，才会像在系统「地图」App 里查看一个地点那样，向 Apple 地图请求照片所在区域的地图；没有位置信息的照片不会请求。</p>
<p>{store_short}有些不同：它不检查更新，更新由 App Store 负责；没有崩溃报告，也没有激活码，不会连接激活服务器。它只在这几种情况联网：上面说的发送反馈、显示位置地图、下载识别模型，以及在 App 里购买 Pro 时和 App Store 通信。</p>
<h2>购买 Pro</h2>
<p>在官网购买时，付款由 Stripe 处理，银行卡等支付信息由 Stripe 收集，我们看不到完整卡号。付款完成后，pay.flipic.app 从 Stripe 读取这笔订单的邮箱和订单号，生成激活码。激活码里包含邮箱和订单号，在你的 Mac 上离线验证。订单记录保存在我们的 Stripe 账户里，用来帮你找回激活码、处理退款和记账。激活时，Flipic Lens 把激活码发给 pay.flipic.app 验证，服务器只记下订单号的哈希和这台 Mac 设备号的哈希（不存邮箱和电脑名），用来把激活码限制在 2 台 Mac 上，之后每隔一段时间核对一次；IP 地址只用来限制请求频率，不保存。付款成功页会把这笔订单的金额和 Stripe 订单编号报给 Google Analytics，用来统计购买次数，不含邮箱。Stripe 如何处理信息见 <a href="{STRIPE_PRIVACY}">Stripe 隐私政策</a>。</p>
<p>找回激活码时，你填写的邮箱和卡号后四位（或收据号）只用来在 Stripe 里查找订单，不会保存。为了防止有人反复试探，找回页面按 IP 地址限制每分钟的请求次数，IP 地址不保存。</p>
<p>在 App Store 版里购买 Pro（订阅或买断）时，付款、续订和账户都由 Apple 处理，我们收不到你的姓名、邮箱或支付信息，App 只从 App Store 得知这台 Mac 上的 Pro 是否有效。见 <a href="{APPLE_PRIVACY}">Apple 隐私政策</a>。</p>
<h2>网站</h2>
<p>flipic.app 托管在 Cloudflare 上。Cloudflare 为了安全和正常运行会记录访问日志（比如 IP 地址和浏览器类型）。</p>
<p>网站用 Google Analytics 4 统计访问量，以及点了下载、购买、GitHub 这些按钮的次数，用来了解大家从哪里来、哪些内容有用。Google Analytics 会在浏览器里存 cookie，记录页面、来源、大致地区和设备类型，不记录完整 IP，也不知道你是谁；我们关闭了广告和个性化相关的功能。来自欧洲经济区、英国和瑞士的访问不写统计 cookie。网站没有广告和第三方字体。Google 如何处理这些数据见 <a href="https://policies.google.com/privacy">Google 隐私政策</a>。软件本身不包含任何统计。</p>
{wl_zh}<h2>查询和删除</h2>
<p>如果你想知道我们保存了哪些和你的订单有关的信息，或者希望删除，请发邮件到 {m}。按照财务和税务法规必须保留的付款记录除外。</p>
<h2>政策变化</h2>
<p>软件或服务处理信息的方式有变化时，我们会更新这一页并修改生效日期。</p>
</div>""")
        terms = ("/terms/", "用户协议", f"{both} 的使用条款：免费功能、Pro 一次买断、退款方式和免责说明。", f"""
<p class="lede">生效日期：{eff}</p>
<div class="prose">
<p>这份协议适用于 Flipic Lens（从 flipic.app 和 GitHub 下载的版本）和 {store_full}，由{op}提供。使用软件即表示你同意这份协议。</p>
<h2>免费使用</h2>
<p>Flipic Lens 的源代码以 <a href="https://opensource.org/license/mit">MIT 协议</a>在 <a href="{GITHUB}">GitHub</a> 开源。看图、评星、标记、筛选、导出、清理这些功能免费使用，不需要注册。</p>
<h2>Pro</h2>
<p>官网的 Pro 是一次性购买，不是订阅。买过以后，之后发布的更新里的 Pro 功能都可以用。Pro 只供购买者本人使用，一个激活码最多激活购买者自己的 2 台 Mac，激活时绑定设备，超过 2 台无法激活。</p>
<p>官网购买得到的激活码请不要公开分享。被公开传播的激活码，以及已经退款或拒付的订单对应的激活码，会被作废。</p>
<h2>退款</h2>
<p>在官网购买 Pro 后 {days} 天内，发邮件到 {m} 并附上付款邮箱，我们会全额退款，不需要说明理由。退款后对应的激活码作废。</p>
<p>在 App Store 购买的，退款按 Apple 的规定办理，请到 <a href="{APPLE_REFUND}">reportaproblem.apple.com</a> 申请。</p>
<h2>App Store 版</h2>
<p>{store_full}免费下载，免费功能和官网版相同。Pro 在 App 里购买，可以选按月或按年的自动续期订阅，也可以一次买断。订阅到期前 24 小时内会自动续费，可以随时在 App Store 的账户设置里取消，取消后用到当期结束。App Store 版和官网版的 Pro 分开购买，不能互通。App Store 版同时适用 <a href="{APPLE_EULA}">Apple 标准最终用户许可协议</a>，两者不一致的地方，以 Apple 的协议为准。</p>
<h2>责任</h2>
<p>软件按现状提供。删除、移动、批量整理照片会改动你的文件；删除的照片会先移到废纸篓。处理重要照片前请先备份。在法律允许的范围内，我们不对使用软件造成的数据丢失或其他间接损失承担责任。</p>
<h2>联系和变更</h2>
<p>有问题请发邮件到 {m}。协议有变化时，我们会更新这一页并修改生效日期。</p>
</div>""")
    else:
        privacy = ("/en/privacy/", "Privacy Policy", f"Privacy policy for {both}: photos stay on your Mac and no personal data is collected; Pro payments are handled by Stripe or Apple.", f"""
<p class="lede">Effective {eff}</p>
<div class="prose">
<p>This policy covers Flipic Lens (the version downloaded from flipic.app and GitHub), {store_full}, the flipic.app website and the pay.flipic.app payment service. They are run by {op}.</p>
<h2>The app</h2>
<p>Your photos are read and shown only on your Mac and are never uploaded. The app has no account, no ads and no automatic crash reporting, doesn’t collect device information and doesn’t track which features you use.</p>
<p>Star ratings are written into each photo’s XMP data, or into a matching .xmp file for camera RAW; marks are Finder tags; settings are stored on your Mac. All of this stays on your computer.</p>
<p>Flipic Lens checks for updates automatically once a day by default; you can turn this off in Settings, or click Check for Updates yourself. Each check requests a small file from flipic.app that contains the latest version number. The request carries the app’s version number, how long ago the app was installed as one of three ranges (under 7 days, 7–29 days, 30 days or more) and whether Pro is activated, plus a flag when you started the check yourself. It carries no identifier, no exact install date or day count, and stores no cookies. The server only adds to counters by date, country, app version, install-age range and Pro flag, and counts how many times this file and the installer on the website are requested; it does not keep IP addresses. When you click Update Now, the installer is downloaded from GitHub.</p>
<p>A few other things connect, and only when you trigger them: downloading the more accurate recognition model in Settings fetches it from GitHub; sending feedback from About Flipic Lens sends what you wrote, the email you leave (optional) and the app and macOS versions, stored in pay.flipic.app’s feedback records so we can reply and improve the app. No photos or files are sent. So that the developer sees it promptly, what you wrote and the app and macOS versions are also sent to the developer’s phone through the Bark push notification service; your email is not. To stop spam we also keep a salted hash of the IP address, not the address itself. After an unexpected quit, the app asks on the next launch whether to send a crash report to the developer. Nothing is sent unless you click Send, you can read the full text first, and you can turn the question off in Settings. The report says where the app crashed, the app and macOS versions and the Mac model; user names, file names and paths are removed before sending and no photos are included. It is stored at pay.flipic.app with the same salted IP hash, and a short summary (crash location and versions) is pushed to the developer’s phone through Bark. The location map in the info panel does not load by default. Only after you click Show Map, or turn on showing it automatically in Settings, does the app request the map of the area where the photo was taken from Apple Maps, the same as looking up a place in the Maps app. Photos without a location never make that request.</p>
<p>{store_short} differs in a few ways. It doesn’t check for updates; the App Store handles them. It has no crash reports and no license keys, so it never contacts the activation server. It connects only for the things described above that you trigger (sending feedback, showing the location map, downloading the recognition model) and to talk to the App Store when you buy Pro in the app.</p>
<h2>Buying Pro</h2>
<p>On flipic.app, payment is handled by Stripe. Stripe collects your card details; we never see the full card number. After you pay, pay.flipic.app reads the order’s email address and order ID from Stripe and generates your license key. The key contains the email and order ID and is checked offline on your Mac. Order records stay in our Stripe account and are used to recover keys, handle refunds and keep accounts. On activation, Flipic Lens sends the key to pay.flipic.app for verification; the server stores only a hash of the order ID and a hash of this Mac’s device ID (no email or computer name), to limit each key to 2 Macs, and the app checks in again from time to time; the IP address is used only for rate limiting and is not stored. The payment confirmation page reports the order amount and Stripe order ID to Google Analytics to count purchases, without your email. See the <a href="{STRIPE_PRIVACY}">Stripe Privacy Policy</a>.</p>
<p>When you recover a key, the email and last four card digits (or receipt number) you enter are used only to look up the order in Stripe and are not stored. To stop repeated guessing, the recovery page limits requests per minute by IP address; the address is not stored.</p>
<p>When you buy Pro in the App Store version (subscription or one-time), Apple handles payment, renewals and your account. We don’t receive your name, email or payment details; the app only learns from the App Store whether Pro is active. See the <a href="{APPLE_PRIVACY}">Apple Privacy Policy</a>.</p>
<h2>The website</h2>
<p>flipic.app is hosted on Cloudflare. Cloudflare keeps access logs (such as IP address and browser type) for security and operation.</p>
<p>The website uses Google Analytics 4 to count visits and clicks on buttons such as download, buy and GitHub, so we can see where visitors come from and which pages help. Google Analytics stores cookies in your browser and records pages, referrers, approximate region and device type; it doesn’t record your full IP address or who you are, and we keep its advertising and personalization features off. Visits from the European Economic Area, the UK and Switzerland don’t get analytics cookies. The site has no ads and no third-party fonts. See the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>. The app itself contains no analytics.</p>
{wl_en}<h2>Questions and deletion</h2>
<p>To find out what we hold about your order, or to ask us to delete it, email {m}. Payment records we must keep for tax and accounting law are excepted.</p>
<h2>Changes</h2>
<p>If the way the app or services handle information changes, we’ll update this page and its effective date.</p>
</div>""")
        terms = ("/en/terms/", "Terms of Use", f"Terms of use for {both}: free features, the one-time Pro purchase, refunds and disclaimers.", f"""
<p class="lede">Effective {eff}</p>
<div class="prose">
<p>These terms cover Flipic Lens (the version downloaded from flipic.app and GitHub) and {store_full}, provided by {op}. By using the app you agree to them.</p>
<h2>Free use</h2>
<p>Flipic Lens’s source code is available under the <a href="https://opensource.org/license/mit">MIT License</a> on <a href="{GITHUB}">GitHub</a>. Viewing, ratings, marks, filtering, export and Cleanup Mode are free and need no account.</p>
<h2>Pro</h2>
<p>Pro bought on flipic.app is a one-time purchase, not a subscription. Once bought, the Pro features in later updates are included. Pro is for the buyer’s own use only: one key can be activated on up to 2 of the buyer’s own Macs. Activation binds the key to the Mac, and a third Mac can’t be activated.</p>
<p>Please don’t share a license key from flipic.app publicly. Keys that are shared publicly, and keys for orders that were refunded or disputed, are revoked.</p>
<h2>Refunds</h2>
<p>Within {days} days of buying Pro on flipic.app, email {m} with the address you paid with and we’ll refund you in full, no reason needed. The key is revoked after the refund.</p>
<p>For App Store purchases, refunds follow Apple’s rules; request one at <a href="{APPLE_REFUND}">reportaproblem.apple.com</a>.</p>
<h2>App Store version</h2>
<p>{store_full} is a free download with the same free features as the website version. Pro is bought in the app as a monthly or yearly auto-renewing subscription, or as a one-time purchase. Subscriptions renew automatically within 24 hours before the end of each period unless cancelled; you can cancel any time in your App Store account settings and keep Pro until the period ends. Pro bought on the App Store and Pro bought on flipic.app are separate and don’t carry over. The App Store version is also subject to the <a href="{APPLE_EULA}">Apple Standard EULA</a>; where the two differ, Apple’s agreement applies.</p>
<h2>Liability</h2>
<p>The app is provided as is. Deleting, moving and batch-sorting photos changes your files; deleted photos go to the Trash first. Back up important photos before working on them. To the extent the law allows, we aren’t liable for data loss or other indirect damage from using the app.</p>
<h2>Contact and changes</h2>
<p>Questions go to {m}. If these terms change, we’ll update this page and its effective date.</p>
</div>""")
    return [privacy, terms]


def render_legal(lang, page):
    path, title, desc, body = page
    out = head(lang, path, title + (" | Flipic Lens" ), desc, []) + header(lang, path)
    return out + f'<main id="main" class="narrow article">\n<h1>{title}</h1>{body}\n</main>\n' + footer(lang)


def render_changelog(lang):
    is_zh = lang == "zh"
    path = "/changelog/" if is_zh else "/en/changelog/"
    title = "更新记录" if is_zh else "Changelog"
    desc = ("Flipic Lens 各版本更新记录：摄影质检、EXIF 参数相框、外接盘 SSD 缓存、跟随访达排序、胶片滤镜与水印导出。" if is_zh
            else "Flipic Lens release history: photographer inspection tools, EXIF photo frame, external drive SSD cache, Same as Finder sort, film looks and watermarks.")
    entries_zh = [
        ("1.0.64", "2026-11-24", [
            "Pro 工作台全视图支持按 V 切换看 JPG / RAW：胶片条、宫格 + 大图、单张、多图对比与宫格均可按 V（或菜单 / 右键）快速切换同名配对照片，保留当前缩放倍数与查看位置；胶片条底部状态栏与大图信息栏新增「+ NEF / + JPG」配对后缀标记。",
            "文件操作类型明细提示（免费 + Pro）：删除、⌘Z 放回、⌘C 拷贝、导出复制/移动、发送到常用文件夹与重命名后，提示条会清晰写明实际处理到的文件类型（例如「仅 JPG」或「JPG + NEF + XMP」），不再担心漏删或误删 RAW 与 XMP 旁车文件。",
        ]),
        ("1.0.63", "2026-11-24", [
            "错误图片后缀检测与一键修复（免费）：自动识别文件头与后缀不符的图片（如豆包 / AI 绘图 / 网页保存的 PNG、WebP 被写成 .jpg 导致访达无法显示缩略图与后期软件报错），看图页顶部轻提示胶囊、照片信息栏（I）与右键菜单均可一键无损修正。",
            "整文件夹批量修复（「工具 › 修复错误的图片后缀…」，看图窗口与工作台通用）：几十毫秒只扫前 32 字节文件头（跳过所有相机 RAW 与视频），提供「无损修正为真实后缀（同步 .xmp / .MOV）」与「转为真正的 JPEG（透明底自动铺白，保留 .jpg 名称与 EXIF/标签）」两种模式。",
            "裁剪、拉直、加边框另存副本改用真实格式后缀，不再产出假 JPG；慢盘 128 KB JPEG 前缀快读新增真实 FF D8 FF 魔数校验。",
        ]),
        ("1.0.62", "2026-11-23", [
            "看图页 & 工作台快捷排序（⇅）：看图页右上角（及照片右键菜单「排序方式 ▸」）和工作台 5 种视图顶栏新增 ⇅ 排序按钮，浏览与挑片时一键切换跟随访达、文件名、拍摄时间、修改/创建/添加时间、大小、类型、标星与升序/降序。",
            "缩略图栏鼠标滚轮翻图：鼠标悬停在看图页或工作台底部胶片缩略图条时，上下滚轮直接切换上一张/下一张（遵循滚轮翻页方向设置），双指横向滑动保持缩略图滚动，鼠标侧键 3/4 同步翻页；工作台宫格支持 ⌥ + 滚轮与侧键翻图。",
            "精简 14 种语言的「鼠标与触控板」设置说明文案，横向滚轮与侧键行为一眼读懂。",
        ]),
        ("1.0.61", "2026-11-23", [
            "Pro 工作台新增最右侧独立照片信息栏：顶部固定 ⓘ 按钮与快捷键 I / ⇧I 开关，宽屏圆角卡片贴边一屏显示直方图、曝光全参、相机镜头、文件色域、IPTC 说明翻译与地图，窄屏自动切为右侧浮层；支持 5 种视图全联动（含多图对比焦点格跟随）。",
            "工作台胶片条与单张视图底部字幕同步补全快门、光圈、ISO、焦距与像素尺寸。",
        ]),
        ("1.0.60", "2026-11-23", [
            "ExFAT 与外接机械硬盘冷读取深度加速（免费 + Pro）：按卷优先级单通道顺序调度、POSIX 顺序大块读盘、单次打开合并解码（RAW 前 4 MB 预览优先）、目录级 .xmp 索引免无效探测、统一跳过 ExFAT/FAT/NTFS/SMB 扩展属性寻道，工作台网格与胶片条同步接入本机 SSD 缩略图缓存与增量刷新。",
            "Pro 工作台重大升级：可折叠左侧边栏（⌃⌘S，顶部按钮与系统红黄绿按钮精准齐平）、胶片条模式（大图 + 底部缩略图，T 键快速切换）、2–9 张多图同屏对比（自适应网格布局 + 同步缩放/平移/放大到眼睛）、实时 1★–5★ 计数双色胶囊。",
            "看图主窗口工作台跳转按钮独立移至左上角胶囊；修复同星级按键取消评分、⌘A 全选及多选右键批量评分 / 对比体验。",
        ]),
        ("1.0.59", "2026-11-22", [
            "外接硬盘本机 SSD 预览缓存（上限 500 MB、LRU 自动清理，可在「设置 › 看图 › 外接盘加速」开关或清空）+ RAW 前 4 MB 内嵌预览快扫 + 慢盘单通道顺序调度与首图优先。",
            "单图质检套件（免费）：H 实时 RGB/亮度直方图（含死黑/过曝占比）、J 过曝/暗部斑马纹警示、K 焦点峰值、A 相机对焦框（EXIF SubjectArea、XMP MWG-RS、Sony 与 Fujifilm MakerNotes）。",
            "EXIF 参数相框（⇧B，免费）：自动排版机身、镜头、焦距、光圈、快门与 ISO，适配导出与批量转换。",
            "EXIF 变量模板批量重命名（免费）：支持 {date}、{time}、{camera}、{focal}、{name}、{seq} 与实时预览；同步改名 .xmp/.MOV 附属文件。",
            "XMP 颜色标签（xmp:Label）与 Lightroom / Capture One 互通；导出新增「抹掉相机与镜头序列号」；水印新增 {index} 自动序号。",
            "Pro 新增：按客户文件名清单挑图（跨扩展名 + RAW+JPG 配对），胶片面板支持导入自定义 .cube 3D LUT（17/33/64/65 级）。",
        ]),
        ("1.0.58", "2026-11-21", [
            "新增「跟随访达」排序（未手动改过排序时默认开启），按访达当前文件夹的排序方式直接翻页。",
        ]),
        ("1.0.57", "2026-11-21", [
            "新增按「添加日期」排序（对齐访达的添加日期，缺项回落创建日期）。",
        ]),
        ("1.0.43", "2026-11-16", [
            "新增导出水印（免费）：支持文字与图片 logo、斜向平铺或九宫格定位，⌘S 导出、批量转换与导出预设可用。",
            "Pro 新增：胶片滤镜十款（两款免费 + 八款 Pro）、导出预设（⌥⌘1–⌥⌘9）。",
        ]),
        ("1.0.36", "2026-11-14", [
            "照片信息面板支持读取 IPTC 标题、说明、版权与关键词，支持 macOS 15+ 本机离线说明翻译。",
            "新增裁剪与拉直（⇧R），记住上次裁剪比例，RAW 裁剪另存为 JPEG 不伤原片。",
        ]),
        ("1.0.23", "2026-11-10", [
            "正式启用名称 Flipic Lens，同时发布视频播放（MP4/MOV/M4V）、文件夹实时监听与触控板水平翻页。",
        ]),
        ("1.0.0", "2026-11-04", [
            "Pro 工作台（⌥⌘B）默认开启、按内容/文字本机搜索、放大到眼睛（E）、修图前后对比与 Developer ID 签名公证。",
        ]),
    ]
    entries_en = [
        ("1.0.64", "2026-11-24", [
            "Switch JPG / RAW with V across all Pro Workbench views: Filmstrip, Grid + Preview, Single, Multi-Compare and Grid now all support V (plus menu bar and context menu) to switch paired shots while keeping zoom and pan position; Filmstrip and Preview caption bars now show paired format badges (+ NEF / + JPG).",
            "Clear file-type action feedback (Free + Pro): Trash, ⌘Z Undo, ⌘C Copy, Export Copy/Move, Send To and Rename toasts now explicitly show which file types were affected (such as JPG only vs. JPG + NEF + XMP), removing guesswork around RAW and XMP sidecars.",
        ]),
        ("1.0.63", "2026-11-24", [
            "Mismatched image extension detection & one-click repair (Free): detects images whose actual header differs from their filename extension (such as PNG or WebP saved as .jpg, which breaks Mac Finder thumbnails and Photoshop) with a dismissible viewer banner, an inline Photo Info (I) card, and right-click quick fix.",
            "Batch folder repair (Tools › Fix Mismatched Extensions…, available in Viewer and Workbench): scans only the first 32 header bytes in milliseconds (skipping all camera RAW and video files), offering both lossless extension rename (syncing .xmp / .MOV sidecars) and real JPEG conversion (white background flattening for alpha PNGs, keeping .jpg names, EXIF and Finder tags).",
            "Crop, Straighten and Border copies now write the actual matching extension instead of inheriting broken extensions; slow-storage 128 KB JPEG header fast-path now verifies real FF D8 FF magic bytes.",
        ]),
        ("1.0.62", "2026-11-23", [
            "Quick Sort (⇅) in Viewer & Workbench: added a ⇅ sort menu to the top-right bar of both the single Viewer (plus a Sort By ▸ context submenu) and all 5 Workbench views for switching between Same as Finder, Name, Capture Date, Date Modified/Created/Added, Size, Kind, Rating and ascending/descending order on the fly.",
            "Filmstrip mouse-wheel photo flipping: hovering over the bottom filmstrip in Viewer or Workbench lets vertical scroll flip previous/next photo (respecting wheel direction settings), while two-finger horizontal swipe still scrolls the strip and mouse side buttons 3/4 flip photos; Workbench grid supports ⌥ + wheel and side buttons.",
            "Streamlined Mouse & Trackpad settings descriptions across all 14 languages so horizontal-wheel and side-button behavior is immediately clear.",
        ]),
        ("1.0.61", "2026-11-23", [
            "Pro Workbench right Photo Info Inspector: fixed top-right ⓘ toggle and I / ⇧I shortcuts, docking as a rounded card on wide windows (histogram, exposure, camera/lens, file/color profile, IPTC + translation, GPS map in one screen) with automatic floating fallback on narrow windows; follows selection across all 5 views including Multi-Photo Compare focus.",
            "Workbench Filmstrip and Single caption bars now show shutter, aperture, ISO, focal length, and pixel dimensions.",
        ]),
        ("1.0.60", "2026-11-23", [
            "Deep ExFAT & external HDD cold-read acceleration (Free + Pro): per-volume priority serial scheduler, POSIX large-chunk sequential reads, single-open decoding (4 MB RAW prefix preview first), directory-level .xmp indexing, unified skipping of Finder tags/AppleDouble seeks on ExFAT/FAT/NTFS/SMB, plus local SSD thumbnail caching & incremental reloads for Workbench.",
            "Major Pro Workbench upgrades: collapsible left sidebar (⌃⌘S, toggle aligned with window traffic lights), Filmstrip view mode (T quick toggle), 2–9 photo multi-pane Compare with adaptive grids & synced zoom/pan/eye zoom, and live per-star split-pill counters.",
            "Dedicated top-left Workbench jump pill in the main viewer; fixed same-star keyboard toggle-off, ⌘A select-all across all views, and multi-select batch rating / compare context menu.",
        ]),
        ("1.0.59", "2026-11-22", [
            "External drive local SSD preview cache (500 MB cap, automatic LRU cleanup, toggle/clear in Settings › Viewing › External drives) + 4 MB RAW prefix embedded-preview scan + single-lane slow-drive I/O.",
            "Single-viewer inspect suite (Free): H RGB/luma histogram with S/H %, J highlight/shadow clipping zebras, K focus peaking, A camera AF point (EXIF SubjectArea, XMP MWG-RS, Sony and Fujifilm MakerNotes).",
            "EXIF photo frame (⇧B, Free): auto-typesets camera, lens, focal length, aperture, shutter and ISO, wired into Export and Batch Convert.",
            "EXIF template batch rename (Free): {date}, {time}, {camera}, {focal}, {name}, {seq} tokens, 5 presets, live preview and companion .xmp/.MOV sync.",
            "Standard xmp:Label color tags (Lightroom & Capture One compatible), export camera/lens serial stripping, and {index} watermark sequence token.",
            "Pro additions: Match from a client’s filename list (cross-extension & RAW+JPG pair aware), plus custom .cube 3D LUT import (17/33/64/65-point) in the Film Looks panel.",
        ]),
        ("1.0.58", "2026-11-21", [
            "New Same as Finder sort option (default if you never picked a sort), matching the folder’s Finder order.",
        ]),
        ("1.0.57", "2026-11-21", [
            "Added Sort by Date Added (matches Finder’s Date Added attribute).",
        ]),
        ("1.0.43", "2026-11-16", [
            "Free export watermarks (text or image logo, tiled or 9 positions) across Export, Batch Convert and presets.",
            "Ten film looks (2 free, 8 Pro) and one-step Export Presets (⌥⌘1–⌥⌘9, Pro).",
        ]),
        ("1.0.36", "2026-11-14", [
            "Read IPTC headlines, captions, credit and keywords in Photo Info, plus on-device caption translation on macOS 15+.",
            "Crop & Straighten (⇧R) with remembered aspect ratios.",
        ]),
        ("1.0.23", "2026-11-10", [
            "Renamed to Flipic Lens; added built-in video playback (MP4/MOV/M4V), live folder watching and trackpad horizontal paging.",
        ]),
        ("1.0.0", "2026-11-04", [
            "Pro Workbench (⌥⌘B), on-device content & text search, zoom to eyes (E), before & after comparison, and Apple notarization.",
        ]),
    ]
    rows = entries_zh if is_zh else entries_en
    sections = []
    for ver, dt, bullets in rows:
        lis = "".join(f"<li>{esc(b)}</li>" for b in bullets)
        sections.append(f'<h2>v{ver} <span class="updated">({dt})</span></h2><ul>{lis}</ul>')
    intro = (f'<p>当前版本 <strong>{VERSION}</strong>（安装包约 {SIZE}）。完整历史版本与安装包见 <a href="{GITHUB}/releases">GitHub Releases</a>。</p>'
             if is_zh else
             f'<p>Current version <strong>{VERSION}</strong> (about {SIZE} download). Every release archive is also on <a href="{GITHUB}/releases">GitHub Releases</a>.</p>')
    schema = [crumbs_schema(lang, title, path)]
    out = head(lang, path, title + " | Flipic Lens", desc, schema) + header(lang, path)
    return (out + f'<main id="main" class="narrow article">\n<h1>{title}</h1>\n<div class="prose">{intro}{"".join(sections)}</div>\n'
            f'<div class="cta"><p>{T[lang]["cta"]}</p>{download_block(lang)}</div>\n</main>\n' + footer(lang))


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
    shutil.copytree(DOCS / "shots", OUT / "shots" / SHOTS_V,
                    ignore=None if SHOW_WATERMARK else shutil.ignore_patterns("wm-*"))
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
        cl_path = "/changelog/" if lang == "zh" else "/en/changelog/"
        write(cl_path, render_changelog(lang))
        urls.append(cl_path)
        if LEGAL_READY:
            for page in legal_pages(lang):
                write(page[0], render_legal(lang, page))
                urls.append(page[0])
    if not LEGAL_READY:
        print("注意：LEGAL 没填完（运营主体、邮箱、退款天数），隐私政策和用户协议这次没有生成")

    # sitemap：每个地址带上中英对应版本
    page_dates = {g["path"]: g["updated"] for lang in ("zh", "en") for g in GUIDES[lang]}
    items = []
    for u in urls:
        if u in PAIRS:
            zh, en = u, PAIRS[u]
        elif u in PAIRS_REV:
            zh, en = PAIRS_REV[u], u
        else:
            zh = en = None
        alts = ""
        if zh and en:
            alts = (f'<xhtml:link rel="alternate" hreflang="zh-CN" href="{BASE}{zh}"/>'
                    f'<xhtml:link rel="alternate" hreflang="en" href="{BASE}{en}"/>'
                    f'<xhtml:link rel="alternate" hreflang="x-default" href="{BASE}{en}"/>')
        pri = "1.0" if u in ("/", "/en/") else "0.7"
        items.append(f"<url><loc>{BASE}{u}</loc><lastmod>{page_dates.get(u, UPDATED)}</lastmod><priority>{pri}</priority>{alts}</url>")
    (OUT / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
                                     'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + "\n".join(items) + "\n</urlset>\n")
    (OUT / f"{INDEXNOW_KEY}.txt").write_text(INDEXNOW_KEY)
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {BASE}/sitemap.xml\n")

    WM_LLMS = ("- Export watermark (free): text or picture, tiled or single position, adjustable size, opacity, color and angle, plus {index} sequence number; used in Export, Batch Convert and export presets; originals are never changed; videos and animated images are skipped.\n" if SHOW_WATERMARK else "")
    guide_lines = "\n".join(f"- [{g['title']}]({BASE}{g['path']}): {g['desc']}" for lang in ("en", "zh") for g in GUIDES[lang])
    (OUT / "llms.txt").write_text(f"""# Flipic Lens

> Flipic Lens is a free, open-source (MIT) Mac photo viewer and culling tool for macOS 13+. Double-click any photo and page through the whole folder with the arrow keys. {SIZE} universal download (Apple silicon + Intel), notarized by Apple, no account, photos stay on your Mac.

Key facts:
- Paging & sorting: ← → through every image in the folder (default Same as Finder sort, or Date Added, Date Taken, Date Modified, Name, Size); Space wraps the window to the photo; hold 0 to zoom to 100% at the pointer.
- Single-viewer inspection tools (free): H live RGB/luma histogram with highlight/shadow clipping %, J red/blue highlight and shadow clipping zebras, K focus peaking, A camera AF point overlay (EXIF SubjectArea, XMP mwg-rs:Regions, Sony 0x2027, Fujifilm 0x1023).
- External drive acceleration (free): persistent local Mac SSD preview & thumbnail cache (500 MB LRU, toggle/clear in Settings › Viewing › External drives) for external hard drives, SD cards and network shares; 4 MB prefix RAW embedded-preview scan; single-lane sequential I/O on slow storage; 100% zoom always reads the original.
- Star ratings 1–5 and color labels 6–9 written as standard XMP (xmp:Rating and xmp:Label embedded for JPEG/HEIC/TIFF/DNG, .xmp sidecar for proprietary RAW), readable by Lightroom, Bridge and Capture One; color tags also sync with Finder tags.
- Cleanup Mode (free): finds similar bursts, exact duplicates, closed eyes and blurry photos on-device using Apple Vision.
- EXIF photo frame (free, ⇧B): adds camera, lens, focal length, aperture, shutter and ISO caption along the bottom border with auto light/dark ink contrast; works in Export, Batch Convert and presets.
- EXIF template batch rename (free): {{date}}, {{time}}, {{camera}}, {{focal}}, {{name}}, {{seq}} tokens, 5 presets, live preview, companion .xmp/.MOV rename.
- Export & privacy (free): batch convert HEIC/JPEG/PNG, long-edge and MB size caps, sRGB conversion, lossless 90° rotation, optional GPS stripping and camera/lens serial-number stripping.
- IPTC captions & translation (free): press I to read IPTC Headline/Description/credit/copyright/keywords (read-only); on-device translation via macOS 15+.
- Crop & Straighten (free, ⇧R): aspect ratios remembered across photos; RAW crops save as JPEG without altering RAW originals.
- Film looks & custom .cube 3D LUTs (⇧F): ten built-in film looks (2 free, 8 Pro) plus custom 3D .cube LUT import (Pro, 17/33/64/65-point) with Strength, Grain and Halation sliders, usable in Save a Copy, Export, Batch Convert and export presets.
- Pro culling additions (optional one-time purchase, 7-day trial in every download): Workbench project grid (⌥⌘B), zoom to eyes (E), on-device content & OCR text search (⌘F), match photos from a client's filename list (cross-extension & RAW+JPG pair aware), before & after comparison, RAW+JPG pair merging (V), export presets (⌥⌘1–9).
- Location map in the info panel (loads on request); photos taken in mainland China are converted from WGS-84 to GCJ-02 for Apple Maps alignment.
{WM_LLMS}- Optional HDR display, customizable shortcuts, global show/hide shortcut, ⌘E hand-off to Photoshop/Lightroom/Capture One.
- Formats: JPEG, PNG, HEIC, WebP, GIF, TIFF, AVIF, JPEG XL, camera RAW (Sony, Canon, Nikon, Fujifilm, more), MP4/MOV/M4V video.
- Reproducible performance: built-in `--bench <folder>` CLI flag; baseline on Apple M5 Pro with 50×24 MP JPEGs: 50 ms first open, 1 ms median rapid paging, 17 ms max 1:1 zoom stall.
- Download: {BASE}/download/Flipic.dmg · Source: {GITHUB} · Current version: {VERSION} · Changelog: {BASE}/en/changelog/

## How Flipic Lens compares
- [Adobe Bridge]({BASE}/en/guides/adobe-bridge-alternative-mac/): choose Bridge for metadata, keywords, Camera Raw and Adobe batch work; choose Flipic Lens for a catalog-free folder cull.
- [Photo Mechanic]({BASE}/en/guides/photo-mechanic-alternative-mac/): choose Photo Mechanic for high-volume card ingest, IPTC editing, keywording and delivery; choose Flipic Lens for a lightweight Mac paging, inspection and rating pass.
- [FastRawViewer]({BASE}/en/guides/fastrawviewer-alternative-mac/): choose FastRawViewer for sensor-level raw-data histograms (before demosaic) and Shadow Boost exposure recovery checks; choose Flipic Lens for free arrow-key culling, display-referred histogram/clipping/peaking/AF point, XMP ratings & color labels, Cleanup Mode and external drive SSD caching.
- [XnView MP]({BASE}/en/guides/xnview-mp-alternative-mac/): choose XnView MP for format breadth, batch tools and cross-platform work; choose Flipic Lens for a quick Mac cull.
- [ApolloOne]({BASE}/en/guides/apolloone-alternative/): choose ApolloOne for Mac-native metadata editing, stacks and quick edits; choose Flipic Lens for a free, open-source catalog-free first cull.
- [FlowVision]({BASE}/en/guides/flowvision-alternative/): choose FlowVision for waterfall or grid browsing with video; choose Flipic Lens for arrow-key culling with XMP ratings, labels and inspection overlays.
- [Lightroom Classic]({BASE}/en/guides/cull-before-lightroom/): choose Lightroom Classic for editing and a catalog; choose Flipic Lens to cull before import.
- [Preview]({BASE}/en/guides/mac-preview-next-image/): choose Preview for a quick look at a file; choose Flipic Lens to page and rate a whole folder.
- [Photos](https://support.apple.com/guide/photos/welcome/mac): choose Photos for a personal Apple photo library; choose Flipic Lens for a folder-based first cull.
- [All comparisons]({BASE}/en/compare/): one table of Mac viewers, cullers and catalog tools.

## Pages
- [Flipic Lens (English)]({BASE}/en/)
- [Flipic Lens（中文）]({BASE}/)
- [Flipic Lens Pro (English)]({BASE}/en/pro/)
- [Flipic Lens Pro（中文）]({BASE}/pro/)
- [Changelog (English)]({BASE}/en/changelog/)
- [更新记录（中文）]({BASE}/changelog/)
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
/download/PixDeck.dmg /download/Flipic.dmg 301
/macphoto/ / 301
/macphoto/en/ /en/ 301
/macphoto/download/* /download/:splat 301
/zh / 301
/zh/ / 301
""")
    (OUT / "404.html").write_text(head("zh", "/404", "页面不存在 | Flipic Lens", "这个页面不存在。", []).replace(
        '<link rel="canonical" href="https://flipic.app/404">\n', '<meta name="robots" content="noindex">\n')
        + header("zh", "/") + '<main id="main" class="narrow article"><h1>页面不存在</h1><p class="prose">'
        '回到 <a href="/">Flipic Lens 首页</a>，或看看 <a href="/en/">English</a>。</p></main>\n' + footer("zh"))
    print("built", len(urls), "pages ->", OUT)


if __name__ == "__main__":
    main()
