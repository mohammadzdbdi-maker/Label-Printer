#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
شبیهساز server.ps1 برای تست زنده‌ی بخش وب روی لینوکس/مرورگر.

همان قرارداد HTTP سرور PowerShell را پیاده میکند، ولی به جای چاپ واقعی،
PNG لیبل را داخل /tmp/zebra-label-tests ذخیره میکند (پرینتر فیک).

اجرا:  python3 tests/mock_server.py --port 8080
"""
import argparse
import base64
import json
import re
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "label-server"
OUT = Path("/tmp/zebra-label-tests")
OUT.mkdir(exist_ok=True)

MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ttf": "font/ttf",
    ".png": "image/png",
    ".webmanifest": "application/manifest+json",
}
CONFIG = {
    "foot": "داروخانه شبانه روزی دکتر زارعی - سیرجان ، چهار راه شهربابک - 03442204802",
    "widthMm": 58,
    "heightMm": 40,
}


class Handler(BaseHTTPRequestHandler):
    server_version = "ZebraLabelMock/1.0"

    def log_message(self, fmt, *args):
        print(f"{datetime.now():%H:%M:%S}  {self.address_string()}  " + fmt % args, flush=True)

    def send_bytes(self, code, body, ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, code=200):
        self.send_bytes(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                        "application/json; charset=utf-8")

    def send_attachment(self, file_path, filename):
        """ارسال فایل ZIP بهصورت جریانی (بدون خواندن ۱۰۰ مگابایت در حافظه)"""
        f = Path(file_path)
        if not f.is_file():
            return self.send_bytes(404, b"file not found")
        size = f.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        with f.open("rb") as fh:
            while True:
                chunk = fh.read(256 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
        self.log_message("DOWNLOAD %s (%d bytes)", filename, size)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/Label-Printer.zip", "/full.zip"):
            return self.send_attachment("/tmp/zebra-dist/Label-Printer-full.zip", "Label-Printer.zip")
        if path in ("/ZebraManager-update.zip", "/update.zip"):
            return self.send_attachment("/tmp/zebra-dist/ZebraManager-update.zip", "ZebraManager-update.zip")
        if path == "/download":
            page = """<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>دریافت نرم افزار مدیریت پرینتر</title>
<style>body{font-family:Tahoma,sans-serif;background:#eef3f7;color:#14212b;margin:0;padding:28px;line-height:1.9}
.wrap{max-width:720px;margin:auto;background:#fff;border-radius:18px;padding:26px;box-shadow:0 12px 40px -18px #345}
h1{margin:0 0 6px;font-size:21px;color:#0e7c86}p{color:#6a768c;font-size:14px}
a{display:block;margin:14px 0;padding:16px 20px;border-radius:12px;text-decoration:none;font-weight:bold;font-size:15px}
a.full{background:linear-gradient(135deg,#0e7c86,#0b5f67);color:#fff}a.upd{background:#fff8e6;border:1.5px solid #f2cf7a;color:#8a5a00}
code{background:#f2f6fa;padding:2px 6px;border-radius:6px;font-size:13px}small{color:#6a768c}</style></head>
<body><div class="wrap"><h1>دریافت نرم افزار مدیریت پرینتر</h1>
<p>روی یکی از دکمههای زیر کلیک کنید تا فایل ZIP ذخیره شود، سپس آن را Extract کنید و <code>ZebraManager.bat</code> را اجرا کنید.</p>
<a class="full" href="/Label-Printer.zip">⬇️ بسته کامل (۹۸ مگابایت) — شامل درایور Zebra، آماده اجرا</a>
<a class="upd" href="/ZebraManager-update.zip">⬇️ فقط فایلهای جدید (۵۴ کیلوبایت) — اگه پوشه قدیمی با درایور رو داری</a>
<p style="margin-top:22px"><small>بسته دوم را در همان پوشه <code>Zebra GK888t Setup</code> قدیمی Extract کنید (جایگزینی فایلها را تایید کنید). بسته کامل را هرجا Extract کنید، فقط ساختار پوشهها (<code>app</code>، <code>lib</code>، <code>config</code>، <code>driver</code>) را بههم نزنید.</small></p>
<p><small>روی گیت‌هاب هم هست: <code>arena/4345765d-label-printer</code> → Code → Download ZIP</small></p>
</div></body></html>"""
            return self.send_bytes(200, page.encode("utf-8"), "text/html; charset=utf-8")
        if path == "/status":
            return self.send_json({"ok": True, "text": "آماده (شبیهساز، پرینتر واقعی نیست)",
                                   "status": "Normal", "jobs": 0})
        if path == "/config":
            return self.send_json(CONFIG)
        if path == "/designer":
            f = next(ROOT.glob("*.html"), None)
            if not f:
                return self.send_bytes(404, b"designer html not found")
            return self.send_bytes(200, f.read_bytes(), MIME[".html"])
        if path == "/manager-preview":
            f = ROOT / "app" / "preview.html"
            if not f.is_file():
                return self.send_bytes(404, b"manager preview not found")
            return self.send_bytes(200, f.read_bytes(), MIME[".html"])
        if path in ("/", "/index.html"):
            return self.send_bytes(200, (WEB / "index.html").read_bytes(), MIME[".html"])
        rel = unquote(path).lstrip("/")
        f = (WEB / rel).resolve()
        if not str(f).startswith(str(WEB.resolve()) + "/") or not f.is_file() or f.suffix not in MIME:
            return self.send_bytes(404, b"Not found")
        return self.send_bytes(200, f.read_bytes(), MIME[f.suffix])

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/print":
            return self.send_bytes(404, b"Not found")
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n).decode("utf-8"))
            qty = max(1, min(50, int(body.get("qty", 1))))
            png = re.sub(r"^data:image/\w+;base64,", "", str(body.get("png", "")))
            raw = base64.b64decode(png, validate=True)
            if not raw.startswith(b"\x89PNG"):
                raise ValueError("داده‌ی PNG معتبر نیست")
            name = OUT / f"label-{datetime.now():%Y%m%d-%H%M%S}.png"
            name.write_bytes(raw)
            self.log_message("MOCK PRINT x%s  patient=%r  png=%d bytes  -> %s",
                             qty, body.get("pat", ""), len(raw), name)
            return self.send_json({"ok": True, "qty": qty})
        except Exception as e:  # همان الگوی پاسخ 500 در server.ps1
            self.log_message("PRINT ERROR: %s", e)
            return self.send_json({"ok": False, "error": str(e)}, 500)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    a = ap.parse_args()
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    print(f"شبیهساز لیبل سرور: http://{a.host}:{a.port}   (وب: {WEB})", flush=True)
    print(f"خروجی چاپهای تست: {OUT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
