#!/usr/bin/env python3
"""部署后把 sitemap 里的网址推给 IndexNow（Bing、Yandex、Seznam 等共用）。用法：python3 site/indexnow.py"""
import json, re, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parent
key = re.search(r'INDEXNOW_KEY = "(\w+)"', (ROOT / "build.py").read_text()).group(1)
urls = re.findall(r"<loc>([^<]+)</loc>", (ROOT / "public/sitemap.xml").read_text())
body = json.dumps({"host": "flipic.app", "key": key, "keyLocation": f"https://flipic.app/{key}.txt", "urlList": urls}).encode()
req = urllib.request.Request("https://api.indexnow.org/indexnow", data=body, headers={"Content-Type": "application/json; charset=utf-8"})
with urllib.request.urlopen(req, timeout=20) as r:
    print("IndexNow", r.status, len(urls), "urls")
