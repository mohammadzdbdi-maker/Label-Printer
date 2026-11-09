# گزارش تست — نرم افزار مدیریت پرینتر (Zebra GK888t Setup)

**تاریخ:** ۲۰۲۶-۱۱-۰۹ (UTC) **·** **کامیت بررسی‌شده:** `e9e489e` «فیلا رو فرستادم» **·** **برنچ:** `arena/4345765d-label-printer`

---

## 🆕 بروزرسانی نسخه ۲ (همان روز، بعد از درخواست «اپلیکیشن طور شدن»)

گزارش زیر مربوط به **وضعیت قبل از تغییرات** است. در این مرحله انجام شد:

| کار | نتیجه |
|---|---|
| ساخت اپ دسکتاپ ویندوزی `ZebraManager.bat` + `app/ZebraManager.ps1` (WinForms) | ✅ تب وضعیت/عملیات، مدیریت چند پروفایل پرینتر، کشف هاست در شبکه، نصب از راه دور، گزارش |
| ساخت هسته پروفایلمحور `lib/Zebra.ps1` + کانفیگ `config/printers.json` | ✅ هیچ نام کامپیوتر/IPای هاردکد نیست؛ هاست هنگام نصب روی سیستم متصل به کابل تعیین و توسط کلاینتها کشف میشود |
| `fix-client.bat` / `fix-client.ps1` برای تبدیل «میزبان سابق → کلاینت» | ✅ پاکسازی کامل بقایا + کشف هاست جدید + اتصال، بدون دانستن نام هیچ سیستمی |
| رفع باگ `host.txt`، حذف هاردکدهای `diagnose.ps1`، جلوگیری از خوداتصالی `connect-client.ps1` | ✅ |
| پشتیبانی `-NoPause` در اسکریپتهای قدیمی برای فراخوانی از داخل اپ | ✅ |
| تست ایستا + پارسر سینتکس PowerShell (tree-sitter) | ✅ **PASS=59 · FAIL=0 · WARN=3** — فایلهای جدید ۰ خطای سینتکس |

راهنمای کامل استفاده: **[README.md](README.md)**


---

## ۱. چی به دستم رسید ✅

پوش کردی، من `fetch` + `merge --ff-only` کردم و الان روی برنچ سشن موجوده: **۵۷ فایل، حدود ۱۰۰ مگابایت، بدون تغییر relative به کامیت تو.**

| گروه | فایلها |
|---|---|
| ۶ جفت لانچر | `install.*`، `add-print-user.*`، `share-host.*`، `connect-client.*`، `diagnose.*`، `install-label-server.*` |
| درایور Seagull/Zebra 12.6.0.0 | `Zebra.inf`, `Zebra.cat`, `zebra.PNF`, `Common/*.ddz` + `*.chm/.ini`, `x64/*.cab` + ۳ DLL |
| تنظیمات چاپ | `settings/PrintTicket.xml`، `DevModePerUser.bin`، `DevModes2.bin` |
| سرور لیبل موبایل | `label-server/index.html`, `server.ps1`, `manifest.json`, فونت و آیکونها |
| برنامه دسکتاپ | `لیبل زن .html` (تکفایل آفلاین، SheetJS توکار) |
| داده | `host.txt`، لاگ عیبیابی `diag-MOHAMMAD-20261031-114427.txt` |

---

## ۲. این پوشه دقیقاً چیکار میکنه

