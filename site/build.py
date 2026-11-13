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
SIZE = "5 MB"
# 样式和脚本按内容取版本号：它们缓存一年，内容一变地址就变
import hashlib
# 截图也一样：放进按内容命名的子文件夹，换了图地址就变
SHOTS_V = hashlib.sha1(b"".join(f.read_bytes() for f in sorted((REPO / "docs/shots").iterdir()) if f.is_file())).hexdigest()[:8]
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
}

# Pro 购买：Stripe 付款链接和价格。没填时页面显示「即将开放购买」
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
    "effective": "2026-11-04",          # 生效日期
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
        "other": "English", "download": "免费下载 Mac 版", "github_alt": "也可以从 <a href=\"{gh}/releases/latest\">GitHub</a> 下载",
        "facts": ["免费开源", "安装包约 5 MB", "macOS 13 或更新", "Apple 芯片与 Intel 通用", "已通过 Apple 公证", "默认不联网"],
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
        "other": "中文", "download": "Download for Mac, free", "github_alt": "or get it from <a href=\"{gh}/releases/latest\">GitHub</a>",
        "facts": ["Free and open source", "About 5 MB download", "macOS 13 or later", "Apple silicon and Intel", "Notarized by Apple", "Offline by default"],
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


def download_block(lang, big=True, brew=False):
    t = T[lang]
    brew_line = (f'\n<p class="brew">{"或者用 Homebrew 装：" if lang == "zh" else "Or with Homebrew: "}'
                 '<code>brew install xmasdong/flipic/flipic-lens</code></p>') if brew else ""
    facts = "".join(f"<li>{f}</li>" for f in t["facts"])
    return f"""<div class="get">
  <a class="btn" href="/download/Flipic.dmg" download>{DOWNLOAD_ICON}{t['download']}</a>
  <span class="alt">{t['github_alt'].format(gh=GITHUB)}</span>
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
    return f"""<footer class="wrap">
  <nav>{nav}</nav>
  <p>{t['footer_line'].format(v=VERSION)} · <a href="{GITHUB}">{t['src']}</a> · <a href="{GITHUB}/issues">{t['feedback']}</a> · <a href="{GITHUB}/releases">{t['releases']}</a>{legal_links(lang)}</p>
  <p>{t['footer_credit']}</p>
