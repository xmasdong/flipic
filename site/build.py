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
SIZE = "4.1 MB"
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
}

# Pro 购买：Stripe 付款链接和价格。没填时页面显示「即将开放购买」
PRO_BUY_URL = "https://buy.stripe.com/9B66oI6Rg3uocmU2BAcbC02"
PRO_PRICE = {"zh": "¥68", "en": "$12.99"}
# 隐私政策和用户协议里要写明的三项，由用户填写；有一项没填，这两页就不生成，页脚也不放链接
LEGAL = {
    "operator": {"zh": "Flipic 团队", "en": "Flipic Team"},   # 运营主体
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
        "facts": ["免费开源", "安装包 " + SIZE, "macOS 13 或更新", "Apple 芯片与 Intel 通用", "已通过 Apple 公证", "默认不联网"],
        "phone": "Flipic 是 Mac 软件，手机上装不了。复制网址，到 Mac 的浏览器里打开就能下载。",
        "phone_btn": "复制网址 flipic.app", "phone_done": "已复制，到 Mac 上粘贴打开",
        "crumbs_home": "Flipic", "crumbs_guides": "指南", "updated": "更新于 " + UPDATED,
        "cta": "Flipic 是一款免费开源的 Mac 看图软件，双击一张图，左右键就能翻完整个文件夹。",
        "related": "相关指南",
        "footer_credit": "截图中的照片来自 Wikimedia Commons，均为 CC0：圣托里尼 Aidan Meyer、Anthony Delanoix，布莱德湖 Aleš Krivec，哈尔施塔特 Fineas Anton、Martin Horák，冰岛 Alexandre Godreau，优胜美地 John Salzarulo，阳朔 Manon Boyer。",
        "footer_line": "Flipic {v} · MIT 开源 · 原名 PixDeck",
        "src": "源代码", "feedback": "反馈问题", "releases": "历史版本",
        "privacy": "隐私政策", "terms": "用户协议",
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
<meta property="og:site_name" content="Flipic for Mac">
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
        "@context": "https://schema.org", "@type": "SoftwareApplication", "name": "Flipic",
        # 「Flipic」这个词常被当成拼错的 flip icon / flipaclip，写全称帮搜索引擎认出是哪个软件
        "alternateName": ["Flipic for Mac", "Flipic Image Viewer", "Flipic 看图"],
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
        {"@type": "ListItem", "position": 1, "name": "Flipic", "item": f"{BASE}{t['home']}"},
        {"@type": "ListItem", "position": 2, "name": t["crumbs_guides"], "item": f"{BASE}{t['home']}#guides"},
        {"@type": "ListItem", "position": 3, "name": title, "item": f"{BASE}{path}"}]}


def shot(name, alt, w=1440, h=900, eager=False):
    load = 'fetchpriority="high"' if eager else 'loading="lazy" decoding="async"'
    return f'<img class="shot" src="{SHOTS}{name}" alt="{esc(alt)}" width="{w}" height="{h}" {load}>'


# ---------------------------------------------------------------- 首页内容