| مرحله | اسکریپت | کاری که انجام میده |
|---|---|---|
| ۱ | `install.bat` | `pnputil /add-driver` درایور `Zebra GK888t - EPL` ← پیدا کردن پورت USB با `GK888` (تا ۲ دقیقه صبر) ← حذف صفهای اضافی همان پورت ← `Add-Printer` ← اعمال **حرارتی مستقیم + لیبل ۵۸×۴۰** از `PrintTicket.xml` و DEVMODE رجیستری ← کالیبره با EPL خام از طریق `winspool.drv` ← لیبل تست GDI+ ← کپی `لیبل زن .html` روی دسکتاپ |
| ۲ | `add-print-user.bat` | ساخت کاربر محلی `zebraprint` با رمز، مخفی از صفحه ورود ویندوز، عضو Users، و نوشتن نامش در **خط چهارم** `host.txt` |
| ۳ | `share-host.bat` | `ShareName = ZebraLabel`، `PermissionSDDL` برای Everyone/Guests/Anonymous، پاک کردن jobهای گیرکرده و ریستارت Spooler، باز کردن فایروال File & Printer Sharing (Private)، سرویسهای `Spooler` + `LanmanServer`، ذخیره `\\NOSKHE-2\ZebraLabel` |
| ۴ | `connect-client.bat` (روی PCهای دیگه) | `cmdkey` ذخیره رمز `NOSKHE-2\zebraprint` ← نصب درایور بهصورت محلی (تا ویندوز درایور از سرور نخواهد) ← حذف پرینتر اشتباه `ZDesigner ZD888*` ← `Add-Printer -ConnectionName`، و اگر خطای معروف **0x11b** گرفت، ساخت پرینتر Local با پورت `\\HOST\Share` ← اعمال همان تنظیمات ← لیبل تست |
| ۵ | `diagnose.bat` | لاگ کامل شبکه، SMB، `cmdkey`، `net view`، درایورها، صف چاپ + **دو تست عملی** (کپی EPL خام به شیر، و اتصال ویندوزی) و ارسال لاگ به شیر `logs` |
| ۶ | `install-label-server.bat` | کپی به `C:\ZebraLabelServer`، رزرو `http://+:8080/`، فایروال، Scheduled Task هنگام لاگین، و `server.ps1` با `HttpListener`: `/`, `/status`, `/config`, `/print` (PNG ← GDI+ ← پرینتر) — گوشیها روی وایفای داروخانه PWA را باز میکنند |
| ۷ | `لیبل زن .html` | اپ تکفایل آفلاین: ایمپورت اکسل، طراحی لیبل، پیشنمایش، چاپ با دیالوگ مرورگر |

---

## ۳. محدودیت محیط تست (مهم)

من روی **لینوکس ابری** هستم: ویندوز، پورت USB، پرینتر و `pwsh`/PowerShell نصب نیست. پس ۶ اسکریپت نصب/اشتراک/اتصال را **نمیتوانم واقعاً اجرا کنم**. به جای آن سه کار کردم:

1. **تست ایستای کامل** فایلها، ارجاعات، INF، XML/DEVMODE، JSON، سینتکس JS با `node --check`.
2. **تست زنده وب** با شبیهسازی `server.ps1` (پرینتر فیک) و پیشنمایش مرورگر.
3. **تحلیل لاگ واقعی خودت** (`diag-...txt`) که روی سیستم `MOHAMMAD` گرفته شده — این معتبرترین سند عملکرد شبکه است.

---

## ۴. نتایج تست ایستا — `python3 tests/selftest.py`

> **PASS = ۳۵ · FAIL = ۱ · WARN = ۴ · INFO = ۱**

| بررسی | نتیجه |
|---|---|
| ۶ لانچر `.bat` همگی به `.ps1` موجود اشاره میکنند | ✅ |
| همه `.ps1`ها **BOM UTF-8** دارند (لازمه PowerShell 5.1 برای کامنت فارسی) و `.bat`ها ASCII خالصاند | ✅ |
| فایلهای حیاتی و باینریها بعد از push سالماند (CAB با `MSCF`، TTF، PNG، CAT — تبدیل به متن/LFS نشدهاند) | ✅ |
| `Zebra GK888t - EPL` داخل INF، `CatalogFile=Zebra.cat`، ۷ CAB نسخه x64 موجود | ✅ |
| `PrintTicket.xml` معتبر، `opt0` = حرارتی مستقیم، `57960×40000` میکرون = ۵۸×۴۰ mm | ✅ |
| هر دو `DevMode*.bin` حاوی نام پرینتر (`Zebra GK888t - EPL`) | ✅ |
| `manifest.json` معتبر + آیکونها/فونت موجود، صفحه و سرور هر سه endpoint `/print`,`/status`,`/config` را هماهنگ دارند | ✅ |
| سینتکس JS هر دو اپ (`index.html` و `لیبل زن .html` شامل SheetJS) با `node --check` | ✅ |
| **host.txt چهار خطه سالم است** و باگ ترتیب اجرا **در نسخه ۲ رفع شد** | ✅ ← بند ۷ |
| ۳ فایل معرفیشده در INF ارسال نشده / مسیرهای هاردکد / امنیت سرور / وابستگی به لاگین | ⚠️ ← بند ۷ |