</footer>
<script src="/site.js?v={ASSET_V}" defer></script>
</body>
</html>
"""


def app_schema(lang, desc):
    return {
        "@context": "https://schema.org", "@type": "SoftwareApplication", "name": "Flipic Lens",
        # 「Flipic Lens」这个词常被当成拼错的 flip icon / flipaclip，写全称帮搜索引擎认出是哪个软件
        "alternateName": ["Flipic", "PixDeck", "Flipic for Mac", "Flipic Lens for Mac", "Flipic Image Viewer", "Flipic Lens Image Viewer", "Flipic 看图", "Flipic Lens 看图"],
        "sameAs": [GITHUB, f"{GITHUB}/releases"],
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
             "<p>双击文件夹里任意一张，<kbd>→</kbd> 下一张，<kbd>←</kbd> 上一张，整个文件夹都能翻到。排序默认按文件名，连拍的话改成按拍摄时间会顺一些。</p>"
             "<p>后面几张会先在后台准备好，4800 万像素的照片按住方向键一直翻也跟得上。按一下 <kbd>空格</kbd>，窗口会变成照片的比例，竖拍就是个竖长的窗口。</p>"),
            ("zoom.webp", "Flipic Lens 在鼠标位置放大到 100% 查看对焦", "看清楚焦点对没对上",
             "<p>鼠标移到眼睛上按住 <kbd>0</kbd>，就以那儿为中心放大到 100%，对没对上一下就看出来了，松手回到整张。用触控板捏合或者滚轮缩放，也是围着鼠标的位置放大。</p>"
             "<p>连拍里拿不准留哪张的话，按 <kbd>C</kbd> 把两张并排放，放大、拖动的时候两张一起动，方便对着同一个地方比。</p>"),
            ("settings.webp", "Flipic Lens 设置窗口：快捷键可以自己改", "打的星 Lightroom 也认",
             "<p><kbd>1</kbd> 到 <kbd>5</kbd> 打星，再按一次同样的数字取消，<kbd>P</kbd> 标记要留的。星级存成标准的 XMP，Lightroom、Bridge、Capture One 都读得到。JPEG 和 HEIC 只改里面的信息，不会重新压缩；RAW 的星级写在旁边一个同名的 .xmp 文件里。标记是访达标签，换个软件也还在。</p>"
             "<p>挑完按 <kbd>⇧P</kbd> 只看标记过的，或者只看几星以上的，再按 <kbd>⇧⌘E</kbd> 一起拷到别的文件夹。快捷键用不惯的话，设置里每个都能改。</p>"),
            ("cleanup.webp", "Flipic Lens 清理模式：相似连拍分组与推荐保留", "让它先把废片找出来",
             "<p>一场活动拍下来几百张，可以按 <kbd>⇧⌘K</kbd> 打开清理模式。它在你自己的 Mac 上把整个文件夹过一遍，相似的连拍、一模一样的文件、闭眼的、糊的分别归到一起，每组里标出最清楚的那张。</p>"
             "<p>删哪些还是你说了算，点了「移到废纸篓」才会删，删错了 <kbd>⌘Z</kbd> 能撤回来。同名的 RAW 和 JPG 会一起处理。</p>"),
            ("exif.webp", "Flipic Lens 照片信息面板显示相机、镜头与拍摄参数", "参数按 I 才出来",
             "<p>平时画面上只有照片，想看参数就按 <kbd>I</kbd>，右上角会列出相机、镜头、快门、光圈、ISO 和拍摄时间，看完按 <kbd>Esc</kbd> 关掉。</p>"
             "<p>iPhone 拍的 HDR 照片也能按 HDR 显示，亮的地方比普通白色更亮，跟系统「预览」看到的一样。这个要在设置里打开，屏幕也得支持 HDR。</p>"),
        ],
        "more_title": "其他功能",
        "more": [
            ("一次看四张", "按 ⇧C 可以四张一起并排看，放大、拖动也是一起动。"),
            ("用后期软件打开", "按 ⌘E 用 Photoshop、Lightroom 或 Capture One 打开当前照片，有同名 RAW 时打开 RAW。"),
            ("RAW 和 JPG 当一张看（Pro）", "RAW 加 JPG 一起拍的话，同名的两个文件只显示一张，按 V 换着看。打星、标记、删除都只算一张。"),
            ("修图前后对比（Pro）", "修好导出的那张跟原片叠在一起，按住 \\ 看原片，一松手就是修过的。"),
            ("按星级分文件夹（Pro）", "挑完可以按星级一下分到几个子文件夹里，也可以用 ⌥1 到 ⌥9 把照片丢进常用的文件夹。"),
            ("窗口置顶和分享", "点右上角的图钉，窗口就一直浮在最上面，修图时拿来对照参考图挺方便。分享按钮能用隔空投送、信息、邮件发出去。"),
            ("幻灯片", "每张停 1 到 10 秒，切换的渐变时长也能调。单击暂停，暂停时可以手动翻页和打星。"),
            ("HEIC 批量转 JPG", "整个文件夹一次转成 JPEG、PNG 或 HEIC，转好的放在子文件夹里，原图不动。"),
            ("旋转和拉直", "转 90° 只改方向标记，JPEG、HEIC 和相机 RAW 都不重新编码，画质没有损失。按 ⇧R 拉直，会自动裁成最大的正矩形。"),
            ("批量重命名和导出", "可以按序号批量改名。导出时选格式和质量，导出前能看到大概多大。"),
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
                 ("I", "照片信息"), ("1–5", "打 1 到 5 星，再按一次取消"), ("S", "幻灯片放映"), ("⌘E", "在后期软件中编辑"),
                 ("⇧⌘K", "清理模式"), ("⌘⌫", "移到废纸篓"), ("⌘,", "设置，快捷键都能改")],
        "guides_title": "指南",
        "faq": [
            ("Flipic Lens 收费吗？", "看图、评星、标记、筛选、导出、清理这些都免费，没有广告，也不用注册账号，代码以 MIT 协议开源在 GitHub。另有可选的 <a href=\"/pro/\">Pro</a>，¥68 一次买断，下载后可以先试用 7 天，只加了批量处理和几个专业功能，大多数人用不上。"),
            ("Flipic Lens 和 App Store 上的 Flipic 是同一个吗？", "不是。Flipic Lens 原名 Flipic（更早叫 PixDeck），是 Mac 看图挑片软件；App Store 上的「Flipic: Photo Organizer」是另一位开发者的 iPhone App。为了区分，2026 年 11 月起改名 Flipic Lens，下载地址、激活码和设置都不变。"),
            ("从网上下载的安全吗？", "安装包用 Developer ID 签名，并通过了 Apple 公证，macOS 安装时会自动校验。Flipic Lens 默认不联网，不收集任何数据。"),
            ("能代替 Lightroom 挑片吗？", "挑片可以用它。在 Flipic Lens 里翻一遍、打星、删掉废片，打的星 Lightroom 和 Capture One 都读得到。调色修图还是回原来的软件，按 ⌘E 就能把当前这张在那边打开。"),
            ("和 Bridge、Photo Mechanic、Lightroom 有什么不同？", "Bridge 更像素材和元数据工具，Photo Mechanic 强在拷卡、IPTC 和交付，Lightroom Classic 要先进目录再挑。Flipic Lens 只做打开文件夹、翻页、看焦点、打星、标记和清理这一段，挑完再把留下的导入后期。完整对比见 <a href=\"/compare/\">Mac 看图与挑片软件对比</a>。"),
            ("Mac 上怎么看下一张图片？", "用 Flipic Lens 双击任意一张图片，按右方向键就是下一张，左方向键是上一张，同一个文件夹里的图片都能翻到。"),
            ("怎么设为默认看图软件？", "打开 Flipic Lens 的设置（⌘,），在「通用」里点「设为默认看图软件」，常见图片格式和相机 RAW 一次设好。"),
            ("能不能一次看很多张，像宫格那样？", "免费版翻片时，底部有缩略图栏，同一个文件夹的照片都列在那里；Pro 的工作台（⌥⌘B）把每场拍摄当一个项目，中间宫格里打星、标记、删除，右边是大图、拍摄参数和直方图。工作台是 Pro 功能，下载后可以先试用 7 天。"),
            ("支持哪些格式？", "JPEG、PNG、HEIC、WebP、GIF 动图、TIFF、AVIF、JPEG XL（macOS 14 起），以及索尼、佳能、尼康、富士等相机 RAW。"),
            ("Intel 芯片的 Mac 能用吗？", "能。Flipic Lens 同时支持 Apple 芯片和 Intel 芯片，需要 macOS 13 或更新版本。"),
            ("以前装过 PixDeck 怎么办？", "Flipic Lens 就是改名后的 PixDeck。把「应用程序」里的 PixDeck 拖进废纸篓，再装 Flipic Lens，原来的设置都会保留。"),
        ],
        "end": "下载 Flipic Lens",
    },
    "en": {
        "title": "Flipic Lens: free Mac photo viewer for arrow-key culling",
        "desc": "Free Mac photo viewer for culling: double-click a photo, arrow keys for the next photo, hold 0 to check focus, rate 1 to 5. Lightroom reads the stars.",
        "eyebrow": "A Mac photo viewer for culling a shoot",
        "h1": "Offload the card,<br>cull with the arrow keys",
        "lede": "After a shoot, Preview only pages through the files you opened together, and Lightroom wants an import first. Flipic Lens opens the folder as it is: double-click any photo, press → for the next one, hold 0 to zoom to 100% at the pointer and check focus, 1 to 5 to rate and P to mark keepers. Ratings are saved as standard XMP, so they are still there in Lightroom and Capture One.",
        "deck_hint": "This is the real Flipic Lens window. Press <kbd>←</kbd><kbd>→</kbd> on your keyboard to page through",
        "deck_alt": "Flipic Lens showing photo {n} in a folder", "prev": "Previous", "next": "Next",
        "features": [
            ("filmstrip.webp", "Flipic Lens thumbnail strip and navigation arrows", "Page through the card, no import",
             "<p>Double-click any photo in the folder and press <kbd>→</kbd> for the next one or <kbd>←</kbd> for the previous one. Sort by date taken, name, date modified or size; date taken keeps bursts in order.</p>"
             "<p>The next few photos are prepared in the background, so even 48-megapixel images keep up when you hold an arrow key. Press <kbd>Space</kbd> and the window takes the shape of the photo, tall for portrait shots.</p>"),
            ("zoom.webp", "Flipic Lens zooming to 100% at the pointer to check focus", "Hold 0 to check focus",
             "<p>Point at the eyes or whatever needs to be sharp and hold <kbd>0</kbd> to zoom to 100% around it; you can tell at once whether it’s in focus. Let go to see the whole photo. Pinch and scroll-wheel zoom also center on the pointer.</p>"
             "<p>Not sure which frame in a burst is sharper? Press <kbd>C</kbd> to put two side by side; zooming and dragging move both, so you compare the same spot.</p>"),
            ("settings-en.webp", "Flipic Lens Settings window with editable shortcuts", "Ratings and marks that Lightroom sees",
             "<p>Press <kbd>1</kbd> to <kbd>5</kbd> to rate (the same number again clears it) and <kbd>P</kbd> to mark keepers. Ratings are saved as standard XMP, which Lightroom, Bridge and Capture One read: JPEG and HEIC only get their metadata changed and are not recompressed, and camera RAW ratings go into a .xmp file with the same name. Marks are Finder tags, so they survive a change of app.</p>"
             "<p>When you’re done, <kbd>⇧P</kbd> shows only marked photos, or show only a minimum rating, and <kbd>⇧⌘E</kbd> copies them to another folder. Every shortcut can be changed in Settings.</p>"),
            ("cleanup-en.webp", "Flipic Lens Cleanup Mode grouping similar bursts", "Bursts, closed eyes and blur, found for you",
             "<p>After an event, press <kbd>⇧⌘K</kbd> for Cleanup Mode. Flipic Lens checks the folder on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry shots, marking the sharpest photo in each group.</p>"
             "<p>You decide what goes. Nothing is deleted until you click Move to Trash, and <kbd>⌘Z</kbd> undoes it. RAW and JPG files with the same name are handled together.</p>"),
            ("exif.webp", "Flipic Lens photo info panel with camera, lens and exposure", "Shooting details when you need them",
             "<p>Normally the window shows only the photo. Press <kbd>I</kbd> to see the camera, lens, shutter speed, aperture, ISO and date taken in the top-right corner, and <kbd>Esc</kbd> to close it.</p>"
             "<p>HDR photos from an iPhone can be shown in HDR, with highlights brighter than normal white, the same as in Preview. Turn it on in Settings; your display needs to support HDR.</p>"),
        ],
        "more_title": "More features",
        "more": [
            ("Four at once", "Press ⇧C to put four frames of a burst side by side; zooming and dragging move them together."),
            ("Open in your editor", "⌘E opens the current photo in Photoshop, Lightroom or Capture One, or its RAW file if there is one with the same name."),
            ("RAW and JPG as one (Pro)", "If you shoot RAW + JPG, the two files with the same name show as one photo; press V to switch between them. Ratings, marks and deletes count once."),
            ("Before and after (Pro)", "Put an edited export next to its original: hold \\ to see the original, release to see the edit."),
            ("Sort by rating (Pro)", "When you’re done, split the folder into subfolders by stars in one go, or send photos to favorite folders with ⌥1 to ⌥9."),
            ("Keep on top and share", "Click the pin at the top right to keep the window above other apps, handy for a reference image while editing. The share button sends the photo by AirDrop, Messages or Mail."),
            ("Slideshow", "Each photo stays 1 to 10 seconds and the crossfade length is adjustable. Click to pause; while paused you can page and rate."),
            ("Batch convert HEIC to JPG", "Convert a whole folder to JPEG, PNG or HEIC. The new files go into a subfolder and the originals are left alone."),
            ("Rotate and straighten", "90° turns only change the orientation tag, for JPEG, HEIC and camera RAW alike, so nothing is re-encoded. Straighten with ⇧R and the photo is cropped to the largest rectangle."),
            ("Batch rename and export", "Rename by sequence number. When exporting, pick a format and quality and see roughly how big the file will be."),
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
                 ("I", "Photo info"), ("1–5", "Rate one to five stars; again to clear"), ("S", "Slideshow"), ("⌘E", "Edit in your photo editor"),
                 ("⇧⌘K", "Cleanup Mode"), ("⌘⌫", "Move to Trash"), ("⌘,", "Settings; change any shortcut")],
        "guides_title": "Guides",
        "faq": [
            ("Is Flipic Lens free?", "Viewing, ratings, marks, filtering, export and Cleanup Mode are free, with no ads and no account, and the code is MIT licensed on GitHub. There is an optional <a href=\"/en/pro/\">Pro</a> upgrade, $12.99 once, with a 7-day trial in every download. It only adds batch and pro tools; most people won’t need it."),
            ("Is Flipic Lens the same as Flipic on the App Store?", "No. Flipic Lens was formerly Flipic (and PixDeck before that) and is a Mac culling app. “Flipic: Photo Organizer” on the App Store is an iPhone app from another developer. We renamed to Flipic Lens in November 2026 to keep the two apart; download links, license keys and settings are unchanged."),
            ("Is the download safe?", "It is signed with a Developer ID and notarized by Apple; macOS checks it on install. Flipic Lens is offline by default and collects no data."),
            ("Can it replace Lightroom for culling?", "For culling, yes; for editing, no. Page through, check focus, rate, mark and delete rejects in Flipic Lens, and Lightroom or Capture One will read the ratings. Edit in the app you already use; ⌘E opens the current photo there."),
            ("How is Flipic Lens different from Bridge, Photo Mechanic or Lightroom?", "Bridge is an asset and metadata browser, Photo Mechanic is built for ingest, IPTC and delivery, and Lightroom Classic works from an imported catalog. Flipic Lens covers the catalog-free first pass: open a folder, page, check focus, rate, mark and clean up, then send the keepers to your editor. See the <a href=\"/en/compare/\">full comparison</a>."),
            ("How do I see the next image on a Mac?", "Double-click any image in Flipic Lens and press the right arrow key for the next one, the left arrow for the previous one, across the whole folder."),
            ("How do I make it my default viewer?", "Open Settings (⌘,) and click Make Default Viewer under General; common image formats and camera RAW are set in one go."),
            ("Can I see many photos at once, in a grid?", "The free version has a thumbnail strip along the bottom while you page through a folder. Pro adds the Workbench (⌥⌘B): one project per shoot, a grid in the middle for rating, marking and deleting, with a large preview, shooting details and a histogram on the right. The Workbench is part of Pro, and every download includes a 7-day trial."),
            ("Which formats are supported?", "JPEG, PNG, HEIC, WebP, animated GIF, TIFF, AVIF, JPEG XL (macOS 14 or later) and camera RAW from Sony, Canon, Nikon, Fujifilm and others."),
            ("Does it run on Intel Macs?", "Yes. Flipic Lens is universal for Apple silicon and Intel and needs macOS 13 or later."),
        ],
        "end": "Download Flipic Lens",
    },
}

# ---------------------------------------------------------------- 指南

GUIDES = {"zh": [], "en": []}


def guide(lang, path, title, short, desc, summary, body, howto=None, faq=None, title_suffix=True,
          updated=UPDATED, published=UPDATED):
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
<p><strong>Flipic Lens</strong>：免费开源，安装包 5 MB 左右。双击一张图后用 <kbd>←</kbd> <kbd>→</kbd> 翻完整个文件夹，滚轮默认缩放，按 <kbd>0</kbd> 在鼠标处放大到 100%，这些都照着 Windows 看图软件的手感来做。快捷键都能在设置里改；用 Mos 改过滚轮方向的，可以把缩放方向反过来。</p>
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

guide("en", "/en/guides/mac-preview-next-image/", "Next photo in Mac Preview: why arrows fail, 3 fixes",
      "Next photo in Mac Preview",
      "To see the next photo in Preview, open the whole folder: select the photos in Finder, press ⌘↓, then use the arrow keys. Quick Look and Flipic Lens also work.",
      "Why the arrows stop, and how to page a whole folder",
      f"""<p>Preview opens only the file you double-clicked, so the arrow keys have nothing to move to. The direct fix is to open the folder's photos as a set: select them in Finder, press <kbd>⌘↓</kbd>, and the arrows work inside that Preview window. If you would rather start from one photo and keep paging, double-click it in Flipic Lens and press <kbd>→</kbd>.</p>
