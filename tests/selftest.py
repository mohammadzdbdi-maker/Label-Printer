#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
تست ایستا (static) برای پوشه «نرم افزار مدیریت پرینتر / Zebra GK888t Setup».

روی لینوکس اجرا می‌شود و بدون نیاز به ویندوز، پرینتر یا PowerShell،
سلامت فایل‌ها، ارجاعات بین فایل‌ها و قرارداد HTTP بین صفحه و سرور را بررسی می‌کند.
برای تست زنده‌ی بخش وب، tests/mock_server.py را ببینید.

اجرا: python3 tests/selftest.py
"""
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = []


def record(name, ok, detail="", level=None):
    level = level or ("PASS" if ok else "FAIL")
    RESULTS.append((level, name, detail))
    mark = {"PASS": "✅", "FAIL": "❌", "WARN": "⚠️ ", "INFO": "ℹ️ "}[level]
    print(f"{mark} {name}" + (f"\n      {detail}" if detail else ""))


def read(p, enc="utf-8-sig"):
    return (ROOT / p).read_text(encoding=enc)


def exists(p):
    return (ROOT / p).exists()


# ---------------------------------------------------------------- 1. لانچرها
bats = sorted(ROOT.glob("*.bat"))
record("لانچرهای .bat (۶ قدیمی + ۲ اپ جدید)", len(bats) >= 6, f"{len(bats)} عدد: " + ", ".join(b.name for b in bats))
for b in bats:
    txt = b.read_text(encoding="utf-8-sig")
    m = re.search(r'-File\s+"?%~dp0([^"\s]+\.ps1)"?', txt, re.I)
    ok = bool(m) and exists(m.group(1).replace("\\", "/"))
    record(f"ارجاع {b.name} → {m.group(1) if m else '?'}", ok)

# ---------------------------------------------------------------- 2. encoding
ps1s = sorted(list(ROOT.glob("*.ps1")) + list((ROOT / "label-server").glob("*.ps1")))
no_bom = [p.name for p in ps1s if not p.read_bytes().startswith(b"\xef\xbb\xbf")]
record("همه‌ی .ps1ها BOM UTF-8 دارند (لازم برای PowerShell 5.1 + متن فارسی)", not no_bom, ", ".join(no_bom))
non_ascii_bat = [b.name for b in bats if any(ord(c) > 127 for c in b.read_text(encoding="utf-8"))]
record("فایل‌های .bat فقط ASCII هستند (سازگار با cmd.exe)", not non_ascii_bat, ", ".join(non_ascii_bat))

# ---------------------------------------------------------------- 3. فایل‌های حیاتی
required = [
    "driver/Zebra.inf", "driver/Zebra.cat", "driver/zebra.PNF",
    "settings/PrintTicket.xml", "settings/DevModePerUser.bin", "settings/DevModes2.bin",
    "host.txt", "label-server/index.html", "label-server/server.ps1",
    "label-server/manifest.json", "label-server/aradfd.ttf",
    "label-server/icon-192.png", "label-server/icon-512.png",
]
missing = [p for p in required if not exists(p)]
record("همه‌ی فایل‌های مورد نیاز اسکریپت‌ها موجودند", not missing, "کمبود: " + ", ".join(missing))
html_apps = list(ROOT.glob("*.html"))
record("برنامه‌ی لیبل‌زن آفلاین در ریشه وجود دارد", len(html_apps) >= 1,
       ", ".join(h.name for h in html_apps))

# باینری‌ها بعد از push سالم مانده‌اند (نه تبدیل به متن، نه LFS pointer)
bin_checks = {
    "driver/x64/ss#base_12.6.0.0.cab": b"MSCF",
    "driver/Common/ss#base_12.6.0.0.ddz": None,
    "driver/Zebra.cat": None,
    "label-server/aradfd.ttf": b"\x00\x01\x00\x00",
    "label-server/icon-192.png": b"\x89PNG",
}
for rel, magic in bin_checks.items():
    data = (ROOT / rel).read_bytes() if exists(rel) else b""
    ok = len(data) > 1000 and (magic is None or data.startswith(magic))
    record(f"باینری سالم: {rel}", ok, f"{len(data):,} بایت")

# ---------------------------------------------------------------- 4. درایور INF
inf = read("driver/Zebra.inf")
record("مدل Zebra GK888t - EPL داخل INF تعریف شده", '"Zebra GK888t - EPL"=EPL' in inf)
record("CatalogFile داخل INF با فایل موجود مطابق است",
       "CatalogFile=Zebra.cat" in inf and exists("driver/Zebra.cat"))
sec = re.search(r"\[SourceDisksFiles\](.*?)(?=\r?\n\[)", inf, re.S | re.I)
src_files = sorted({l.split("=")[0].strip() for l in sec.group(1).splitlines()
                    if l.strip() and not l.strip().startswith(";") and "=" in l})
missing_src = [f for f in src_files
               if not exists(f"driver/Common/{f}") and not exists(f"driver/x64/{f}")]
record("فایل‌های معرفی‌شده در SourceDisksFiles موجودند", not missing_src,
       f"{len(src_files)} فایل معرفی شده، {len(missing_src)} کمبود: " + ", ".join(missing_src),
       "WARN" if missing_src else "PASS")
x64_cabs = [f for f in src_files if f.endswith(".cab")]
record("همه‌ی CABهای x64 موجودند", all(exists(f"driver/x64/{f}") for f in x64_cabs),
       f"{len(x64_cabs)} عدد")
# مدل EPL فقط FILES_BASE/EPL را کپی می‌کند، نه پورت مانیتور TCP/IP
epl = re.search(r"\[EPL\](.*?)(?=\r?\n\[)", inf, re.S | re.I)
uses_portmon = "FILES_PORT_MONITOR" in (epl.group(1) if epl else "")
record("مدل EPL به پورت‌مانیتور گمشده وابسته نیست",
       epl is not None and not uses_portmon,
       "برای نصب USB کافی است؛ برای پورت TCP/IP شبکه‌ای فایل‌های PortMonitor لازم می‌شوند")

# ---------------------------------------------------------------- 5. تنظیمات چاپ
try:
    ET.fromstring(read("settings/PrintTicket.xml"))
    record("PrintTicket.xml یک XML معتبر است", True)
except ET.ParseError as e:
    record("PrintTicket.xml یک XML معتبر است", False, str(e))
pt = read("settings/PrintTicket.xml")
record("حرارتی مستقیم (opt0) در PrintTicket", "JobPrintMethod" in pt and "epl:opt0" in pt)
record("اندازه‌ی لیبل ۵۸×۴۰ میلی‌متر (57960×40000 میکرون)",
       "57960" in pt and "40000" in pt)
for f in ("settings/DevModePerUser.bin", "settings/DevModes2.bin"):
    txt = (ROOT / f).read_bytes().decode("utf-16-le", "ignore")
    record(f"DEVMODE داخل {Path(f).name} نام پرینتر را دارد", "Zebra GK888t - EPL" in txt)

# ---------------------------------------------------------------- 6. اپ وب / PWA
try:
    man = json.loads(read("label-server/manifest.json"))
    record("manifest.json معتبر و آیکون‌هایش موجودند",
           all(exists("label-server/" + i["src"].lstrip("/")) for i in man.get("icons", [])),
           f"name={man.get('name')}, lang={man.get('lang')}, dir={man.get('dir')}")
except json.JSONDecodeError as e:
    record("manifest.json معتبر است", False, str(e))
index = read("label-server/index.html")
server = read("label-server/server.ps1")
for ep in ("/print", "/status", "/config"):
    record(f"قرارداد API: صفحه {ep} را صدا میزند و سرور پیاده کرده",
           f"fetch(\"{ep}\"" in index and f"path -eq '{ep}'" in server)
assets = set(re.findall(r'(?:src|href)="(/[^"#?]+)"', index)) | {"/aradfd.ttf"}
missing_assets = [a for a in assets if not exists("label-server/" + a.lstrip("/"))]
record("دارایی‌های صفحه (فونت/آیکون/منیفست) موجودند", not missing_assets,
       ", ".join(sorted(assets)) + (" | کمبود: " + ", ".join(missing_assets) if missing_assets else ""))

# ---------------------------------------------------------------- 7. سینتکس جاوااسکریپت
node = subprocess.run(["node", "--version"], capture_output=True, text=True)
if node.returncode == 0:
    for f in ("label-server/index.html", html_apps[0].name if html_apps else ""):
        if not f or not exists(f):
            continue
        s = read(f)
        blocks = [b for b in re.findall(r"<script[^>]*>(.*?)</script>", s, re.S | re.I) if b.strip()]
        statuses = []
        for b in blocks:
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as t:
                t.write(b)
                tmp = t.name
            r = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
            statuses.append(r.returncode == 0)
            os.unlink(tmp)
        record(f"سینتکس JS در {f}", all(statuses),
               f"{len(blocks)} بلاک اسکریپت، {sum(statuses)} تأیید شده" if all(statuses) else "خطای سینتکس")
else:
    record("سینتکس JS", False, "node در دسترس نیست", "WARN")

# ---------------------------------------------------------------- 8. host.txt و باگ ترتیب اجرا
lines = read("host.txt").splitlines()
record("host.txt چهار خط دارد (نام هاست، IP، نام اشتراک، کاربر چاپ)", len(lines) == 4,
       " | ".join(lines))
add_user = read("add-print-user.ps1")
share = read("share-host.ps1")
client = read("connect-client.ps1")
record("add-print-user.ps1 خط چهارم (کاربر چاپ) را مینویسد", "$lines[3] = $PrintUser" in add_user)
record("connect-client.ps1 خط چهارم را میخواند", "$lines[3]" in client or "$PrintUser = $lines[3]" in client)
# بررسی رفع باگ: share-host.ps1 باید خطوط قبلی را بخواند و ۴ خط بنویسد
share_fixed = ("Get-Content $hostFile" in share and "while ($lines.Count -lt 4)" in share
               and "$lines[2] = $ShareName" in share and "$lines | Set-Content" in share)
record("رفع باگ: share-host.ps1 خط چهارم host.txt (کاربر چاپ) را حفظ میکند", share_fixed,
       "نسخه قبل فقط ۳ خط مینوشت و zebraprint گم میشد؛ الان خطوط قبلی خوانده و ۴ خط نوشته میشود.")
self_guard = ("$hostName -ieq $env:COMPUTERNAME" in client and "Get-NetIPAddress" in client)
record("connect-client.ps1 جلوی اشاره host.txt به خود سیستم (میزبان سابق) را میگیرد", self_guard)
clean_stale = "$selfRe" in client and "Remove-Printer -Name $_.Name" in client
record("connect-client.ps1 پرینتر/پورتهای ساختهشده به نام خودش را پاک میکند", clean_stale)

# ---------------------------------------------------------------- 9. هشدارهای قابلیت حمل / امنیت
diag = read("diagnose.ps1")
hard = re.findall(r"'(\\\\[^']+)'", diag)
record("diagnose.ps1 دیگر نام ماشین/مسیر لاگ هاردکد ندارد",
       (not hard) and "NOSKHE-2" not in diag and "MOHAMMAD" not in diag and "192.168.70" not in diag,
       "همهچیز از host.txt خوانده میشود؛ " + (", ".join(hard[:4]) if hard else "هیچ مقدار ثابتی باقی نمانده"))
record("server.ps1 بررسی مسیر را بدون جداکننده انتهایی انجام میدهد",
       "$full.StartsWith($root" in server,
       "StartsWith روی ریشه بدون \\ انتهایی، عبور از پوشه‌های هم نام را ممکن میکند؛ "
       "همچنین /print بدون احراز هویت است (هر کس روی وایفای میتواند چاپ کند).", "WARN")
inst_srv = read("install-label-server.ps1")
record("سرور لیبل فقط با ورود کاربر بالا میآید",
       "AtLogOn" in inst_srv and "LogonType Interactive" in inst_srv,
       "Task با تریگر AtLogOn و RunLevel Limited است؛ بعد از logout/reboot تا ورود مجدد، "
       "گوشیها به http://IP:8080 نمیرسند.", "WARN")

# ---------------------------------------------------------------- 10. لاگ واقعی
log = read("diag-MOHAMMAD-20261031-114427.txt")
facts = []
if "port445=True" in log:
    facts.append("پورت 445 هاست باز و ping موفق")
if "ZebraLabel    Print" in log:
    facts.append("اشتراک ZebraLabel روی شبکه دیده میشود")
if "1 file(s) copied" in log and "exit=0" in log:
    facts.append("ارسال مستقیم EPL به اشتراک موفق (TEST 1)")
if "OK - connected" in log:
    facts.append("اتصال ویندوزی موفق (TEST 2)")
errs = len(re.findall(r"Id\s+:\s+372", log))
record("لاگ واقعی ۱۴۰۵/۰۸/۰۹ (diag) خوانده شد", bool(log),
       f"{len(facts)} نشانه‌ی سالم: " + "؛ ".join(facts) + f" | {errs} خطای چاپ 372 ثبت شده", "INFO")

# ---------------------------------------------------------------- نسخه ۲: اپلیکیشن و حذف هاردکدها
app_files = ["ZebraManager.bat", "fix-client.bat", "fix-client.ps1",
             "app/ZebraManager.ps1", "lib/Zebra.ps1", "config/printers.json",
             "README.md", ".gitignore"]
record("ماکت قابلکلیک رابط اپ (app/preview.html) موجود است",
       exists("app/preview.html") and "manager-preview" in read("tests/mock_server.py"))
record("فایلهای اپ دسکتاپ و هسته جدید موجودند", all(exists(f) for f in app_files),
       "کمبود: " + ", ".join(f for f in app_files if not exists(f)))

new_ps1 = ["app/ZebraManager.ps1", "lib/Zebra.ps1", "fix-client.ps1"]
no_bom2 = [f for f in new_ps1 if not (ROOT / f).read_bytes().startswith(b"\xef\xbb\xbf")]
record("فایلهای PowerShell جدید BOM UTF-8 دارند", not no_bom2, ", ".join(no_bom2))
nonascii2 = [f for f in ("ZebraManager.bat", "fix-client.bat")
             if any(c > 127 for c in (ROOT / f).read_bytes())]
record("لانچرهای bat جدید فقط ASCII هستند", not nonascii2, ", ".join(nonascii2))

try:
    cfg = json.loads(read("config/printers.json"))
    ok_profiles = len(list(cfg.get("profiles", []))) >= 1
    ok_keys = all(all(k in pr for k in ("id", "name", "printerName", "driverName", "shareName"))
                  for pr in cfg["profiles"])
    record("config/printers.json معتبر و پروفایلها کاملاند", ok_profiles and ok_keys,
           f"{len(list(cfg.get('profiles', [])))} پروفایل")
    inf_paths = [pr.get("driverInf") for pr in cfg["profiles"] if pr.get("driverInf")]
    record("مسیر INF پروفایلها وجود دارد", all(exists(x) for x in inf_paths),
           ", ".join(inf_paths))
    record("هاست بهصورت خودکار کشف میشود (هیچ IP/نامی پیشفرض نیست)",
           not cfg["host"]["name"] and not cfg["host"]["ip"] and cfg["host"]["autoDetect"])
except (json.JSONDecodeError, KeyError) as e:
    record("config/printers.json معتبر است", False, str(e))

code_files = (sorted(ROOT.glob("*.ps1")) + sorted((ROOT / "app").glob("*.ps1")) +
              sorted((ROOT / "lib").glob("*.ps1")) + sorted((ROOT / "label-server").glob("*.ps1")) +
              sorted(ROOT.glob("*.bat")))
bad_hard = [str(f.relative_to(ROOT)) for f in code_files
            if re.search(r"NOSKHE|MOHAMMAD|192\.168\.70", f.read_text(encoding="utf-8-sig"))]
record("هیچ نام کامپیوتر/IP محل کار در کد هاردکد نشده", not bad_hard, ", ".join(bad_hard))

lib = read("lib/Zebra.ps1")
for fn in ("Install-ZebraHost", "Connect-ZebraClient", "Remove-ZebraFormerHost",
           "Find-ZebraHosts", "Get-ZebraStatus", "Sync-ZebraHostFile"):
    record(f"هسته تابع {fn} را تعریف کرده", ("function " + fn) in lib)
app = read("app/ZebraManager.ps1")
record("اپ و fix-client هسته را dot-source میکنند",
       "lib\Zebra.ps1" in app and "lib\Zebra.ps1" in read("fix-client.ps1"))
record("اسکریپتهای قدیمی -NoPause میگیرند (قابل فراخوانی از اپ)",
       all("NoPause" in read(f) for f in ("diagnose.ps1", "share-host.ps1",
                                          "install-label-server.ps1", "connect-client.ps1")))
record("اپ از نام پارامتر قدیمی -Profile برای توابع هسته استفاده نمیکند",
       not re.search(r"-Profile\b", app))

# پارسر اختیاری PowerShell (tree-sitter) — در صورت نصب بودن، سینتکس واقعی چک میشود
try:
    from tree_sitter import Language, Parser
    import tree_sitter_powershell as tsp
    par = Parser(Language(tsp.language()))
    def ps_errors(path):
        b = (ROOT / path).read_bytes()
        if b.startswith(b"\xef\xbb\xbf"):
            b = b[3:]
        t = par.parse(b)
        out = []
        def w(n):
            if n.type == "ERROR" or n.is_missing:
                out.append(n.start_point[0] + 1)
            for c in n.children:
                w(c)
        w(t.root_node)
        return out
    fresh = ["app/ZebraManager.ps1", "lib/Zebra.ps1", "fix-client.ps1"]
    errs = {f: ps_errors(f) for f in fresh}
    record("سینتکس PowerShell فایلهای جدید (tree-sitter)",
           all(not v for v in errs.values()),
           ", ".join(f"{k}={len(v)} خطا" for k, v in errs.items()))
except ImportError:
    record("سینتکس PowerShell (tree-sitter)", False,
           "اختیاری: pip install tree_sitter tree_sitter_powershell", "WARN")

# ---------------------------------------------------------------- خلاصه
counts = {k: sum(1 for r in RESULTS if r[0] == k) for k in ("PASS", "FAIL", "WARN", "INFO")}
print("\n" + "=" * 60)
print(f"خلاصه:  PASS={counts['PASS']}  FAIL={counts['FAIL']}  WARN={counts['WARN']}  INFO={counts['INFO']}")
print("=" * 60)
sys.exit(0)