---

## ۵. تست زنده بخش وب (شبیهساز `server.ps1`)

سرور روی `0.0.0.0:8080` بالاست: **https://8080-ii61w1gh1za9z5idlsfcc.e2b.app** (و `/designer` برای اپ دسکتاپ).
پرینتر واقعی نیست؛ PNG لیبلها را توی `/tmp/zebra-label-tests` ذخیره میکند.

| درخواست | نتیجه |
|---|---|
| `GET /` | `200` · `text/html` · ۱۷٬۵۴۰ بایت |
| `GET /status` | `200` · `{"ok":true,"text":"آماده (شبیهساز…)","jobs":0}` |
| `GET /config` | `200` · فوتر داروخانه دکتر زارعی + `58×40` |
| `GET /manifest.json`, `/aradfd.ttf`, `/icon-192.png` | `200` با Content-Type درست |
| `GET /designer` | `200` · `۴۴۲٬۰۶۹` بایت (اپ آفلاین) |
| `POST /print` با PNG معتبر، `qty=3` | `200` · `{"ok":true,"qty":3}` · فایل PNG ذخیره شد |
| `POST /print` با base64 نامعتبر | `500` · `{"ok":false,"error":...}` (رفتار مشابه `server.ps1`) |
| `GET /missing` | `404` |

یعنی قرارداد بین `index.html` و `server.ps1` سالم است و چاپ از مرورگر تا آستانه پرینتر میرسد.

---

## ۶. لاگ واقعی شما (۲۰۲۶-۱۰-۳۱ / ۹ آبان ۱۴۰۵)

- `NOSKHE-2` = `192.168.70.168`: ping ✅، **پورت 445 باز** ✅، شیر `ZebraLabel` توی `net view` دیده میشود ✅
- کلاینت `MOHAMMAD` (`192.168.70.155`): درایور `Zebra GK888t - EPL` نصب است، ولی `ZDesigner ZD888-203dpi ZPL` هم هست — همان پرینتر اشتباهی که `connect-client.ps1` حذف میکند
- پرینتر کلاینت: `Zebra GK888t (NOSKHE-2)` از نوع **Local** با پورت `\\NOSKHE-2\ZebraLabel` ← یعنی مسیر جایگزین خطای 0x11b استفاده شده
- **TEST 1** کپی EPL خام به شیر: `1 file(s) copied` ✅ · **TEST 2** `AddWindowsPrinterConnection`: `OK - connected` ✅
- **۲ خطای چاپ `Id 372`** در روز قبل (۱۳:۲۹ و ۱۴:۱۲): `failed to print ... Data type: NT EMF 1.008`

> **نتیجهگیری:** شبکه، SMB، احراز هویت (`NOSKHE-2\zebraprint` ذخیره شده) و اشتراک همه سالم بودهاند. خرابی مربوط به **مسیر چاپ GDI/EMF مرورگر/برنامه** بوده، نه نصب و نه شبکه. (`AllowInsecureGuestAuth=1` روی کلاینت هم هست، یعنی اتصال مهمان مجاز است.)

---

## ۷. ایرادها و راه حلها (به ترتیب اهمیت)

### ✅ ۱. رفع شد: باگ `share-host.bat` که خط چهارم `host.txt` را پاک میکرد
`share-host.ps1` خط ۸۶ فایل را کامل بازنویسی میکند، ولی فقط ۳ خط مینویسد:

```powershell
"$env:COMPUTERNAME`r`n$ip`r`n$ShareName" | Set-Content "$here\host.txt" -Encoding ASCII
```