<h2>Next image in the same folder</h2>
<p>Open the folder in Finder, press <kbd>⌘A</kbd> to select everything, then <kbd>⌘↓</kbd> to open the files in one Preview window. The sidebar lists the set, and the arrow keys or <kbd>Page Down</kbd> move through it. This works, but opening hundreds of RAW files just to look at one is slow, and you make the trip back to Finder every time.</p>
<h2>Arrow keys: Preview, Quick Look, or a folder viewer</h2>
<p>If <kbd>←</kbd> <kbd>→</kbd> still do nothing, check what Preview has open: one document has no next image inside it. Apple's shortcut list sends the Up and Down arrows to the sidebar and <kbd>Page Down</kbd> to the next image in the window, so the keys only move inside a set that is already open (<a href="https://support.apple.com/guide/preview/cpprvw0003/mac">Apple Preview shortcuts</a>). Quick Look and a folder viewer take a different route.</p>
<h2>Quick Look: Space, then the arrow keys</h2>
<p>Quick Look is built into macOS and needs no extra app. Select one or more files in Finder and press <kbd>Space</kbd>; Apple's guide says the window shows a full-size preview without opening the file, and with several items selected the Left and Right arrow keys move between them (<a href="https://support.apple.com/guide/mac-help/view-and-edit-files-with-quick-look-mh14119/mac">Apple Quick Look guide</a>). MacMost makes the same case for viewing files rather than editing them (<a href="https://macmost.com/use-quick-look-instead-of-preview-to-view-files.html">MacMost</a>). It is a preview window tied to the Finder selection, not a folder browser, and closing it ends the session.</p>
<h2>MacBook trackpad: swipe left for the next photo</h2>
<p>In Flipic Lens, two fingers on the trackpad do what the arrow keys do. Swipe left or right to change photos, and left goes to the next one. Pinch to zoom, or double-click to switch between fit and 100%. The recording below is the real app, paging, zooming to 100% and rating in real time.</p>
<figure>{shot('demo-paging.webp', 'Flipic Lens paging through 34 RAW files from 34 different cameras', 960, 540)}<figcaption>Real-time screen recording: 34 RAW files from 34 different cameras.</figcaption></figure>
<h2>Like the Windows photo viewer: double-click, then page</h2>
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
<p><strong>Flipic Lens</strong>: free and open source, a 5 MB download. Double-click a photo and page with <kbd>←</kbd> <kbd>→</kbd>; the wheel zooms by default; <kbd>0</kbd> zooms to 100% at the pointer. Every shortcut can be remapped, and if you reversed your wheel with Mos you can flip the zoom direction.</p>
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
      f"""<p>The slow part of an event shoot isn't editing; it's finding the fifty usable frames among hundreds. This workflow runs in Flipic Lens alone, with no catalog import.</p>
<h2>1. Let the app find the obvious rejects</h2>
<p>Open the folder in Flipic Lens and press <kbd>⇧⌘K</kbd> for Cleanup Mode. It checks every photo on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry or out-of-focus shots, suggesting the sharpest blink-free frame of each burst.</p>
<figure>{shot('cleanup-en.webp', 'Flipic Lens Cleanup Mode grouping bursts and suggesting a keeper', 1440, 967)}<figcaption>Faces flagged for closed eyes are outlined; Space zooms in to check.</figcaption></figure>
<p>Nothing is deleted until you press Move to Trash, and <kbd>⌘Z</kbd> undoes it. Detection can be wrong, so look before you delete.</p>
<h2>2. Page through and rate</h2>
<p>Press <kbd>→</kbd> through what's left and <kbd>1</kbd>–<kbd>5</kbd> to rate. Rest the pointer on a face and press <kbd>0</kbd> to check focus at 100%. Or run a slideshow, click to pause on a good one, rate it, click to resume.</p>
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
<ul><li>You just want to double-click a photo and arrow through the folder: Flipic Lens, qView or PicView. Flipic Lens is the closest to IrfanView or Honeyview in feel.</li><li>You mostly cull RAW and need focus and histograms: FastRawViewer.</li><li>You want one big tool that also organizes and converts: XnView MP.</li><li>You like grids: FlowVision.</li></ul>
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
<p>Flipic Lens is the one to try if you cull by stepping through photos. Open a folder, double-click any photo and press <kbd>←</kbd> or <kbd>→</kbd>; the window moves through the folder one image at a time, with a thumbnail strip along the bottom. Press <kbd>0</kbd> to zoom to 100% at the pointer and check focus, <kbd>1</kbd>–<kbd>5</kbd> to rate, and <kbd>P</kbd> to mark keepers. Ratings are written as standard XMP, so Lightroom, Bridge and Capture One can read them. Cleanup Mode groups similar bursts, exact duplicates, closed eyes and blurry shots on your Mac, and nothing is deleted until you choose Move to Trash. Flipic Lens is MIT-licensed, a 5 MB download, needs macOS 13 or later, and runs on Apple silicon and Intel.</p>
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
      f"""<p>Photo Mechanic is a mature, paid professional photo browser from Camera Bits. It is built for high-volume ingest, browsing, culling, metadata and upload workflows, and it does far more than Flipic Lens. If you mainly need to open a folder, page through photos, check focus, rate and mark, Flipic Lens is a free, open-source alternative for that narrower job.</p>