HOME = {
    "zh": {
        "title": "Flipic Mac 看图：摄影师挑片用的免费看图软件，方向键翻页、看焦点、打星",
        "desc": "Flipic 是给摄影师挑片用的免费 Mac 看图软件。导完卡，双击一张照片，用方向键翻完整个文件夹，按 0 在鼠标处放大到 100% 看焦点，按 1–5 打星、P 标记要留的，星级 Lightroom 和 Capture One 都能读。支持主流相机 RAW，免费开源。",
        "eyebrow": "给摄影师挑片用的 Mac 看图软件",
        "h1": "导完卡，<br>用方向键挑一遍",
        "lede": "拍完一组想先挑一挑，Mac 自带的「预览」只能一张张打开，开 Lightroom 又得先导入。我自己嫌麻烦，就做了 Flipic：双击文件夹里随便一张，左右键往下翻，看中的打个星，回到 Lightroom 里星还在。现在用它的基本都是摄影师。",
        "deck_hint": "这是 Flipic 的实际界面，按键盘上的 <kbd>←</kbd><kbd>→</kbd> 可以翻页",
        "deck_alt": "Flipic 浏览文件夹中的第 {n} 张照片", "prev": "上一张", "next": "下一张",
        "features": [
            ("filmstrip.webp", "Flipic 底部缩略图栏与左右翻页按钮", "翻片不用先导入",
             "<p>双击文件夹里任意一张，<kbd>→</kbd> 下一张，<kbd>←</kbd> 上一张，整个文件夹都能翻到。排序默认按文件名，连拍的话改成按拍摄时间会顺一些。</p>"
             "<p>后面几张会先在后台准备好，4800 万像素的照片按住方向键一直翻也跟得上。按一下 <kbd>空格</kbd>，窗口会变成照片的比例，竖拍就是个竖长的窗口。</p>"),
            ("zoom.webp", "Flipic 在鼠标位置放大到 100% 查看对焦", "看清楚焦点对没对上",
             "<p>鼠标移到眼睛上按 <kbd>0</kbd>，就以那儿为中心放大到 100%，对没对上一下就看出来了，再按一次回到整张。用触控板捏合或者滚轮缩放，也是围着鼠标的位置放大。</p>"
             "<p>连拍里拿不准留哪张的话，按 <kbd>C</kbd> 把两张并排放，放大、拖动的时候两张一起动，方便对着同一个地方比。</p>"),
            ("settings.webp", "Flipic 设置窗口：快捷键可以自己改", "打的星 Lightroom 也认",
             "<p><kbd>1</kbd> 到 <kbd>5</kbd> 打星，<kbd>P</kbd> 标记要留的。星级存成标准的 XMP，Lightroom、Bridge、Capture One 都读得到。JPEG 和 HEIC 只改里面的信息，不会重新压缩；RAW 的星级写在旁边一个同名的 .xmp 文件里。标记是访达标签，换个软件也还在。</p>"
             "<p>挑完按 <kbd>⇧P</kbd> 只看标记过的，或者只看几星以上的，再按 <kbd>⇧⌘E</kbd> 一起拷到别的文件夹。快捷键用不惯的话，设置里每个都能改。</p>"),
            ("cleanup.webp", "Flipic 清理模式：相似连拍分组与推荐保留", "让它先把废片找出来",
             "<p>一场活动拍下来几百张，可以按 <kbd>⇧⌘K</kbd> 打开清理模式。它在你自己的 Mac 上把整个文件夹过一遍，相似的连拍、一模一样的文件、闭眼的、糊的分别归到一起，每组里标出最清楚的那张。</p>"
             "<p>删哪些还是你说了算，点了「移到废纸篓」才会删，删错了 <kbd>⌘Z</kbd> 能撤回来。同名的 RAW 和 JPG 会一起处理。</p>"),
            ("exif.webp", "Flipic 照片信息面板显示相机、镜头与拍摄参数", "参数按 I 才出来",
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
            ("同名 RAW 和 JPG 一起处理", "不支持", "删除、清理时一起走"),
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
            ("能代替 Lightroom 挑片吗？", "挑片可以用它。在 Flipic 里翻一遍、打星、删掉废片，打的星 Lightroom 和 Capture One 都读得到。调色修图还是回原来的软件，按 ⌘E 就能把当前这张在那边打开。"),
            ("Mac 上怎么看下一张图片？", "用 Flipic 双击任意一张图片，按右方向键就是下一张，左方向键是上一张，同一个文件夹里的图片都能翻到。"),
            ("怎么设为默认看图软件？", "打开 Flipic 的设置（⌘,），在「通用」里点「设为默认看图软件」，常见图片格式和相机 RAW 一次设好。"),
            ("支持哪些格式？", "JPEG、PNG、HEIC、WebP、GIF 动图、TIFF、AVIF、JPEG XL（macOS 14 起），以及索尼、佳能、尼康、富士等相机 RAW。"),
            ("Intel 芯片的 Mac 能用吗？", "能。Flipic 同时支持 Apple 芯片和 Intel 芯片，需要 macOS 13 或更新版本。"),
            ("以前装过 PixDeck 怎么办？", "Flipic 就是改名后的 PixDeck。把「应用程序」里的 PixDeck 拖进废纸篓，再装 Flipic，原来的设置都会保留。"),
        ],
        "end": "下载 Flipic",
    },
    "en": {
        "title": "Flipic for Mac: a free photo viewer for culling, with arrow keys, focus check and star ratings",
        "desc": "A free, open-source photo viewer for photographers on Mac. Double-click a photo from the card and arrow through the folder, press 0 to check focus at 100%, rate with 1–5 and mark keepers with P. Lightroom and Capture One read the ratings. Supports camera RAW.",
        "eyebrow": "A Mac photo viewer for culling a shoot",
        "h1": "Offload the card,<br>cull with the arrow keys",
        "lede": "After a shoot, Preview makes you open photos one at a time, and Lightroom wants an import first. Flipic opens the folder as it is: double-click any photo, press → for the next one, 0 to zoom to 100% at the pointer and check focus, 1–5 to rate and P to mark keepers. Ratings are saved as standard XMP, so they are still there in Lightroom and Capture One.",
        "deck_hint": "This is the real Flipic window. Press <kbd>←</kbd><kbd>→</kbd> on your keyboard to page through",
        "deck_alt": "Flipic showing photo {n} in a folder", "prev": "Previous", "next": "Next",
        "features": [
            ("filmstrip.webp", "Flipic thumbnail strip and navigation arrows", "Page through the card, no import",
             "<p>Double-click any photo in the folder and press <kbd>→</kbd> for the next one or <kbd>←</kbd> for the previous one. Sort by date taken, name, date modified or size; date taken keeps bursts in order.</p>"
             "<p>The next few photos are prepared in the background, so even 48-megapixel images keep up when you hold an arrow key. Press <kbd>Space</kbd> and the window takes the shape of the photo, tall for portrait shots.</p>"),
            ("zoom.webp", "Flipic zooming to 100% at the pointer to check focus", "Press 0 to check focus",
             "<p>Point at the eyes or whatever needs to be sharp and press <kbd>0</kbd> to zoom to 100% around it; you can tell at once whether it’s in focus. Press it again to see the whole photo. Pinch and scroll-wheel zoom also center on the pointer.</p>"
             "<p>Not sure which frame in a burst is sharper? Press <kbd>C</kbd> to put two side by side; zooming and dragging move both, so you compare the same spot.</p>"),
            ("settings-en.webp", "Flipic Settings window with editable shortcuts", "Ratings and marks that Lightroom sees",
             "<p>Press <kbd>1</kbd> to <kbd>5</kbd> to rate and <kbd>P</kbd> to mark keepers. Ratings are saved as standard XMP, which Lightroom, Bridge and Capture One read: JPEG and HEIC only get their metadata changed and are not recompressed, and camera RAW ratings go into a .xmp file with the same name. Marks are Finder tags, so they survive a change of app.</p>"
             "<p>When you’re done, <kbd>⇧P</kbd> shows only marked photos, or show only a minimum rating, and <kbd>⇧⌘E</kbd> copies them to another folder. Every shortcut can be changed in Settings.</p>"),
            ("cleanup-en.webp", "Flipic Cleanup Mode grouping similar bursts", "Bursts, closed eyes and blur, found for you",
             "<p>After an event, press <kbd>⇧⌘K</kbd> for Cleanup Mode. Flipic checks the folder on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry shots, marking the sharpest photo in each group.</p>"
             "<p>You decide what goes. Nothing is deleted until you click Move to Trash, and <kbd>⌘Z</kbd> undoes it. RAW and JPG files with the same name are handled together.</p>"),
            ("exif.webp", "Flipic photo info panel with camera, lens and exposure", "Shooting details when you need them",
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
            ("RAW and JPG pairs handled together", "No", "When deleting and cleaning up"),
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
            ("Can it replace Lightroom for culling?", "For culling, yes; for editing, no. Page through, check focus, rate, mark and delete rejects in Flipic, and Lightroom or Capture One will read the ratings. Edit in the app you already use; ⌘E opens the current photo there."),
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
<p><strong>Flipic</strong>：免费开源，安装包 4.1 MB。双击一张图后用 <kbd>←</kbd> <kbd>→</kbd> 翻完整个文件夹，滚轮默认缩放，按 <kbd>0</kbd> 在鼠标处放大到 100%，这些都照着 Windows 看图软件的手感来做。快捷键都能在设置里改；用 Mos 改过滚轮方向的，可以把缩放方向反过来。</p>
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
<p>用 Flipic 打开整个文件夹，按 <kbd>⇧⌘K</kbd> 进入清理模式。它在本机检查每一张，分成四类：相似连拍、内容完全相同、闭眼、模糊或虚焦。连拍组里推荐保留最清楚、没人闭眼的那张，其余默认勾上。</p>
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
<p><strong>Flipic</strong>: free and open source, a 4.1 MB download. Double-click a photo and page with <kbd>←</kbd> <kbd>→</kbd>; the wheel zooms by default; <kbd>0</kbd> zooms to 100% at the pointer. Every shortcut can be remapped, and if you reversed your wheel with Mos you can flip the zoom direction.</p>
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
<p>Open the folder in Flipic and press <kbd>⇧⌘K</kbd> for Cleanup Mode. It checks every photo on your Mac and groups similar bursts, exact duplicates, closed eyes and blurry or out-of-focus shots, suggesting the sharpest blink-free frame of each burst.</p>
<figure>{shot('cleanup-en.webp', 'Flipic Cleanup Mode grouping bursts and suggesting a keeper', 1440, 967)}<figcaption>Faces flagged for closed eyes are outlined; Space zooms in to check.</figcaption></figure>
<p>Nothing is deleted until you press Move to Trash, and <kbd>⌘Z</kbd> undoes it. Detection can be wrong, so look before you delete.</p>
<h2>2. Page through and rate</h2>
<p>Press <kbd>→</kbd> through what's left and <kbd>1</kbd>–<kbd>5</kbd> to rate. Rest the pointer on a face and press <kbd>0</kbd> to check focus at 100%. Or run a slideshow, click to pause on a good one, rate it, click to resume.</p>
<p>Ratings are standard XMP: inside JPEG and HEIC files, in a same-name .xmp sidecar for proprietary RAW, leaving the RAW untouched.</p>
<h2>3. Hand the keepers to your editor</h2>
<p>Choose Lightroom, Photoshop or Capture One in Settings and press <kbd>⌘E</kbd> on a photo to open it there, the RAW if one sits next to the JPEG. Lightroom picks up the star ratings on import, so you can filter by them right away.</p>""",
      howto=["Open the folder in Flipic and press ⇧⌘K for Cleanup Mode", "Review the suggested bursts, closed eyes and blurry shots and move them to the Trash", "Page through the rest and rate with 1–5", "Press ⌘E to open keepers in Lightroom or Photoshop"])


guide("zh", "/guides/mac-image-viewer-recommend/", "Mac 看图软件推荐（2026）：预览不够用时可以换哪些",
      "Mac 看图软件推荐",
      "Mac 自带的预览翻不了整个文件夹。这里把 2026 年还在更新的 Mac 看图软件按免费开源、免费不开源、付费三类列出来，写清楚各自适合谁。",
      "免费开源、免费、付费三类，各自适合什么人",
      f"""<p>Mac 自带的「预览」只在你一起打开的几个文件之间切换，双击打开一张后，同一个文件夹里的其他图片翻不到。下面这些都能解决这个问题，按类型分开写。信息在 2026 年 11 月 1 日从各自官网、GitHub 和 App Store 核对过，价格和版本以官网为准。</p>
<h2>免费开源</h2>
<table><thead><tr><th>软件</th><th>协议</th><th>适合</th></tr></thead><tbody>
<tr><td>Flipic</td><td>MIT</td><td>只用 Mac、想要 Windows 看图软件那种手感：双击后方向键翻整个文件夹，按 0 在鼠标处放大到 100%，打星、标记、挑片</td></tr>
<tr><td>PicView</td><td>GPL-3.0</td><td>Mac 和 Windows 都用；支持的格式多，相机 RAW 也在列；可以 <code>brew install picview</code></td></tr>
<tr><td>FlowVision</td><td>GPL-3.0</td><td>喜欢按瀑布流网格浏览整个文件夹，也看视频；Swift 写的原生 Mac 软件</td></tr>
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
<ul><li>只是想双击一张后方向键往下翻：Flipic、qView、PicView 都可以，Flipic 最接近 Windows 看图软件的手感。</li><li>主要挑相机 RAW、要看焦点和直方图：FastRawViewer。</li><li>要一个能管理、能批量处理的「大」软件：XnView MP。</li><li>喜欢网格浏览：FlowVision。</li></ul>
<p>说明一下：Flipic 是本站的软件。看图、打星、标记、筛选、导出都免费开源；另有一个可选的付费 Pro，只加了批量整理的功能，大多数人用不上。</p>
<figure>{{shot('filmstrip.webp', 'Flipic 底部缩略图栏与左右翻页')}}<figcaption>Flipic：双击一张，方向键翻完整个文件夹。</figcaption></figure>""")

guide("en", "/en/guides/open-source-image-viewers-mac/", "Open-source image viewers for Mac (2026): which one to pick",
      "Open-source image viewers for Mac",
      "Preview can't page through a folder. These open-source Mac image viewers can, checked against their official sites and GitHub in November 2026, with notes on who each one suits.",
      "Seven maintained options, what each is good at, and two to skip",
      f"""<p>Preview only moves between files you opened together, so after you double-click one photo you can't page through the rest of the folder. The viewers below fix that and are all open source. Everything here was checked on 1 November 2026 against each project's site, GitHub releases and licenses; check the project pages for current versions.</p>
<h2>The short list</h2>
<table><thead><tr><th>Viewer</th><th>License</th><th>Good for</th></tr></thead><tbody>
<tr><td>Flipic</td><td>MIT</td><td>Mac-only users who want the Windows-viewer feel: arrow keys through the folder, 0 to zoom to 100% at the pointer, ratings, marks and culling</td></tr>
<tr><td>PicView</td><td>GPL-3.0</td><td>People on both Mac and Windows; a long format list including camera RAW; <code>brew install picview</code></td></tr>
<tr><td>FlowVision</td><td>GPL-3.0</td><td>Browsing a folder as a waterfall grid, with video; a native Swift app</td></tr>
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
<ul><li>You just want to double-click a photo and arrow through the folder: Flipic, qView or PicView. Flipic is the closest to IrfanView or Honeyview in feel.</li><li>You mostly cull RAW and need focus and histograms: FastRawViewer.</li><li>You want one big tool that also organizes and converts: XnView MP.</li><li>You like grids: FlowVision.</li></ul>
<p>Disclosure: Flipic is made by the people behind this site. Viewing, ratings, marks, filtering and export are free and MIT-licensed; an optional paid Pro adds batch tools that most people won't need.</p>
<figure>{{shot('filmstrip.webp', 'Flipic thumbnail strip and arrow-key paging')}}<figcaption>Flipic: double-click a photo, then arrow through the folder.</figcaption></figure>""")


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
    out = head(lang, g["path"], g["title"] + (" | Flipic Mac 看图" if lang == "zh" else " | Flipic for Mac"), g["desc"], schema, og_type="article") + header(lang, g["path"])
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
        "title": "Flipic Mac 看图 Pro：给大量挑片、修图的摄影师准备的批量功能",
        "desc": "Flipic 免费版已经够大多数人用。Pro 加了管拍摄的工作台、放大到眼睛、按内容和照片里的字找照片、修图前后对比这些功能，一次买断，下载就有 7 天试用。",
        "eyebrow": "给经常挑片的摄影师",
        "h1": "Flipic Pro",
        "lede": "给一次要挑几百上千张照片的人多准备的几样东西。一次买断，下载 Flipic 就能先试用 7 天。",
        "try": "下载，先试用 7 天",
        "hero_alt": "Flipic 工作台：左边是拍摄项目列表，中间是一场婚礼的宫格，右边是大图和直方图",
        "honest_title": "先说一句：大多数人用免费版就够了",
        "honest": [
            "看图、RAW 秒开、打星、标记、按星级筛选、导出到文件夹、并排对比、清理相似和模糊的照片，这些都是免费的，代码也开源，以后不会改成要付费。",
            "Pro 是给经常一次处理几百上千张照片的人准备的。平时只是看看照片、偶尔挑几张的话，用不到它，不用买。卖 Pro 的收入用来继续维护 Flipic，免费版也会一直更新。",
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
            "body": "原片和修过的那张叠在一起，按住 <kbd>\\</kbd> 看修图前，松开看修图后。也可以拖一条分割线左右对照，或者调修图后那张的透明度。Flipic 会按文件名找到对应的两张，比如 IMG_1234.RAF 和 IMG_1234-编辑.jpg，或者导出文件夹里同名的那张。",
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
        "price_note": "一次买断，之后的更新都能用。付款后马上拿到激活码，不用注册账号。",
        "trial": "下载 Flipic 就带 7 天试用，到期后免费功能照常可用。",
        "free_title": "免费和 Pro",
        "free_head": ("功能", "免费", "Pro"),
        "free_rows": [("看图、RAW 秒开、HDR、幻灯片", "有", "有"), ("评星、标记、按星级筛选", "有", "有"),
                      ("导出到文件夹、并排对比、清理模式", "有", "有"), ("批量转格式、批量重命名", "有", "有"),
                      ("工作台", "", "有"), ("放大到眼睛", "", "有"), ("按内容、按照片里的字找照片", "", "有"), ("修图前后对比", "", "有"), ("JPG 和 RAW 合并显示", "", "有"), ("按星级分到子文件夹", "", "有"),
                      ("常用文件夹 ⌥1–⌥9", "", "有"), ("删除没挑中的照片", "", "有"), ("批量送进后期软件", "", "有"),
                      ("自定义同名关联", "", "有")],
        "faq": [
            ("激活码怎么用？", "付款成功的页面上有激活码和「在 Flipic 中激活」按钮，点一下就激活了。也可以复制激活码，粘贴到 Flipic「设置 › Pro」里。"),
            ("要联网验证吗？", "激活时联网登记一次，只发激活码订单号和设备号的哈希，没网也能激活。之后在 Mac 上离线验证，Flipic 照样默认不联网。"),
            ("能装在几台 Mac 上？", "你自己的 Mac 都可以用同一个激活码。"),
            ("激活码丢了怎么办？", "在 <a href=\"https://pay.flipic.app/recover?lang=zh\">找回激活码</a> 页面输入付款邮箱和卡号后四位就能找回。"),
            ("Flipic 还是开源的吗？", "是。看图和挑片的核心功能继续开源（MIT），Pro 功能的代码不在公开仓库里。"),
        ],
    },
    "en": {
        "path": "/en/pro/",
        "title": "Flipic for Mac Pro: batch tools for photographers who cull and edit a lot",
        "desc": "The free Flipic is enough for most people. Pro adds a Workbench for your shoots, zoom to the eyes, search by what’s in a photo or the text on it, and before & after. One-time purchase, 7-day trial in every download.",
        "eyebrow": "For photographers who cull a lot",
        "h1": "Flipic Pro",
        "lede": "A few extra tools for people who go through hundreds or thousands of photos at a time. One-time purchase, and every download includes a 7-day trial.",
        "try": "Download and try it for 7 days",
        "hero_alt": "Flipic Workbench: shoot projects on the left, a wedding shoot in the grid, a large preview with a histogram on the right",
        "honest_title": "First, most people will be fine with the free version",
        "honest": [
            "Viewing, quick RAW previews, ratings, marks, filtering by rating, export to a folder, side-by-side comparison and cleaning up similar or blurry photos are all free, the code is open source, and none of it will become paid.",
            "Pro is for people who often go through hundreds or thousands of photos at a time. If you mostly look at photos and pick a few now and then, you won’t use it, so there’s no need to buy it. Pro sales pay for keeping Flipic going, and the free version keeps getting updates too.",
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
            "body": "The original and the edited version sit on top of each other. Hold <kbd>\\</kbd> to see the original and let go to see the edit. You can also drag a split line to compare side by side, or change the edit’s opacity. Flipic finds the pair by file name, such as IMG_1234.RAF and IMG_1234-Edit.jpg, or a file with the same name in an export folder.",
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
        "price_note": "One-time purchase with future updates included. You get your key right after paying. No account.",
        "trial": "Every download includes a 7-day trial; after it ends, the free features keep working.",
        "free_title": "Free and Pro",
        "free_head": ("Feature", "Free", "Pro"),
        "free_rows": [("Viewing, instant RAW, HDR, slideshow", "Yes", "Yes"), ("Ratings, marks, filter by rating", "Yes", "Yes"),
                      ("Export to folder, side-by-side, Cleanup Mode", "Yes", "Yes"), ("Batch convert, batch rename", "Yes", "Yes"),
                      ("Workbench", "", "Yes"), ("Zoom to the eyes", "", "Yes"), ("Find photos by content or text", "", "Yes"), ("Before & after", "", "Yes"), ("Merge JPG and RAW", "", "Yes"), ("Sort into folders by rating", "", "Yes"),
                      ("Favorite folders ⌥1–⌥9", "", "Yes"), ("Delete what you didn’t pick", "", "Yes"), ("Send a batch to your editor", "", "Yes"),
                      ("Custom linked files", "", "Yes")],
        "faq": [
            ("How do I activate?", "The payment confirmation page shows your key and an Activate in Flipic button. Or copy the key and paste it into Flipic › Settings › Pro."),
            ("Does it need to go online?", "Activation registers once, sending only hashes of the order number and device ID, and still works offline. After that the key is checked offline on your Mac, and Flipic stays offline by default."),
            ("How many Macs?", "Use the same key on all of your own Macs."),
            ("I lost my key", "Use <a href=\"https://pay.flipic.app/recover?lang=en\">Recover Key</a> with your payment email and the last four digits of your card."),
            ("Is Flipic still open source?", "Yes. The core viewer and culling features stay open source (MIT). Pro code isn’t in the public repository."),
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
    buy_btn = f'<a class="btn" href="{PRO_BUY_URL}">{p["buy"]}{" · " + esc(price) if price else ""}</a>'
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
        both = f"Flipic 和 {store}" if store else "Flipic"
        store_full = f"{store}（同一款软件在 Mac App Store 上的版本）" if store else "Flipic 的 Mac App Store 版"
        store_short = f" {store} " if store else "Mac App Store 版"
    else:
        both = f"Flipic and {store}" if store else "Flipic"
        store_full = f"{store} (the same app on the Mac App Store)" if store else "the Mac App Store version of Flipic"
        store_short = store or "The Mac App Store version"
    mail = esc(LEGAL["email"])
    m = f'<a href="mailto:{mail}">{mail}</a>'
    days = LEGAL["refund_days"]
    eff = LEGAL["effective"]
    if lang == "zh":
        privacy = ("/privacy/", "隐私政策", f"{both} 的隐私政策：照片只在你的 Mac 上处理，不收集个人信息；购买 Pro 时付款信息由 Stripe 或 Apple 处理。", f"""
<p class="lede">生效日期：{eff}</p>
<div class="prose">
<p>这份政策适用于 Flipic（从 flipic.app 和 GitHub 下载的版本）、{store_full}、flipic.app 网站和 pay.flipic.app 付款服务。运营者是{op}。</p>
<h2>软件本身</h2>
<p>照片只在你的 Mac 上读取和显示，不会上传到任何地方。软件不需要账号，没有广告、统计和崩溃上报，也不收集设备信息。</p>
<p>你给照片打的星级写进照片的 XMP 信息，相机 RAW 写在同名的 .xmp 文件里；挑片标记是访达标签；设置保存在这台 Mac 上。这些都留在你自己的电脑上。</p>
<p>Flipic 默认不联网。只有你打开「自动检查更新」或点「检查更新」时，才会向 flipic.app 请求一个只写着最新版本号的文件，请求里除了软件版本号没有别的信息，也不保存 cookie。你点「立即更新」时，安装包从 GitHub 下载。</p>
<p>另外几种情况会联网，都由你主动触发：在设置里下载「更准的中文识别」模型时，从 GitHub 下载；在「关于 Flipic」里发送反馈时，发送你写的内容、你留的邮箱（可以不填）和 App、系统版本，存在 pay.flipic.app 的反馈记录里，用来回复你和改进软件，不含照片和文件；为了防止刷屏，同时保存一个加盐处理过的 IP 哈希，不保存 IP 本身。</p>
<p>{store_short}付费下载即是完整版，没有 App 内购买；它不检查更新，更新和付款都由 App Store 负责，App 本身不联网。</p>
<h2>购买 Pro</h2>
<p>在官网购买时，付款由 Stripe 处理，银行卡等支付信息由 Stripe 收集，我们看不到完整卡号。付款完成后，pay.flipic.app 从 Stripe 读取这笔订单的邮箱和订单号，生成激活码。激活码里包含邮箱和订单号，在你的 Mac 上离线验证。订单记录保存在我们的 Stripe 账户里，用来帮你找回激活码、处理退款和记账。激活时，Flipic 向 pay.flipic.app 登记一次：只发送订单号的哈希和这台 Mac 设备号的哈希，不含邮箱和电脑名，用来发现被公开转卖的激活码；IP 地址只用来限制请求频率，不保存。Stripe 如何处理信息见 <a href="{STRIPE_PRIVACY}">Stripe 隐私政策</a>。</p>
<p>找回激活码时，你填写的邮箱和卡号后四位（或收据号）只用来在 Stripe 里查找订单，不会保存。为了防止有人反复试探，找回页面按 IP 地址限制每分钟的请求次数，IP 地址不保存。</p>
<p>在 App Store 购买时，付款和账户都由 Apple 处理，我们收不到你的姓名、邮箱或支付信息。见 <a href="{APPLE_PRIVACY}">Apple 隐私政策</a>。</p>
<h2>网站</h2>
<p>flipic.app 托管在 Cloudflare 上。网站不使用 cookie，没有统计脚本、广告和第三方字体。Cloudflare 为了安全和正常运行会记录访问日志（比如 IP 地址和浏览器类型），我们只查看汇总的访问量和下载量。</p>
<h2>查询和删除</h2>
<p>如果你想知道我们保存了哪些和你的订单有关的信息，或者希望删除，请发邮件到 {m}。按照财务和税务法规必须保留的付款记录除外。</p>
<h2>政策变化</h2>
<p>软件或服务处理信息的方式有变化时，我们会更新这一页并修改生效日期。</p>
</div>""")
        terms = ("/terms/", "用户协议", f"{both} 的使用条款：免费功能、Pro 一次买断、退款方式和免责说明。", f"""
<p class="lede">生效日期：{eff}</p>
<div class="prose">
<p>这份协议适用于 Flipic（从 flipic.app 和 GitHub 下载的版本）和 {store_full}，由{op}提供。使用软件即表示你同意这份协议。</p>
<h2>免费使用</h2>
<p>Flipic 的源代码以 <a href="https://opensource.org/license/mit">MIT 协议</a>在 <a href="{GITHUB}">GitHub</a> 开源。看图、评星、标记、筛选、导出、清理这些功能免费使用，不需要注册。</p>
<h2>Pro</h2>
<p>Pro 是一次性购买，不是订阅。买过以后，之后发布的更新里的 Pro 功能都可以用。Pro 供购买者本人在自己的 Mac 上使用。</p>
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
<p>This policy covers Flipic (the version downloaded from flipic.app and GitHub), {store_full}, the flipic.app website and the pay.flipic.app payment service. They are run by {op}.</p>
<h2>The app</h2>
<p>Your photos are read and shown only on your Mac and are never uploaded. The app has no account, no ads, no analytics and no crash reporting, and it doesn’t collect device information.</p>
<p>Star ratings are written into each photo’s XMP data, or into a matching .xmp file for camera RAW; marks are Finder tags; settings are stored on your Mac. All of this stays on your computer.</p>
<p>Flipic is offline by default. Only when you turn on automatic update checks or click Check for Updates does it request a small file from flipic.app that contains the latest version number. The request carries nothing but the app’s version number and stores no cookies. When you click Update Now, the installer is downloaded from GitHub.</p>
<p>A few other things connect, and only when you trigger them: downloading the more accurate recognition model in Settings fetches it from GitHub; sending feedback from About Flipic sends what you wrote, the email you leave (optional) and the app and macOS versions, stored in pay.flipic.app’s feedback records so we can reply and improve the app. No photos or files are sent. To stop spam we also keep a salted hash of the IP address, not the address itself.</p>
<p>{store_short} is a paid download that includes everything, with no in-app purchases. It doesn’t check for updates; the App Store handles updates and payment, and the app itself doesn’t go online.</p>
<h2>Buying Pro</h2>
<p>On flipic.app, payment is handled by Stripe. Stripe collects your card details; we never see the full card number. After you pay, pay.flipic.app reads the order’s email address and order ID from Stripe and generates your license key. The key contains the email and order ID and is checked offline on your Mac. Order records stay in our Stripe account and are used to recover keys, handle refunds and keep accounts. On activation, Flipic registers once with pay.flipic.app, sending only a hash of the order ID and a hash of this Mac’s device ID (no email or computer name), so we can spot keys that are being resold publicly; the IP address is used only for rate limiting and is not stored. See the <a href="{STRIPE_PRIVACY}">Stripe Privacy Policy</a>.</p>
<p>When you recover a key, the email and last four card digits (or receipt number) you enter are used only to look up the order in Stripe and are not stored. To stop repeated guessing, the recovery page limits requests per minute by IP address; the address is not stored.</p>
<p>On the App Store, Apple handles the payment and your account. We don’t receive your name, email or payment details. See the <a href="{APPLE_PRIVACY}">Apple Privacy Policy</a>.</p>
<h2>The website</h2>
<p>flipic.app is hosted on Cloudflare. It uses no cookies, no analytics scripts, no ads and no third-party fonts. Cloudflare keeps access logs (such as IP address and browser type) for security and operation; we only look at total visits and downloads.</p>
<h2>Questions and deletion</h2>
<p>To find out what we hold about your order, or to ask us to delete it, email {m}. Payment records we must keep for tax and accounting law are excepted.</p>
<h2>Changes</h2>
<p>If the way the app or services handle information changes, we’ll update this page and its effective date.</p>
</div>""")
        terms = ("/en/terms/", "Terms of Use", f"Terms of use for {both}: free features, the one-time Pro purchase, refunds and disclaimers.", f"""
<p class="lede">Effective {eff}</p>
<div class="prose">
<p>These terms cover Flipic (the version downloaded from flipic.app and GitHub) and {store_full}, provided by {op}. By using the app you agree to them.</p>
<h2>Free use</h2>
<p>Flipic’s source code is available under the <a href="https://opensource.org/license/mit">MIT License</a> on <a href="{GITHUB}">GitHub</a>. Viewing, ratings, marks, filtering, export and Cleanup Mode are free and need no account.</p>
<h2>Pro</h2>
<p>Pro is a one-time purchase, not a subscription. Once bought, the Pro features in later updates are included. Pro is for the buyer’s own use on their own Macs.</p>
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
    out = head(lang, path, title + (" | Flipic" ), desc, []) + header(lang, path)
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
    (OUT / f"{INDEXNOW_KEY}.txt").write_text(INDEXNOW_KEY)
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {BASE}/sitemap.xml\n")

    guide_lines = "\n".join(f"- [{g['title']}]({BASE}{g['path']}): {g['desc']}" for lang in ("en", "zh") for g in GUIDES[lang])
    (OUT / "llms.txt").write_text(f"""# Flipic

> Flipic is a free, open-source (MIT) image viewer for macOS 13+. Double-click any photo and page through the whole folder with the arrow keys. {SIZE} download, notarized by Apple, offline by default, no account.

Key facts:
- Paging: ← → through every image in the folder; Space wraps the window to the photo; 0 zooms to 100% at the pointer.
- Star ratings 1–5 written as XMP (embedded for JPEG/HEIC/TIFF, .xmp sidecar for proprietary RAW), readable by Lightroom, Bridge and Capture One.
- Cleanup Mode: finds similar bursts, exact duplicates, closed eyes and blurry photos on-device.
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