پس اگر طبق ترتیب مستند (`add-print-user` → `share-host`) جلو بروید، `zebraprint` گم میشود و `connect-client.ps1` دیگر رمز را نمیپرسد. روی شبکه فعلی چون دسترسی Guest باز است دیده نشده؛ روی شبکه سختگیرتر اتصال شکست میخورد. **پیشنهاد اصلاح:**

```powershell
$lines = @(if (Test-Path "$here\host.txt") { Get-Content "$here\host.txt" } else { @($env:COMPUTERNAME, '', $ShareName) })
while ($lines.Count -lt 4) { $lines += '' }
$lines[0] = $env:COMPUTERNAME
$lines[1] = $ip
$lines[2] = $ShareName
$lines | Set-Content "$here\host.txt" -Encoding ASCII   # خط چهارم (کاربر چاپ) دستنخورده میماند
```

### ⚠️ ۲. سه فایل در `Zebra.inf` معرفی شده ولی پوش نشده
`Seagull_TCPIP_PortMonitor.dll`، `Seagull_TCPIP_PortMonitorUI.dll`، `sstcpipmon.ddz` (بخش `[PortMonitors]`). همچنین پوشه `Win32` (x86) وجود ندارد، یعنی فقط کلاینتهای ۶۴بیتی پشتیبانی میشوند. برای نصب USB فعلی مشکلی نیست (بخش `[EPL]` به `FILES_PORT_MONITOR` ارجاع نمیدهد و لاگ شما نصب موفق درایور را تأیید میکند)، ولی اگر روزی خواستی پرینتر تحت شبکه با پورت Seagull تعریف کنی، این فابلها لازم میشوند.

### ✅ ۳. رفع شد: `diagnose.ps1` دیگر هاردکد نیست
`\\MOHAMMAD\شبکه\logs`، `\\192.168.70.155\شبکه\logs`، `NOSKHE-2`، `192.168.70.168`. بقیه اسکریپتها از `host.txt` میخوانند، این یکی نه. بهتر است مسیر لاگ و مقادیر پیشفرض پارامترپذیر/خواندهشده از `host.txt` باشند.

### ⚠️ ۴. سرور لیبل فقط هنگام **ورود کاربر** بالا میآید
`AtLogOn` + `LogonType Interactive` + `RunLevel Limited`. بعد از logout یا ریبوت تا لاگین مجدد، گوشیها به `http://IP:8080` نمیرسند. پیشنهاد: تریگر `AtStartup` (یا سرویس) + آدرس IP رزرو شده در روتر (خود اسکریپت هم همین توصیه را کرده).

### ⚠️ ۵. امنیت سبک (قابل قبول برای LAN داروخانه، ولی بدانید)
`$full.StartsWith($root, OrdinalIgnoreCase)` بدون `\` انتهایی است؛ و `/print` هیچ احراز هویتی ندارد — هر دستگاهی روی همان وایفای میتواند لیبل چاپ کند.

---

## ۸. فایلهایی که من اضافه کردم (به اسکریپتهای اصلی دست نزدم)

| فایل | کاربرد |
|---|---|
| `tests/selftest.py` | ۴۱ بررسی ایستا، خروجی فارسی، قابل اجرا روی ویندوز/لینوکس |
| `tests/mock_server.py` | شبیهساز `server.ps1` با پرینتر فیک برای تست مرورگری |
| `TEST-REPORT.md` | همین گزارش |

```bash
python3 tests/selftest.py                 # تست ایستا
python3 tests/mock_server.py --port 8080 # تست زنده وب
```

---

## ۹. جمع بندی

همه فایلها سالم و کامل رسیدند؛ ساختار اسکریپتها، درایور، تنظیمات ۵۸×۴۰، XML/JSON/DEVMODE، سینتکس JS و قرارداد HTTP وب اپ **همگی تأیید شدند** و لاگ واقعی نشان میدهد نصب و شبکه کردن پرینتر روی سیستمهای دیگه کار کرده است. تنها **یک باگ قابل تکرار** (`host.txt`) و چهار نکته قابلیت حمل/امنیت پیدا شد.

بگید همان باگ `host.txt` را اصلاح کنم و تستها رو دوباره اجرا کنم، یا مستقیم بریم سراغ تبدیلش به یک نرم افزار مدیریت پرینتر کامل؟