<h2>What Photo Mechanic is built for</h2>
<p>Photo Mechanic is a full workflow tool. Its own tour highlights copying cards and culling while the files are still being ingested, a contact sheet for browsing, keywords and IPTC metadata, batch copy/delete/rename, side-by-side comparison, and export or upload to galleries and services. It also has a Plus version with an image database for cataloging files across drives.</p>
<p>That breadth is the point. If you shoot for clients and need ingest, metadata, captions and delivery in one place, Photo Mechanic is the more complete tool. It is also paid software, with a free trial; check Camera Bits for current licensing.</p>
<h2>What Flipic Lens covers</h2>
<p>Flipic Lens starts from a folder, not a catalog. Copy the card yourself, double-click any photo, and press <kbd>←</kbd> <kbd>→</kbd> to move through the folder. There is no import step and no library to maintain. That is a smaller promise than Photo Mechanic makes, and it is deliberate.</p>
<p>For culling, the useful keys are all there. Press <kbd>0</kbd> to zoom to 100% at the pointer and check focus. Press <kbd>1</kbd> to <kbd>5</kbd> to rate, <kbd>P</kbd> to mark keepers. Press <kbd>C</kbd> for two photos side by side or <kbd>⇧C</kbd> for four, with zoom and pan synced. Cleanup Mode groups similar bursts, exact duplicates, closed eyes and blurry shots on your Mac before you decide what to delete. Viewing, ratings, marks, side-by-side comparison and Cleanup Mode are free.</p>
<figure>{shot('filmstrip.webp', 'Flipic Lens thumbnail strip and arrow-key paging')}<figcaption>Flipic Lens: open one photo, then page through the folder.</figcaption></figure>
<h2>Where the two differ</h2>
<p>Photo Mechanic is stronger when the job includes ingest automation, detailed metadata, keywording and delivery. Flipic Lens is stronger when you want to open a folder quickly and judge one photo at a time without a catalog. Flipic Lens is also Mac-only, MIT-licensed and a 5 MB download; it needs macOS 13 or later.</p>
<p>Photo Mechanic is not the only heavier option, and Flipic Lens is not trying to replace it. If you already use Photo Mechanic for the parts of the workflow that matter to you, keep it. Use Flipic Lens when you just want to look at the pictures and pick.</p>
<h2>Can you use both?</h2>
<p>Yes. You can keep a full workflow app for ingest and metadata, then open the folder in a lighter viewer for a quick pass. Flipic Lens does not import, copy or catalog your files, and opening a folder does not move anything. The only photo data it writes is the rating you set, as standard XMP; marks are stored as Finder tags. Other apps can read the ratings. If you later decide you need the wider workflow, you can go back without a migration.</p>
<p>For the broader field, see <a href="/en/guides/open-source-image-viewers-mac/">open-source image viewers for Mac</a>. For a culling routine that starts with rejects, see <a href="/en/guides/cull-photos-on-mac/">how to cull hundreds of event photos on a Mac</a>. The full comparison is at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Is Flipic Lens a drop-in replacement for Photo Mechanic?',
           'No. Photo Mechanic covers ingest, metadata, keywording and delivery; Flipic Lens is a smaller viewer for paging, focus, ratings, marks and culling. If you need the full workflow, keep Photo Mechanic.'),
          ('Is Flipic Lens free?',
           'Yes, free and open source (MIT). An optional paid Pro adds batch tools; viewing, ratings, marks, side-by-side comparison and Cleanup Mode are free.'),
          ('Does Flipic Lens import or catalog photos?',
           'No. It reads the folder you open and does not build a library or copy the files.'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-07")

guide("en", "/en/guides/view-raw-files-mac/", "How to quickly view RAW files on a Mac",
      "View RAW files on Mac",
      "View a folder of camera RAW files on a Mac with the arrow keys, check focus at 100%, rate with 1–5 and handle same-name RAW+JPG pairs in one place.",
      "Open a folder of RAW files, page with the arrows and check focus",
      f"""<p>Copy the RAW files to a folder on your Mac, open that folder in Flipic Lens, double-click any photo and use <kbd>←</kbd> <kbd>→</kbd> to move through the folder. There is no import step and no catalog. Flipic Lens opens common camera RAW formats including ARW, CR2, CR3, NEF, RAF and DNG.</p>
<h2>Quick Look or a folder viewer</h2>
<p>Quick Look is a quick way to glance at a few files: select them in Finder, press <kbd>Space</kbd>, and use the arrow keys to browse the selection. It is useful when you already know which files you want. The limit is that you are browsing a selection, not the whole folder.</p>
<p>Quick Look is also temporary: close the window and the selection is gone. A folder viewer keeps the folder open, so you can come back to the same place after a break.</p>
<p>A folder viewer fits when you want to start at one photo and keep going. Flipic Lens reads the folder as it is, so the next photo is whatever comes next in the folder, not the next item you happened to select. You can sort by name, date taken, date modified or file size.</p>
<h2>Check focus before you rate</h2>
<p>Point at the eyes or another detail and hold <kbd>0</kbd> to zoom to 100% there. Let go to fit the photo. Press <kbd>I</kbd> for the camera, lens, shutter speed, aperture, ISO and date taken. When two frames look close, press <kbd>C</kbd> to compare two side by side, or <kbd>⇧C</kbd> for four.</p>
<p>If you shoot bursts, comparing two frames saves going back and forth between them and trying to remember the last. The compare view keeps the same zoom and position, which is exactly what you need for eyes and expressions.</p>
<p>Then rate with <kbd>1</kbd> to <kbd>5</kbd> and mark keepers with <kbd>P</kbd>. Ratings are written as standard XMP: into the file for JPEG, HEIC and TIFF, and into a same-name <code>.xmp</code> sidecar for proprietary RAW. The RAW file itself is not changed.</p>
<figure>{shot('zoom.webp', 'Flipic Lens zooming to 100% at the pointer to check focus')}<figcaption>Hold 0 to check focus; let go to fit.</figcaption></figure>
<h2>A simple RAW routine</h2>
<ol><li>Copy the card to a folder. Do not rename anything yet.</li><li>Open the folder in Flipic Lens and page from the first frame, pressing <kbd>0</kbd> on anything that looks soft.</li><li>Rate the keepers with <kbd>1</kbd> to <kbd>5</kbd>, mark the ones you want to edit with <kbd>P</kbd>, then deal with the rejects.</li></ol>
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
      f"""<p>Open the folder in Flipic Lens, find the first frame you want to compare and press <kbd>C</kbd>. That puts two photos side by side. Press <kbd>⇧C</kbd> to compare four at once. Zooming and dragging move every pane together by default, so you are looking at the same spot in each frame.</p>
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
      ], title_suffix=False, updated="2026-11-07", published="2026-11-07")



guide("en", "/en/guides/adobe-bridge-alternative-mac/", "Adobe Bridge vs Flipic Lens: which one for culling?",
      "Bridge vs Flipic Lens",
      "Adobe Bridge is a free asset browser with deep metadata and batch tools. Flipic Lens is a small Mac culler that opens a folder and pages with the arrow keys.",
      "Bridge for metadata and batch work, Flipic Lens for a quick folder cull",
      f"""<p>Choose Adobe Bridge if you want a free asset browser with deep metadata editing, keywords, collections and batch tools inside the Adobe ecosystem. Choose Flipic Lens if you want to open a folder, page through photos with the arrow keys, check focus and rate them without a catalog. You can use both: Bridge for metadata and batch work, Flipic Lens for a quick culling pass.</p>
<table><thead><tr><th></th><th>Adobe Bridge</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Free</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>Folder browser; optional Photo Downloader; no catalog required</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>Opens RAW in Adobe Camera Raw from Bridge</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>Star ratings in XMP metadata</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Grid and preview; synced two-up not listed on its site</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Not listed on its official site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS and Windows</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where Adobe Bridge is stronger</h2>
<ul><li><strong>Metadata and asset management.</strong> Bridge edits metadata, adds keywords, labels and ratings, and finds files with filters, collections and metadata search.</li><li><strong>Adobe Camera Raw.</strong> Bridge opens RAW files in Camera Raw and sits next to Photoshop and the rest of Creative Cloud.</li><li><strong>Batch work.</strong> Batch rename and batch export, plus PDF contact sheets and publishing to Adobe Stock or Portfolio.</li></ul>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>No import step.</strong> Open the folder, double-click a photo and press the arrow keys. There is no catalog to create or maintain.</li><li><strong>Focus and comparison.</strong> Press 0 to zoom to 100% at the pointer; press C for two photos or Shift-C for four, with zoom and pan synced.</li><li><strong>Ratings and marks in the file.</strong> 1 to 5 stars are written as standard XMP, with a same-name .xmp sidecar for proprietary RAW. P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of similar bursts, duplicates, closed eyes and blurry shots. Nothing is deleted until you choose Move to Trash.<br><strong>Small and offline.</strong> A 5 MB MIT-licensed Mac app that is offline by default. Pro is a one-time purchase with a 7-day trial; the Workbench adds a project grid.</p>
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
      f"""<p>Choose FastRawViewer if you need to judge the RAW data itself: a RAW histogram, highlight inspection, exposure checks and focus peaking. Choose Flipic Lens if you want a simpler folder viewer for paging, focus checks, ratings and a first cull. They can sit in the same workflow: FastRawViewer for exposure-critical frames, Flipic Lens for the rest of the selection.</p>
<table><thead><tr><th></th><th>FastRawViewer</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Paid license</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>No catalog; browse folders directly</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>Decodes RAW data; RAW histogram, highlight inspection, focus peaking</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>Ratings and labels in XMP sidecars</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Grid and single-file view; synced two-up not listed on its site</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Not listed on its official site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS and Windows</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where FastRawViewer is stronger</h2>
<ul><li><strong>RAW data, not an embedded preview.</strong> It renders the RAW and shows a RAW histogram, RAW statistics and highlight inspection.</li><li><strong>Exposure and focus tools.</strong> Shadow Boost, per-channel view, focus peaking and exposure compensation help you see what a converter can recover.</li><li><strong>RAW+JPEG mode.</strong> It handles RAW and JPEG pairs and can work through folders without creating a catalog.</li></ul>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>Simple paging.</strong> Double-click one photo and use the arrow keys through the folder, with no import and no catalog.</li><li><strong>Fast focus checks and comparison.</strong> Press 0 to zoom to 100% at the pointer; C and Shift-C compare two or four frames with synced zoom and pan.</li><li><strong>Ratings and marks.</strong> 1 to 5 stars go into standard XMP, with a same-name .xmp sidecar for proprietary RAW. P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of bursts, duplicates, closed eyes and blur, with you deciding what to delete.<br><strong>Small and offline.</strong> A 5 MB MIT-licensed Mac app, offline by default; Pro adds the Workbench grid and is a one-time purchase with a 7-day trial.</p>
<h2>Using them together</h2>
<p>Open a shoot in FastRawViewer when you need the RAW histogram or a careful exposure check. Use Flipic Lens for the broader pass: page, rate, mark and let Cleanup Mode group the obvious rejects. Both can write ratings to XMP, so pick one app for the rating pass to keep the sidecars predictable.</p>
<p>See the full comparison at <a href="/en/compare/">Mac photo viewers and culling tools compared</a>.</p>""",
      faq=[
          ('Is FastRawViewer free?',
           'No. It is a paid license with a fully functional 30-day trial; check LibRaw for current licensing.'),
          ('Does FastRawViewer show the embedded JPEG?',
           'No. Its main point is rendering the RAW data itself, with a RAW histogram and RAW-based exposure tools.'),
          ('Can I use FastRawViewer and Flipic Lens together?',
           'Yes. Use FastRawViewer for RAW-data exposure checks and Flipic Lens for paging, ratings, marks and Cleanup Mode.'),
          ('Do both write XMP ratings?',
           'Yes. FastRawViewer writes ratings and labels to XMP sidecars; Flipic Lens writes standard XMP ratings, with a sidecar for proprietary RAW.'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("en", "/en/guides/xnview-mp-alternative-mac/", "XnView MP vs Flipic Lens: which viewer fits?",
      "XnView MP vs Flipic Lens",
      "XnView MP brings a long format list, batch tools and an optional catalog on Mac, Windows and Linux. Flipic Lens is a Mac culler for folders and XMP ratings.",
      "XnView MP for formats and batch, Flipic Lens for a quick cull",
      f"""<p>Choose XnView MP if you need a cross-platform viewer and organizer with a very long format list, batch conversion, rename tools and an optional catalog. Choose Flipic Lens if you mainly want to open a folder, page with the arrow keys, check focus and rate a shoot without a catalog. You can keep XnView MP for conversion and organizing, and use Flipic Lens for the first cull.</p>
<table><thead><tr><th></th><th>XnView MP</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Free for private, educational, public and non-profit use; paid license for commercial use</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>Folder browser; optional catalog</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>Views camera RAW; not a RAW development module</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>XMP sidecars, ratings exchanged with Lightroom and Bridge</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Image Compare up to 4 images</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Not listed on its official site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS, Windows and Linux</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where XnView MP is stronger</h2>
<ul><li><strong>Format breadth.</strong> It opens a long list of image and camera RAW formats, plus PDF, DICOM and more.</li><li><strong>Batch tools.</strong> Batch convert, batch rename and a batch processing module shared with XnConvert.</li><li><strong>Cross-platform and catalog.</strong> macOS, Windows and Linux, with an optional SQLite catalog for searching ratings, labels, keywords and metadata.</li></ul>
<p><strong>Image Compare.</strong> Compare up to four images in one view.</p>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>No catalog to manage.</strong> Open the folder and start paging; no import and no library.</li><li><strong>Focus and comparison.</strong> 0 zooms to 100% at the pointer; C and Shift-C compare two or four photos with synced zoom and pan.</li><li><strong>Ratings in standard XMP.</strong> 1 to 5 stars, with a same-name .xmp sidecar for proprietary RAW; P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of similar bursts, duplicates, closed eyes and blur, with you deciding what goes.<br><strong>Small, free and offline.</strong> A 5 MB MIT-licensed Mac app. Pro is a one-time purchase with a 7-day trial and adds the Workbench grid.</p>
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
      f"""<p>Choose ApolloOne if you want a Mac-native viewer with full metadata editing, IPTC keywords, split-view comparison, stacks, HDR and quick edits, all without importing. Choose Flipic Lens if you want a smaller, free, open-source app focused on paging, focus checks, ratings and Cleanup Mode. You can use ApolloOne for metadata and edits, and Flipic Lens for the first cull.</p>
<table><thead><tr><th></th><th>ApolloOne</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>Price model</td><td>Free edition; paid Max Edition with subscription or perpetual license</td><td>Free; optional one-time Pro</td></tr><tr><td>Import or library</td><td>No import; reads folders</td><td>No import, no catalog; reads the folder</td></tr><tr><td>RAW</td><td>RawBridge engine; RAW, HEIF, TIFF and more</td><td>Opens camera RAW; 0 zooms to 100% at the pointer</td></tr><tr><td>Star ratings</td><td>Star ratings, color labels and Finder tags written as XMP</td><td>1 to 5 stars as standard XMP; RAW uses a same-name .xmp sidecar</td></tr><tr><td>Side-by-side compare</td><td>Split-view comparison</td><td>C for two, Shift-C for four, zoom synced</td></tr><tr><td>Closed eyes / blur / bursts</td><td>Auto-Stack and Focus Score; closed-eye detection not listed on its site</td><td>Yes: Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac</td></tr><tr><td>Platform</td><td>macOS</td><td>macOS 13 or later</td></tr><tr><td>Open source</td><td>No</td><td>Yes, MIT</td></tr></tbody></table>
<h2>Where ApolloOne is stronger</h2>
<ul><li><strong>Metadata and keywords.</strong> Full EXIF and IPTC editing, hierarchical keywords and code replacements written as XMP.</li><li><strong>More viewing tools.</strong> Tabs and windows, split-view comparison, HDR display and export, video playback and non-destructive Quick Edit.</li><li><strong>Burst organization.</strong> Stacks and Auto-Stack collapse a burst into one thumbnail, while Focus Score helps compare sharpness.</li></ul>
<p><strong>Batch work.</strong> Batch rename and conversion are built in.</p>
<h2>Where Flipic Lens fits</h2>
<ul><li><strong>Simple and open source.</strong> A 5 MB MIT-licensed Mac app with no import and no catalog.</li><li><strong>Culling without setup.</strong> Double-click a photo, arrow through the folder, press 0 to check focus, C or Shift-C to compare, 1 to 5 to rate and P to mark.</li><li><strong>Ratings and marks in standard places.</strong> Stars are standard XMP with a same-name .xmp sidecar for proprietary RAW; P marks are Finder tags.</li></ul>
<p><strong>Cleanup Mode.</strong> Free on-device grouping of bursts, duplicates, closed eyes and blur, with you deciding what to delete.<br><strong>Pro when needed.</strong> The Workbench adds a project grid, zoom to the eyes, content and text search, and more, as a one-time purchase with a 7-day trial.</p>
<h2>Using them together</h2>
<p>Use ApolloOne when you need IPTC, keywords, HDR or a quick non-destructive edit. Use Flipic Lens when the job is to open a folder and make a first selection. Both write ratings as XMP, so decide which app owns the rating pass if keeping sidecars tidy matters to you.</p>
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
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

guide("en", "/en/guides/cull-before-lightroom/", "Cull before Lightroom: why add another app?",
      "Cull before Lightroom",
      "Already use Lightroom Classic? A first cull in Flipic Lens avoids importing rejects, keeps ratings in XMP and sends only the keepers into the catalog.",
      "Skip the import of rejects; rate first, import keepers",
      f"""<p>If you already use Lightroom Classic, you can import everything and cull there. But import builds a catalog record for every photo, including the ones you will reject. Culling first in Flipic Lens lets you open the folder, rate and mark, then import only the keepers. Lightroom Classic also has Assisted Culling, which sorts photos by eye and subject sharpness, open eyes and exposure; it is a good option if you are happy to cull inside the catalog. Use Flipic Lens for the first pass when you would rather not catalog the rejects, and Lightroom Classic for editing and the catalog.</p>
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
<p><strong>清理模式。</strong> 免费，在本机分相似连拍、重复、闭眼和模糊；你按「移到废纸篓」之前不会删。<br><strong>小、免费、默认不联网。</strong> 约 5 MB，MIT 开源。Pro 一次买断，下载后可以先试用 7 天，工作台多一个项目宫格。</p>
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
<p><strong>清理模式。</strong> 免费，在本机分连拍、重复、闭眼和模糊，删哪些还是你决定。<br><strong>小、免费、默认不联网。</strong> 约 5 MB，MIT 开源。Pro 一次买断，带 7 天试用，工作台有项目宫格。</p>
<h2>一起用</h2>
<p>要拷卡、写 IPTC、批量改关键词、直接交付，用 Photo Mechanic。照片已经在硬盘上、只想先挑一遍，就用 Flipic Lens。两边的星级都走 XMP，但建议固定一个软件负责打星，免得 sidecar 被两边反复改。</p>
<p>完整对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""",
      faq=[
          ('Photo Mechanic 有免费版吗？',
           '没有免费版，提供试用；授权可以订阅，也可以买永久授权，具体看 Camera Bits 官网。'),
          ('Photo Mechanic 能做的，Flipic Lens 都能做吗？',
           '不能。拷卡、IPTC、关键词、Code Replacements 和交付是 Photo Mechanic 的强项；Flipic Lens 只做打开文件夹、翻页、看焦点、打星、标记和清理这一小段。'),
          ('两个都用会不会重复打星？',
           '可以只用一边打星。两边的评分都写 XMP，但固定一个软件负责评分，sidecar 更可控。'),
          ('只挑 RAW 用哪个？',
           '要拷卡和 IPTC 用 Photo Mechanic；只想打开文件夹先看一遍，用 Flipic Lens。'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

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
<p><strong>清理模式。</strong> 免费，在本机分连拍、重复、闭眼、模糊，删哪些由你决定。<br><strong>小、免费、默认不联网。</strong> 约 5 MB，MIT 开源。Pro 一次买断，带 7 天试用和工作台宫格。</p>
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
      f"""<p>FastRawViewer 适合要看 RAW 本身的数据：RAW 直方图、过曝和欠曝、峰值对焦、曝光补偿，再决定这张能不能救。Flipic Lens 适合打开文件夹，用方向键翻、看焦点、打星、做第一轮挑片。两个可以一起用：FastRawViewer 看曝光，Flipic Lens 做选择。</p>
<table><thead><tr><th></th><th>FastRawViewer</th><th>Flipic Lens</th></tr></thead><tbody><tr><td>价格模式</td><td>付费授权</td><td>免费；可选一次买断的 Pro</td></tr><tr><td>要不要导入或建库</td><td>不建图库；直接浏览文件夹</td><td>不导入、不建库，直接读文件夹</td></tr><tr><td>看 RAW</td><td>直接解 RAW，RAW 直方图、过曝检查、峰值对焦</td><td>直接打开相机 RAW；按 0 看 100% 焦点</td></tr><tr><td>星级存在哪</td><td>星级和标签写 XMP sidecar</td><td>1 到 5 星写标准 XMP；RAW 写同名 .xmp</td></tr><tr><td>并排比较</td><td>网格和单张；官网未列出同步对比</td><td>C 两张、⇧C 四张，缩放同步</td></tr><tr><td>闭眼 / 模糊 / 连拍</td><td>官网未列出</td><td>有：清理模式在本机分连拍、重复、闭眼、模糊</td></tr><tr><td>平台</td><td>macOS 和 Windows</td><td>macOS 13 或更新</td></tr><tr><td>开源</td><td>否</td><td>是，MIT</td></tr></tbody></table>
<h2>FastRawViewer 更强的地方</h2>
<ul><li><strong>看的是 RAW 数据。</strong> 不是内嵌 JPEG，给的是 RAW 直方图、RAW 统计和过曝检查。</li><li><strong>曝光和焦点工具。</strong> Shadow Boost、分通道查看、峰值对焦、曝光补偿，帮你看后期还能拉回多少。</li><li><strong>RAW+JPEG 模式。</strong> 同时处理 RAW 和 JPEG，按文件夹浏览，不建图库。</li></ul>
<h2>Flipic Lens 更适合的地方</h2>
<ul><li><strong>打开就翻。</strong> 双击一张，方向键翻整个文件夹，不导入，不建库。</li><li><strong>看焦点和比较。</strong> 0 在鼠标处放大到 100%；C 两张、⇧C 四张，缩放同步。</li><li><strong>星级和标记。</strong> 1 到 5 星写标准 XMP，专有 RAW 写同名 .xmp；P 标记是访达标签。</li></ul>
<p><strong>清理模式。</strong> 免费，在本机分连拍、重复、闭眼和模糊，删哪些由你决定。<br><strong>小、免费、默认不联网。</strong> 约 5 MB，MIT 开源。Pro 一次买断，带 7 天试用和工作台宫格。</p>
<h2>一起用</h2>
<p>要判断曝光、看 RAW 直方图、峰值对焦，用 FastRawViewer。要快速翻一遍、打星、标记、清理，用 Flipic Lens。两边都能写 XMP 星级，但固定一个软件负责评分，sidecar 更可控。</p>
<p>完整对比见 <a href="/compare/">Mac 看图与挑片软件对比</a>。</p>""",
      faq=[
          ('FastRawViewer 免费吗？',
           '不是免费软件，是付费授权，提供完整功能的试用；具体授权方式看 LibRaw 官网。'),
          ('FastRawViewer 看的是内嵌 JPEG 吗？',
           '不是。它的重点是直接解 RAW，给 RAW 直方图和基于 RAW 数据的曝光工具。'),
          ('FastRawViewer 和 Flipic Lens 能一起用吗？',
           '能。FastRawViewer 看曝光和 RAW 数据，Flipic Lens 翻页、打星、标记和清理。'),
          ('只挑片需要 FastRawViewer 吗？',
           '不一定。要看 RAW 直方图和过曝，才需要它；只想翻一遍、看焦点、打星，Flipic Lens 就够。'),
      ], title_suffix=False, updated="2026-11-08", published="2026-11-08")

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
<p>Flipic Lens reads the folder you open, double-click any photo and page with the arrow keys. Press 0 to zoom to 100% at the pointer, C or Shift-C to compare two or four frames with synced zoom, 1 to 5 to rate and P to mark. Ratings are standard XMP, with a same-name .xmp sidecar for proprietary RAW; marks are Finder tags. Cleanup Mode groups bursts, duplicates, closed eyes and blur on your Mac. The app is about 5 MB, MIT-licensed and offline by default. Pro is a one-time purchase with a 7-day trial and adds the Workbench grid, zoom to the eyes, and content and text search.</p>
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
<p>Flipic Lens 直接读你打开的文件夹，双击一张就用方向键翻。按 0 在鼠标处放大到 100%，按 C 两张、⇧C 四张，缩放同步；1 到 5 打星，P 标记。星级写标准 XMP，专有 RAW 写同名 .xmp；标记是访达标签。清理模式在本机分连拍、重复、闭眼和模糊。安装包约 5 MB，MIT 开源，默认不联网。Pro 一次买断，带 7 天试用，多出工作台宫格、放大到眼睛、按内容和文字搜索。</p>
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
              {"@context": "https://schema.org", "@type": "WebSite", "name": "Flipic Lens", "url": f"{BASE}{path}", "inLanguage": t["lang"]}]
    out = head(lang, path, h["title"], h["desc"], schema) + header(lang, path)
    first = f'<img class="on" src="{SHOTS}browse-01.webp" alt="{esc(h["deck_alt"].format(n=1))}" width="1440" height="900" fetchpriority="high">'
    out += f"""<main id="main">
<section class="wrap hero">
  <p class="eyebrow rise">{h['eyebrow']}</p>
  <h1 class="rise">{h['h1']}</h1>
  <p class="lede rise">{h['lede']}</p>
  <div class="rise">{download_block(lang, brew=True)}</div>
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
        "hero_alt": "Flipic Lens 工作台：左边是拍摄项目列表，中间是一场婚礼的宫格，右边是大图和直方图",
        "honest_title": "先说一句：大多数人用免费版就够了",
        "honest": [
            "看图、RAW 秒开、打星、标记、按星级筛选、导出到文件夹、并排对比、清理相似和模糊的照片，这些都是免费的，代码也开源，以后不会改成要付费。",
            "Pro 是给经常一次处理几百上千张照片的人准备的。平时只是看看照片、偶尔挑几张的话，用不到它，不用买。卖 Pro 的收入用来继续维护 Flipic Lens，免费版也会一直更新。",
        ],
        "skip_title": "这些情况用不到 Pro",
        "skip": ["只是想双击图片，用方向键看完一个文件夹", "偶尔给照片打星、标记几张，再导出到一个文件夹", "清理手机里导出来的重复、模糊照片"],
        "workbench": {
            "h": "工作台",
            "body": [
                "另开一个窗口管一场一场的拍摄。左边每个拍摄文件夹是一个项目，可以置顶、分组、标颜色，状态分待挑、挑片中、已交付；中间宫格打星、标记、删除；右边是大图、拍摄参数和直方图。",
                "上面一排按星级、标记、闭眼、模糊、连拍筛选。点「闭眼」，闭着眼的照片就单独列出来，框出是哪张脸。还有单张和两张对比视图。菜单「窗口 › 工作台」，快捷键 <kbd>⌥⌘B</kbd>。",
            ],
            "img": "pro-closed-eyes.webp",
            "alt": "工作台按「闭眼」筛选，只剩 4 张，每张闭眼的脸上有橙色框",
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
        "small_title": "还有这些",
        "small": [
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
        "free_rows": [("看图、RAW 秒开、HDR、幻灯片", "有", "有"), ("评星、标记、按星级筛选", "有", "有"),
                      ("导出到文件夹、并排对比、清理模式", "有", "有"), ("批量转格式、批量重命名", "有", "有"),
                      ("工作台", "", "有"), ("放大到眼睛", "", "有"), ("按内容、按照片里的字找照片", "", "有"), ("修图前后对比", "", "有"), ("JPG 和 RAW 合并显示", "", "有"), ("按星级分到子文件夹", "", "有"),
                      ("常用文件夹 ⌥1–⌥9", "", "有"), ("删除没挑中的照片", "", "有"), ("批量送进后期软件", "", "有"),
                      ("自定义同名关联", "", "有")],
        "faq": [
            ("激活码怎么用？", "付款成功的页面上有激活码和「在 Flipic Lens 中激活」按钮，点一下就激活了。也可以复制激活码，粘贴到 Flipic Lens「设置 › Pro」里。"),
            ("要联网验证吗？", "第一次激活需要联网，把激活码绑定到这台 Mac，只发订单号和设备号的哈希。之后离线也能用，每隔一段时间联网核对一次；长时间（60 天）没联上网，联网一次就恢复。"),
            ("能装在几台 Mac 上？", "一个激活码只限购买者本人使用，最多激活你自己的 2 台 Mac。换电脑时，先在旧 Mac 的「设置 › Pro」里停用，空出名额；旧 Mac 坏了没法操作的，在 App 里「关于 › 反馈建议」告诉我们解绑。"),
            ("激活码丢了怎么办？", "在 <a href=\"https://pay.flipic.app/recover?lang=zh\">找回激活码</a> 页面输入付款邮箱和卡号后四位就能找回。"),
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
        "hero_alt": "Flipic Lens Workbench: shoot projects on the left, a wedding shoot in the grid, a large preview with a histogram on the right",
        "honest_title": "First, most people will be fine with the free version",
        "honest": [
            "Viewing, quick RAW previews, ratings, marks, filtering by rating, export to a folder, side-by-side comparison and cleaning up similar or blurry photos are all free, the code is open source, and none of it will become paid.",
            "Pro is for people who often go through hundreds or thousands of photos at a time. If you mostly look at photos and pick a few now and then, you won’t use it, so there’s no need to buy it. Pro sales pay for keeping Flipic Lens going, and the free version keeps getting updates too.",
        ],
        "skip_title": "You won’t need Pro if you",
        "skip": ["just want to double-click a photo and page through the folder", "rate or mark a few photos now and then and export them to a folder", "clean up duplicate or blurry photos from your phone"],
        "workbench": {
            "h": "Workbench",
            "body": [
                "A separate window for managing your shoots. On the left, each shoot folder is a project you can pin, group and color-label, with a status: To cull, Culling, Delivered. In the middle, a grid for rating, marking and deleting. On the right, a large preview with shooting details and a histogram.",
                "The row on top filters by rating, marks, closed eyes, blur or bursts. Click Blinks and only the photos with closed eyes are left, with the face outlined. Single and two-up compare views too. Window › Workbench, or <kbd>⌥⌘B</kbd>.",
            ],
            "img": "pro-closed-eyes-en.webp",
            "alt": "Workbench filtered to Blinks: four photos left, each closed-eye face outlined in orange",
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
        "small_title": "And also",
        "small": [
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
        "free_rows": [("Viewing, instant RAW, HDR, slideshow", "Yes", "Yes"), ("Ratings, marks, filter by rating", "Yes", "Yes"),
                      ("Export to folder, side-by-side, Cleanup Mode", "Yes", "Yes"), ("Batch convert, batch rename", "Yes", "Yes"),
                      ("Workbench", "", "Yes"), ("Zoom to the eyes", "", "Yes"), ("Find photos by content or text", "", "Yes"), ("Before & after", "", "Yes"), ("Merge JPG and RAW", "", "Yes"), ("Sort into folders by rating", "", "Yes"),
                      ("Favorite folders ⌥1–⌥9", "", "Yes"), ("Delete what you didn’t pick", "", "Yes"), ("Send a batch to your editor", "", "Yes"),
                      ("Custom linked files", "", "Yes")],
        "faq": [
            ("How do I activate?", "The payment confirmation page shows your key and an Activate in Flipic Lens button. Or copy the key and paste it into Flipic Lens › Settings › Pro."),
            ("Does it need to go online?", "The first activation goes online to bind the key to this Mac, sending only hashes of the order number and device ID. After that it works offline and checks in now and then; if it has been offline for a long time (60 days), going online once restores it."),
            ("How many Macs?", "A key is for the buyer’s own use and can be activated on up to 2 of your own Macs. When you switch Macs, deactivate it on the old one in Settings › Pro to free the slot. If the old Mac is broken, let us know via About › Send Feedback in the app and we’ll release it."),
            ("I lost my key", "Use <a href=\"https://pay.flipic.app/recover?lang=en\">Recover Key</a> with your payment email and the last four digits of your card."),
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
    wb, ey, se, tx, ba = p["workbench"], p["eyes"], p["search"], p["text"], p["ba"]
    hero_img = "pro-workbench.webp" if lang == "zh" else "pro-workbench-en.webp"
    skip = "".join(f"<li>{esc(x)}</li>" for x in p["skip"])
    pair = "".join(f"<figure>{pro_shot(img, alt)}<figcaption>{esc(cap)}</figcaption></figure>" for img, alt, cap in ey["shots"])
    small = "".join(f"<li><h3>{esc(h)}</h3><p>{esc(b)}</p></li>" for h, b in p["small"])
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
        both = f"Flipic Lens 和 {store}" if store else "Flipic Lens"
        store_full = f"{store}（同一款软件在 Mac App Store 上的版本）" if store else "Flipic Lens 的 Mac App Store 版"
        store_short = f" {store} " if store else "Mac App Store 版"
    else:
        both = f"Flipic Lens and {store}" if store else "Flipic Lens"
        store_full = f"{store} (the same app on the Mac App Store)" if store else "the Mac App Store version of Flipic Lens"
        store_short = store or "The Mac App Store version"
    mail = esc(LEGAL["email"])
    m = f'<a href="mailto:{mail}">{mail}</a>'
    days = LEGAL["refund_days"]
    eff = LEGAL["effective"]
    if lang == "zh":
        privacy = ("/privacy/", "隐私政策", f"{both} 的隐私政策：照片只在你的 Mac 上处理，不收集个人信息；购买 Pro 时付款信息由 Stripe 或 Apple 处理。", f"""
<p class="lede">生效日期：{eff}</p>
<div class="prose">
<p>这份政策适用于 Flipic Lens（从 flipic.app 和 GitHub 下载的版本）、{store_full}、flipic.app 网站和 pay.flipic.app 付款服务。运营者是{op}。</p>
<h2>软件本身</h2>
<p>照片只在你的 Mac 上读取和显示，不会上传到任何地方。软件不需要账号，没有广告、统计和崩溃上报，也不收集设备信息。</p>
<p>你给照片打的星级写进照片的 XMP 信息，相机 RAW 写在同名的 .xmp 文件里；挑片标记是访达标签；设置保存在这台 Mac 上。这些都留在你自己的电脑上。</p>
<p>Flipic Lens 默认不联网。只有你打开「自动检查更新」或点「检查更新」时，才会向 flipic.app 请求一个只写着最新版本号的文件，请求里除了软件版本号没有别的信息，也不保存 cookie。服务器只累加这个文件和官网安装包被请求了多少次（按日期、国家和版本号），不保存 IP 地址。你点「立即更新」时，安装包从 GitHub 下载。</p>
<p>另外几种情况会联网，都由你主动触发：在设置里下载「更准的中文识别」模型时，从 GitHub 下载；在「关于 Flipic Lens」里发送反馈时，发送你写的内容、你留的邮箱（可以不填）和 App、系统版本，存在 pay.flipic.app 的反馈记录里，用来回复你和改进软件，不含照片和文件；为了防止刷屏，同时保存一个加盐处理过的 IP 哈希，不保存 IP 本身。</p>
<p>{store_short}付费下载即是完整版，没有 App 内购买；它不检查更新，更新和付款都由 App Store 负责，App 本身不联网。</p>
<h2>购买 Pro</h2>
<p>在官网购买时，付款由 Stripe 处理，银行卡等支付信息由 Stripe 收集，我们看不到完整卡号。付款完成后，pay.flipic.app 从 Stripe 读取这笔订单的邮箱和订单号，生成激活码。激活码里包含邮箱和订单号，在你的 Mac 上离线验证。订单记录保存在我们的 Stripe 账户里，用来帮你找回激活码、处理退款和记账。激活时，Flipic Lens 把激活码发给 pay.flipic.app 验证，服务器只记下订单号的哈希和这台 Mac 设备号的哈希（不存邮箱和电脑名），用来把激活码限制在 2 台 Mac 上，之后每隔一段时间核对一次；IP 地址只用来限制请求频率，不保存。付款成功页会把这笔订单的金额和 Stripe 订单编号报给 Google Analytics，用来统计购买次数，不含邮箱。Stripe 如何处理信息见 <a href="{STRIPE_PRIVACY}">Stripe 隐私政策</a>。</p>
<p>找回激活码时，你填写的邮箱和卡号后四位（或收据号）只用来在 Stripe 里查找订单，不会保存。为了防止有人反复试探，找回页面按 IP 地址限制每分钟的请求次数，IP 地址不保存。</p>
<p>在 App Store 购买时，付款和账户都由 Apple 处理，我们收不到你的姓名、邮箱或支付信息。见 <a href="{APPLE_PRIVACY}">Apple 隐私政策</a>。</p>
<h2>网站</h2>
<p>flipic.app 托管在 Cloudflare 上。Cloudflare 为了安全和正常运行会记录访问日志（比如 IP 地址和浏览器类型）。</p>
<p>网站用 Google Analytics 4 统计访问量，以及点了下载、购买、GitHub 这些按钮的次数，用来了解大家从哪里来、哪些内容有用。Google Analytics 会在浏览器里存 cookie，记录页面、来源、大致地区和设备类型，不记录完整 IP，也不知道你是谁；我们关闭了广告和个性化相关的功能。来自欧洲经济区、英国和瑞士的访问不写统计 cookie。网站没有广告和第三方字体。Google 如何处理这些数据见 <a href="https://policies.google.com/privacy">Google 隐私政策</a>。软件本身不包含任何统计。</p>
<h2>查询和删除</h2>
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
<p>Pro 是一次性购买，不是订阅。买过以后，之后发布的更新里的 Pro 功能都可以用。Pro 只供购买者本人使用，一个激活码最多激活购买者自己的 2 台 Mac，激活时绑定设备，超过 2 台无法激活。</p>
<p>官网购买得到的激活码请不要公开分享。被公开传播的激活码，以及已经退款或拒付的订单对应的激活码，会被作废。</p>
<h2>退款</h2>
<p>在官网购买 Pro 后 {days} 天内，发邮件到 {m} 并附上付款邮箱，我们会全额退款，不需要说明理由。退款后对应的激活码作废。</p>
<p>在 App Store 购买的，退款按 Apple 的规定办理，请到 <a href="{APPLE_REFUND}">reportaproblem.apple.com</a> 申请。</p>
<h2>App Store 版</h2>
<p>从 Mac App Store 获得的{store_short}付费下载即包含 Pro 的全部功能，同时适用 <a href="{APPLE_EULA}">Apple 标准最终用户许可协议</a>。两者不一致的地方，以 Apple 的协议为准。</p>
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
<p>Your photos are read and shown only on your Mac and are never uploaded. The app has no account, no ads, no analytics and no crash reporting, and it doesn’t collect device information.</p>
<p>Star ratings are written into each photo’s XMP data, or into a matching .xmp file for camera RAW; marks are Finder tags; settings are stored on your Mac. All of this stays on your computer.</p>
<p>Flipic Lens is offline by default. Only when you turn on automatic update checks or click Check for Updates does it request a small file from flipic.app that contains the latest version number. The request carries nothing but the app’s version number and stores no cookies. The server only adds up how many times this file and the installer on the website are requested (by date, country and version number) and does not keep IP addresses. When you click Update Now, the installer is downloaded from GitHub.</p>
<p>A few other things connect, and only when you trigger them: downloading the more accurate recognition model in Settings fetches it from GitHub; sending feedback from About Flipic Lens sends what you wrote, the email you leave (optional) and the app and macOS versions, stored in pay.flipic.app’s feedback records so we can reply and improve the app. No photos or files are sent. To stop spam we also keep a salted hash of the IP address, not the address itself.</p>
<p>{store_short} is a paid download that includes everything, with no in-app purchases. It doesn’t check for updates; the App Store handles updates and payment, and the app itself doesn’t go online.</p>
<h2>Buying Pro</h2>
<p>On flipic.app, payment is handled by Stripe. Stripe collects your card details; we never see the full card number. After you pay, pay.flipic.app reads the order’s email address and order ID from Stripe and generates your license key. The key contains the email and order ID and is checked offline on your Mac. Order records stay in our Stripe account and are used to recover keys, handle refunds and keep accounts. On activation, Flipic Lens sends the key to pay.flipic.app for verification; the server stores only a hash of the order ID and a hash of this Mac’s device ID (no email or computer name), to limit each key to 2 Macs, and the app checks in again from time to time; the IP address is used only for rate limiting and is not stored. The payment confirmation page reports the order amount and Stripe order ID to Google Analytics to count purchases, without your email. See the <a href="{STRIPE_PRIVACY}">Stripe Privacy Policy</a>.</p>
<p>When you recover a key, the email and last four card digits (or receipt number) you enter are used only to look up the order in Stripe and are not stored. To stop repeated guessing, the recovery page limits requests per minute by IP address; the address is not stored.</p>
<p>On the App Store, Apple handles the payment and your account. We don’t receive your name, email or payment details. See the <a href="{APPLE_PRIVACY}">Apple Privacy Policy</a>.</p>
<h2>The website</h2>
<p>flipic.app is hosted on Cloudflare. Cloudflare keeps access logs (such as IP address and browser type) for security and operation.</p>
<p>The website uses Google Analytics 4 to count visits and clicks on buttons such as download, buy and GitHub, so we can see where visitors come from and which pages help. Google Analytics stores cookies in your browser and records pages, referrers, approximate region and device type; it doesn’t record your full IP address or who you are, and we keep its advertising and personalization features off. Visits from the European Economic Area, the UK and Switzerland don’t get analytics cookies. The site has no ads and no third-party fonts. See the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>. The app itself contains no analytics.</p>
<h2>Questions and deletion</h2>
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
<p>Pro is a one-time purchase, not a subscription. Once bought, the Pro features in later updates are included. Pro is for the buyer’s own use only: one key can be activated on up to 2 of the buyer’s own Macs. Activation binds the key to the Mac, and a third Mac can’t be activated.</p>
<p>Please don’t share a license key from flipic.app publicly. Keys that are shared publicly, and keys for orders that were refunded or disputed, are revoked.</p>
<h2>Refunds</h2>
<p>Within {days} days of buying Pro on flipic.app, email {m} with the address you paid with and we’ll refund you in full, no reason needed. The key is revoked after the refund.</p>
<p>For App Store purchases, refunds follow Apple’s rules; request one at <a href="{APPLE_REFUND}">reportaproblem.apple.com</a>.</p>
<h2>App Store version</h2>
<p>{store_short} obtained from the Mac App Store includes all Pro features with the purchase and is also subject to the <a href="{APPLE_EULA}">Apple Standard EULA</a>. Where the two differ, Apple’s agreement applies.</p>
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

    guide_lines = "\n".join(f"- [{g['title']}]({BASE}{g['path']}): {g['desc']}" for lang in ("en", "zh") for g in GUIDES[lang])
    (OUT / "llms.txt").write_text(f"""# Flipic Lens

> Flipic Lens is a free, open-source (MIT) image viewer for macOS 13+. Double-click any photo and page through the whole folder with the arrow keys. {SIZE} download, notarized by Apple, offline by default, no account.

Key facts:
- Paging: ← → through every image in the folder; Space wraps the window to the photo; 0 zooms to 100% at the pointer.
- Star ratings 1–5 written as XMP (embedded for JPEG/HEIC/TIFF, .xmp sidecar for proprietary RAW), readable by Lightroom, Bridge and Capture One.
- Cleanup Mode: finds similar bursts, exact duplicates, closed eyes and blurry photos on-device.
- Batch convert HEIC/JPEG/PNG, batch rename, lossless rotate, slideshow with adjustable crossfade and click-to-pause.
- Optional HDR display, customizable shortcuts, global show/hide shortcut, ⌘E hand-off to Photoshop/Lightroom/Capture One.
- Formats: JPEG, PNG, HEIC, WebP, GIF, TIFF, AVIF, JPEG XL, camera RAW (Sony, Canon, Nikon, Fujifilm, more).
- Download: {BASE}/download/Flipic.dmg · Source: {GITHUB} · Current version: {VERSION}

## How Flipic Lens compares
- [Adobe Bridge]({BASE}/en/guides/adobe-bridge-alternative-mac/): choose Bridge for metadata, keywords, Camera Raw and Adobe batch work; choose Flipic Lens for a catalog-free folder cull.
- [Photo Mechanic]({BASE}/en/guides/photo-mechanic-alternative-mac/): choose Photo Mechanic for ingest, IPTC, keywording and delivery; choose Flipic Lens for a simple paging and rating pass.
- [FastRawViewer]({BASE}/en/guides/fastrawviewer-alternative-mac/): choose FastRawViewer for RAW histograms, exposure checks and focus peaking; choose Flipic Lens for paging, ratings and Cleanup Mode.
- [XnView MP]({BASE}/en/guides/xnview-mp-alternative-mac/): choose XnView MP for format breadth, batch tools and cross-platform work; choose Flipic Lens for a quick Mac cull.
- [ApolloOne]({BASE}/en/guides/apolloone-alternative/): choose ApolloOne for Mac-native metadata, HDR, stacks and quick edits; choose Flipic Lens for a free, catalog-free first cull.
- [FlowVision]({BASE}/en/guides/flowvision-alternative/): choose FlowVision for waterfall or grid browsing with video; choose Flipic Lens for arrow-key culling with ratings and marks.
- [Lightroom Classic]({BASE}/en/guides/cull-before-lightroom/): choose Lightroom Classic for editing and a catalog; choose Flipic Lens to cull before import.
- [Preview]({BASE}/en/guides/mac-preview-next-image/): choose Preview for a quick look at a file; choose Flipic Lens to page and rate a whole folder.
- [Photos](https://support.apple.com/guide/photos/welcome/mac): choose Photos for a personal Apple photo library; choose Flipic Lens for a folder-based first cull.
- [All comparisons]({BASE}/en/compare/): one table of Mac viewers, cullers and catalog tools.

## Pages
- [Flipic Lens (English)]({BASE}/en/)
- [Flipic Lens（中文）]({BASE}/)
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
