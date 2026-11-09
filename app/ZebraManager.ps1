# -*- coding: utf-8 -*-
# نرم افزار مدیریت پرینتر — رابط دسکتاپ ویندوزی (WinForms / PowerShell 5.1)
# فقط کافیست «مدیریت پرینتر.bat» را اجرا کنید؛ خودش دسترسی ادمین میگیرد.
# هیچ نام کامپیوتر یا IPای در کد هاردکد نشده است.
#
# حالت خط فرمان (برای نصب از راه دور / اسکریپتها):
#   powershell -File app\ZebraManager.ps1 -NoGui -InstallHost
#   powershell -File app\ZebraManager.ps1 -NoGui -CleanFormerHost -ConnectClient

param(
  [switch]$NoGui,
  [switch]$InstallHost,
  [switch]$ConnectClient,
  [switch]$CleanFormerHost,
  [switch]$DiagnoseOnly,
  [switch]$DiscoverOnly,
  [switch]$NoPause,
  [switch]$NoElevate,
  [string]$ProfileId,
  [string]$TargetHost
)

$ErrorActionPreference = 'Stop'
$ZebraRootOverride = Split-Path -Parent $PSScriptRoot
. (Join-Path $ZebraRootOverride 'lib\Zebra.ps1')

$script:cfg = Initialize-Zebra
if (-not $ProfileId) { $ProfileId = [string]$script:cfg.defaultProfileId }
$script:activeProfile = Get-ZebraProfile $script:cfg $ProfileId
$script:hosts = @()

# ---------------------------------------------------------------- بالا آوردن دسترسی ادمین
if (-not (Test-ZebraAdmin)) {
  if ($NoElevate) { throw 'این عملیات نیاز به دسترسی Administrator دارد.' }
  $quoted = '"' + $MyInvocation.MyCommand.Path + '"'
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quoted, '-NoElevate')
  foreach ($sw in 'NoGui', 'InstallHost', 'ConnectClient', 'CleanFormerHost', 'DiagnoseOnly', 'DiscoverOnly', 'NoPause') {
    if ((Get-Variable -Name $sw).Value) { $a += ('-' + $sw) }
  }
  if ($ProfileId) { $a += '-ProfileId'; $a += $ProfileId }
  if ($TargetHost) { $a += '-TargetHost'; $a += $TargetHost }
  Start-Process powershell -Verb RunAs -ArgumentList $a
  exit
}

# ---------------------------------------------------------------- حالت بدون رابط (CLI)
if ($NoGui) {
  Write-ZebraLog "==== حالت خط فرمان | پروفایل: $($script:activeProfile.id) ====" 'OK'
  if ($DiscoverOnly) {
    Find-ZebraHosts $script:cfg | Format-Table -AutoSize | Out-String | Write-Host
  }
  if ($CleanFormerHost) {
    Remove-ZebraFormerHost -Cfg $script:cfg -ZProfile $script:activeProfile `
      -Mode ([string]$script:cfg.cleanup.mode) | Out-Null
  }
  if ($InstallHost) {
    $null = Install-ZebraHost $script:cfg $script:activeProfile
  }
  if ($ConnectClient) {
    $null = Connect-ZebraClient $script:cfg $script:activeProfile -Target $TargetHost
  }
  if ($DiagnoseOnly) {
    $f = Invoke-ZebraDiagnose $script:cfg
    Write-ZebraLog "لاگ عیبیابی: $f" 'OK'
  }
  if (-not $NoPause) { Read-Host "`nPress Enter to close" }
  exit
}

# ---------------------------------------------------------------- رابط گرافیکی
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Add-Ctls {
  param($Parent, [object[]]$Controls)
  foreach ($c in $Controls) { $null = $Parent.Controls.Add($c) }
}

function New-Ctl {
  param([string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
  $c = New-Object $Type
  if ($null -ne $Text) { $c.Text = $Text }
  $c.Location = New-Object System.Drawing.Point($X, $Y)
  $c.Size = New-Object System.Drawing.Size($W, $H)
  return $c
}

function Invoke-ZebraAction {
  param([string]$Title, [scriptblock]$Work)
  $script:lblStatus.Text = "در حال اجرا: $Title ..."
  [System.Windows.Forms.Application]::DoEvents()
  try {
    & $Work
    Write-ZebraLog "✅ $Title انجام شد" 'OK'
  } catch {
    Write-ZebraLog "❌ $Title : $($_.Exception.Message)" 'ERROR'
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $Title,
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
  } finally {
    $script:lblStatus.Text = 'آماده'
    try { Update-StatusView } catch { }
    [System.Windows.Forms.Application]::DoEvents()
  }
}

function Update-StatusView {
  $script:txtStatus.Text = Get-ZebraStatus $script:cfg $script:activeProfile
  $script:txtHost.Text = $(if ($script:cfg.host.ip) { $script:cfg.host.ip } else { $script:cfg.host.name })
  $script:lblStatus.Text = "سیستم: $env:COMPUTERNAME | پروفایل: $($script:activeProfile.name) | ادمین: بله"
}

function Refresh-ProfileCombo {
  $script:cmbProfile.Items.Clear()
  foreach ($p in @($script:cfg.profiles)) { $null = $script:cmbProfile.Items.Add([string]$p.name) }
  $names = @($script:cfg.profiles | ForEach-Object { [string]$_.name })
  $i = [array]::IndexOf($names, [string]$script:activeProfile.name)
  if ($i -ge 0) { $script:cmbProfile.SelectedIndex = $i }
  $script:lstProfiles.Items.Clear()
  foreach ($p in @($script:cfg.profiles)) {
    $tag = $(if ($p.id -eq $script:cfg.defaultProfileId) { '  ★ پیشفرض' } else { '' })
    $null = $script:lstProfiles.Items.Add("$($p.name)$tag  [$($p.shareName)]")
  }
}

function Refresh-HostGrid {
  $script:gridHosts.Rows.Clear()
  foreach ($h in @($script:hosts)) {
    $null = $script:gridHosts.Rows.Add(
      [string]$h.Name, [string]$h.IP, [string]$h.Shares,
      $(if ($h.PortOpen) { 'باز' } else { 'بسته' }),
      $(if ($h.Match) { '✅ پرینتر اینجاست' } else { '—' }))
  }
}

function Show-ZebraPasswordDialog {
  $f = New-Ctl 'System.Windows.Forms.Form' 'رمز کاربر چاپ (اختیاری)' 0 0 420 200
  $f.StartPosition = 'CenterParent'
  $f.FormBorderStyle = 'FixedDialog'
  $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $l1 = New-Ctl 'System.Windows.Forms.Label' 'اگر میخواهید کلاینتها با رمز وصل شوند، رمز را دوبار وارد کنید.' 18 16 380 40
  $t1 = New-Ctl 'System.Windows.Forms.TextBox' '' 18 62 370 26
  $t2 = New-Ctl 'System.Windows.Forms.TextBox' '' 18 96 370 26
  $t1.UseSystemPasswordChar = $true; $t2.UseSystemPasswordChar = $true
  $ok = New-Ctl 'System.Windows.Forms.Button' 'تایید' 210 132 85 30
  $skip = New-Ctl 'System.Windows.Forms.Button' 'رد کردن' 305 132 85 30
  $ok.DialogResult = 'OK'; $skip.DialogResult = 'Cancel'
  Add-Ctls $f @($l1, $t1, $t2, $ok, $skip)
  $f.AcceptButton = $ok; $f.CancelButton = $skip
  if ($f.ShowDialog() -ne 'OK') { return $null }
  if ($t1.Text -ne $t2.Text) {
    [System.Windows.Forms.MessageBox]::Show('دو رمز یکسان نیستند.', 'خطا')
    return $null
  }
  if (-not $t1.Text) { return $null }
  $s = New-Object System.Security.SecureString
  foreach ($ch in $t1.Text.ToCharArray()) { $s.AppendChar($ch) }
  return $s
}

function Show-ZebraProfileDialog {
  param($Existing)
  $fields = @(
    @{ K = 'name';        T = 'نام نمایشی (فارسی آزاد)' },
    @{ K = 'id';          T = 'شناسه یکتا (انگلیسی، بدون فاصله)' },
    @{ K = 'printerName'; T = 'نام پرینتر در ویندوز' },
    @{ K = 'driverName';  T = 'نام درایور (همان نام داخل INF)' },
    @{ K = 'driverInf';   T = 'مسINF نسبی، مثلاً driver/Zebra.inf' },
    @{ K = 'shareName';   T = 'نام اشتراک شبکه (مثلاً ZebraLabel)' },
    @{ K = 'usbHint';     T = 'راهنمای پورت USB (مثلاً GK888 / EPSON)' },
    @{ K = 'printUser';   T = 'کاربر چاپ (خالی = مهمان)' },
    @{ K = 'settingsPath';T = 'پوشه تنظیمات (خالی = بدون PrintTicket)' },
    @{ K = 'width';       T = 'عرض لیبل mm (خالی = بدون تنظیم)' },
    @{ K = 'height';      T = 'ارتفاع لیبل mm (خالی = بدون تنظیم)' }
  )
  $f = New-Ctl 'System.Windows.Forms.Form' 'پروفایل پرینتر' 0 0 620 560
  $f.StartPosition = 'CenterParent'
  $f.FormBorderStyle = 'FixedDialog'
  $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $boxes = @{}
  $y = 12
  foreach ($fd in $fields) {
    $l = New-Ctl 'System.Windows.Forms.Label' $fd.T 14 $y 250 20
    $t = New-Ctl 'System.Windows.Forms.TextBox' '' 272 $y 320 24
    Add-Ctls $f @($l, $t)
    $boxes[$fd.K] = $t
    $y += 42
  }
  if ($Existing) {
    foreach ($fd in $fields) {
      $v = $Existing.($fd.K)
      if ($null -ne $v) { $boxes[$fd.K].Text = [string]$v }
    }
    if ($Existing.label) {
      $boxes['width'].Text = [string]$Existing.label.widthMm
      $boxes['height'].Text = [string]$Existing.label.heightMm
    }
  }
  $ok = New-Ctl 'System.Windows.Forms.Button' 'ذخیره' 370 $y 100 32
  $cancel = New-Ctl 'System.Windows.Forms.Button' 'انصراف' 480 $y 100 32
  $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
  Add-Ctls $f @($ok, $cancel)
  $f.AcceptButton = $ok; $f.CancelButton = $cancel
  if ($f.ShowDialog() -ne 'OK') { return $null }
  $h = @{}
  foreach ($fd in $fields) { $h[$fd.K] = $boxes[$fd.K].Text.Trim() }
  if (-not $h['name'] -or -not $h['printerName'] -or -not $h['driverName'] -or -not $h['shareName']) {
    [System.Windows.Forms.MessageBox]::Show('نام، نام پرینتر، درایور و نام اشتراک الزامیاند.', 'خطا')
    return $null
  }
  if (-not $h['id']) { $h['id'] = New-ZebraProfileId $h['name'] }
  $w = 0; $ht = 0
  $label = $null
  if ([int]::TryParse($h['width'], [ref]$w) -and [int]::TryParse($h['height'], [ref]$ht)) {
    $label = [pscustomobject]@{ widthMm = $w; heightMm = $ht }
  }
  return [pscustomobject]@{
    id           = $h['id']
    name         = $h['name']
    printerName  = $h['printerName']
    driverName   = $h['driverName']
    driverInf    = $h['driverInf']
    shareName    = $h['shareName']
    printUser    = $h['printUser']
    usbHint      = $h['usbHint']
    settingsPath = $h['settingsPath']
    label        = $label
    testLabel    = $false
  }
}

function Show-ZebraPickDialog {
  param([string]$Title, [string[]]$Items)
  $f = New-Ctl 'System.Windows.Forms.Form' $Title 0 0 520 400
  $f.StartPosition = 'CenterParent'
  $lb = New-Ctl 'System.Windows.Forms.ListBox' '' 12 12 480 290
  foreach ($i in $Items) { $null = $lb.Items.Add($i) }
  if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
  $ok = New-Ctl 'System.Windows.Forms.Button' 'انتخاب' 300 315 90 32
  $cancel = New-Ctl 'System.Windows.Forms.Button' 'انصراف' 400 315 90 32
  $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
  Add-Ctls $f @($lb, $ok, $cancel)
  $f.AcceptButton = $ok; $f.CancelButton = $cancel
  if ($f.ShowDialog() -ne 'OK') { return $null }
  return [string]$lb.SelectedItem
}

# ---------------------------------------------------------------- فرم اصلی
$script:form = New-Ctl 'System.Windows.Forms.Form' 'نرم افزار مدیریت پرینتر' 0 0 1020 730
$script:form.StartPosition = 'CenterScreen'
$script:form.MinimumSize = New-Object System.Drawing.Size(900, 620)
$script:form.Font = New-Object System.Drawing.Font('Tahoma', 9)
$script:form.RightToLeft = 'No'

$lblP = New-Ctl 'System.Windows.Forms.Label' 'پرینتر:' 12 18 62 24
$script:cmbProfile = New-Ctl 'System.Windows.Forms.ComboBox' '' 78 14 330 26
$script:cmbProfile.DropDownStyle = 'DropDownList'
$lblH = New-Ctl 'System.Windows.Forms.Label' 'میزبان (هاست):' 420 18 100 24
$script:txtHost = New-Ctl 'System.Windows.Forms.TextBox' '' 522 14 175 26
$btnFind = New-Ctl 'System.Windows.Forms.Button' '🔍 پیدا کردن هاست' 705 12 130 30
$btnSave = New-Ctl 'System.Windows.Forms.Button' '💾 ذخیره تنظیمات' 843 12 150 30

$tabs = New-Ctl 'System.Windows.Forms.TabControl' '' 12 52 980 590
$tabs.Anchor = 'Top,Bottom,Left,Right'
$tab1 = New-Ctl 'System.Windows.Forms.TabPage' 'وضعیت و عملیات' 0 0 0 0
$tab2 = New-Ctl 'System.Windows.Forms.TabPage' 'مدیریت پرینترها' 0 0 0 0
$tab3 = New-Ctl 'System.Windows.Forms.TabPage' 'شبکه و نصب روی سیستم دیگر' 0 0 0 0
$tab4 = New-Ctl 'System.Windows.Forms.TabPage' 'گزارش' 0 0 0 0
foreach ($t in @($tab1, $tab2, $tab3, $tab4)) { $null = $tabs.TabPages.Add($t) }

# --- تب ۱
$script:txtStatus = New-Ctl 'System.Windows.Forms.TextBox' '' 10 10 940 250
$script:txtStatus.Multiline = $true
$script:txtStatus.ReadOnly = $true
$script:txtStatus.ScrollBars = 'Both'
$script:txtStatus.WordWrap = $false
$script:txtStatus.Font = New-Object System.Drawing.Font('Tahoma', 9)
$tab1.Controls.Add($script:txtStatus)

$btnRefresh = New-Ctl 'System.Windows.Forms.Button' '🔄 بروزرسانی وضعیت' 10 270 160 40
$btnInstall = New-Ctl 'System.Windows.Forms.Button' '① نصب + اشتراک (این سیستم هاست شود)' 180 270 260 40
$btnConnect = New-Ctl 'System.Windows.Forms.Button' '② اتصال به پرینتر شبکه (کلاینت)' 450 270 250 40
$btnClean = New-Ctl 'System.Windows.Forms.Button' '③ پاکسازی بقایای میزبان قدیمی' 710 270 250 40
$btnDiag = New-Ctl 'System.Windows.Forms.Button' '④ عیبیابی و لاگ' 10 320 160 40
$btnServer = New-Ctl 'System.Windows.Forms.Button' '⑤ نصب سرور لیبل موبایل' 180 320 260 40
$btnTest = New-Ctl 'System.Windows.Forms.Button' '🧪 چاپ لیبل تست' 450 320 250 40
$btnOpenFolder = New-Ctl 'System.Windows.Forms.Button' '📂 باز کردن پوشه نرمافزار' 710 320 250 40
Add-Ctls $tab1 @($btnRefresh, $btnInstall, $btnConnect, $btnClean, $btnDiag, $btnServer, $btnTest, $btnOpenFolder)

$hint = New-Ctl 'System.Windows.Forms.Label' '' 10 380 940 150
$hint.Text = @'
راهنمای سریع:
• روی سیستمی که پرینتر با کابل USB به آن وصل است، دکمه ① را بزن. نرمافزار درایور را نصب میکند، پرینتر را میسازد، Share میکند و نام/IP همین سیستم را بهعنوان «هاست» ذخیره میکند (هیچ نامی از قبل فرض نشده).
• روی هر سیستم دیگر (مخصوصاً سیستمی که قبلاً هاست بوده) دکمه ③ و بعد ② را بزن. بقایای میزبانی قدیمی پاک میشود و هاست جدید بهصورت خودکار در شبکه پیدا میشود.
• برای اضافه کردن پرینتر دیگه محیط کار، به تب «مدیریت پرینترها» برو و «افزودن پرینتر» یا «از پرینترهای نصبشده» را بزن. فایل INF درایورش را هم کنار پوشه driver بگذار.
• هر پروفایل ShareName و تنظیمات لیبل جداگانه دارد؛ یکی را پیشفرض کن تا بقیه دکمهها روی همان کار کنند.
'@
$tab1.Controls.Add($hint)

# --- تب ۲
$script:lstProfiles = New-Ctl 'System.Windows.Forms.ListBox' '' 10 10 500 430
$tab2.Controls.Add($script:lstProfiles)
$btnAdd = New-Ctl 'System.Windows.Forms.Button' '➕ افزودن پرینتر' 525 10 210 36
$btnEdit = New-Ctl 'System.Windows.Forms.Button' '✏️ ویرایش پروفایل' 525 54 210 36
$btnDelete = New-Ctl 'System.Windows.Forms.Button' '🗑 حذف پروفایل' 525 98 210 36
$btnDefault = New-Ctl 'System.Windows.Forms.Button' '⭐ تنظیم بهعنوان پیشفرض' 525 142 210 36
$btnAdopt = New-Ctl 'System.Windows.Forms.Button' '📋 از پرینترهای نصبشده این سیستم' 525 186 240 36
$btnDrivers = New-Ctl 'System.Windows.Forms.Button' '📁 باز کردن پوشه درایورها' 525 230 240 36
Add-Ctls $tab2 @($btnAdd, $btnEdit, $btnDelete, $btnDefault, $btnAdopt, $btnDrivers)
$hint2 = New-Ctl 'System.Windows.Forms.Label' '' 10 455 940 90
$hint2.Text = 'برای پرینتر تازه: فایل INF درایورش را داخل پوشه driver\ (یا زیرپوشه جداگانه) بگذار، سپس در دیالوگ افزودن، مسیر نسبیاش را وارد کن. اگر PrintTicket/DEVMODE مخصوص آن پرینتر را داری، پوشه settings\ مخصوصش را هم مشخص کن؛ در غیر این صورت خالی بگذار.'
$tab2.Controls.Add($hint2)

# --- تب ۳
$script:gridHosts = New-Ctl 'System.Windows.Forms.DataGridView' '' 10 10 940 320
$script:gridHosts.ReadOnly = $true
$script:gridHosts.AllowUserToAddRows = $false
$script:gridHosts.SelectionMode = 'FullRowSelect'
$script:gridHosts.AutoSizeColumnsMode = 'Fill'
foreach ($c in @('نام سیستم', 'IP / نام', 'شیرهای پیداشده', 'پورت ۴۴۵', 'نتیجه')) {
  $null = $script:gridHosts.Columns.Add($c, $c)
}
$tab3.Controls.Add($script:gridHosts)
$btnScan = New-Ctl 'System.Windows.Forms.Button' '🔍 اسکن شبکه' 10 342 150 36
$btnPickHost = New-Ctl 'System.Windows.Forms.Button' '✅ انتخاب بهعنوان میزبان' 170 342 220 36
$btnTestSmb = New-Ctl 'System.Windows.Forms.Button' '🔌 تست اتصال SMB' 400 342 180 36
$script:txtRemote = New-Ctl 'System.Windows.Forms.TextBox' '' 10 395 220 26
$btnRemoteCopy = New-Ctl 'System.Windows.Forms.Button' '📤 کپی پوشه به C$ سیستم مقصد' 240 390 250 36
$btnRemoteInstall = New-Ctl 'System.Windows.Forms.Button' '⚙️ نصب از راه دور (WinRM)' 500 390 250 36
Add-Ctls $tab3 @($btnScan, $btnPickHost, $btnTestSmb, $script:txtRemote, $btnRemoteCopy, $btnRemoteInstall)
$hint3 = New-Ctl 'System.Windows.Forms.Label' '' 10 445 940 110
$hint3.Text = 'نصب از راه دور: نام سیستم مقصد را بنویس، «کپی پوشه به C$» بزن (نیاز به دسترسی ادمین روی مقصد)، سپس «نصب از راه دور» که با WinRM اجرا میشود. اگر WinRM فعال نیست، همان پوشه را روی مقصد با USB/شبکه ببر و «مدیریت پرینتر.bat» را آنجا اجرا کن. هر دو مسیر از همان پروفایل و همان هسته استفاده میکنند.'
$tab3.Controls.Add($hint3)

# --- تب ۴
$script:txtLog = New-Ctl 'System.Windows.Forms.TextBox' '' 10 10 940 470
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Both'
$script:txtLog.WordWrap = $false
$tab4.Controls.Add($script:txtLog)
$btnClearLog = New-Ctl 'System.Windows.Forms.Button' '🧹 پاک کردن' 10 490 120 32
$btnCopyLog = New-Ctl 'System.Windows.Forms.Button' '📋 کپی' 140 490 120 32
$btnOpenLog = New-Ctl 'System.Windows.Forms.Button' '📂 باز کردن فایل لاگ' 270 490 170 32
Add-Ctls $tab4 @($btnClearLog, $btnCopyLog, $btnOpenLog)

$status = New-Ctl 'System.Windows.Forms.StatusStrip' '' 0 0 0 0
$script:lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:lblStatus.Text = 'آماده'
$null = $status.Items.Add($script:lblStatus)

Add-Ctls $script:form @($lblP, $script:cmbProfile, $lblH, $script:txtHost, $btnFind, $btnSave, $tabs, $status)

# لاگ به پنجره هم فرستاده میشود
$script:ZebraLogSink = {
  param($line)
  if ($script:txtLog) {
    $script:txtLog.AppendText($line + [Environment]::NewLine)
    $script:txtLog.SelectionStart = $script:txtLog.Text.Length
    $script:txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
  }
}

# ---------------------------------------------------------------- رویدادها
$script:cmbProfile.Add_SelectedIndexChanged({
  $i = $script:cmbProfile.SelectedIndex
  if ($i -ge 0 -and $i -lt @($script:cfg.profiles).Count) {
    $script:activeProfile = @($script:cfg.profiles)[$i]
    $script:cfg.defaultProfileId = $script:activeProfile.id
    Update-StatusView
  }
})

$btnRefresh.Add_Click({ Update-StatusView })

$btnFind.Add_Click({
  Invoke-ZebraAction 'جستجوی هاست در شبکه' {
    $script:hosts = @(Find-ZebraHosts $script:cfg)
    Refresh-HostGrid
    $hit = @($script:hosts | Where-Object { $_.Match -and -not $_.IsSelf } | Select-Object -First 1)
    if ($hit.Count -gt 0) {
      Set-ZebraDetectedHost $script:cfg $hit[0]
      Update-StatusView
    } else {
      Write-ZebraLog 'هاستی پیدا نشد؛ روی سیستم متصل به کابل، دکمه ① را بزن.' 'WARN'
    }
  }
})

$btnSave.Add_Click({
  Invoke-ZebraAction 'ذخیره تنظیمات' {
    $v = $script:txtHost.Text.Trim()
    if ($v -match '^\d{1,3}(\.\d{1,3}){3}$') { $script:cfg.host.ip = $v }
    else { $script:cfg.host.name = $v }
    $script:cfg.host.autoDetect = $false
    Save-ZebraConfig $script:cfg
    Sync-ZebraHostFile $script:cfg $script:activeProfile
    Update-StatusView
  }
})

$btnInstall.Add_Click({
  Invoke-ZebraAction 'نصب و اشتراک (میزبان)' {
    $pw = Show-ZebraPasswordDialog
    $null = Install-ZebraHost $script:cfg $script:activeProfile $pw
    Update-StatusView
  }
})

$btnConnect.Add_Click({
  Invoke-ZebraAction 'اتصال بهعنوان کلاینت' {
    $pw = $null
    if ($script:activeProfile.printUser) {
      $ans = [System.Windows.Forms.MessageBox]::Show(
        "آیا کاربر چاپ '$($script:activeProfile.printUser)' رمز دارد؟ (خیر = دسترسی مهمان)",
        'ورود به هاست', [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
      if ($ans -eq 'Yes') { $pw = Show-ZebraPasswordDialog }
    }
    $null = Connect-ZebraClient $script:cfg $script:activeProfile -PrintPassword $pw
    Update-StatusView
  }
})

$btnClean.Add_Click({
  Invoke-ZebraAction 'پاکسازی بقایای میزبان قدیمی' {
    $rows = Remove-ZebraFormerHost -Cfg $script:cfg -ZProfile $script:activeProfile `
      -Mode ([string]$script:cfg.cleanup.mode)
    Write-ZebraLog ("موارد پاکشده: {0}" -f @($rows).Count) 'OK'
    Update-StatusView
  }
})

$btnDiag.Add_Click({
  Invoke-ZebraAction 'عیبیابی' {
    $f = Invoke-ZebraDiagnose $script:cfg
    Write-ZebraLog "لاگ ذخیره شد: $f" 'OK'
  }
})

$btnServer.Add_Click({
  Invoke-ZebraAction 'نصب سرور لیبل موبایل' {
    Install-ZebraLabelServer $script:cfg $script:activeProfile
    Update-StatusView
  }
})

$btnTest.Add_Click({
  Invoke-ZebraAction 'چاپ لیبل تست' {
    $s = Join-Path $script:ZebraRoot 'install.ps1'
    if (-not (Test-Path $s)) { throw 'install.ps1 پیدا نشد.' }
    Write-ZebraLog 'برای لیبل تست، install.bat را اجرا کنید یا از اپ «لیبل زن .html» چاپ بگیرید.' 'WARN'
  }
})

$btnOpenFolder.Add_Click({ Start-Process explorer.exe $script:ZebraRoot })

$btnAdd.Add_Click({
  $p = Show-ZebraProfileDialog
  if ($p) {
    $script:cfg.profiles = @(@($script:cfg.profiles) + $p)
    Save-ZebraConfig $script:cfg
    Refresh-ProfileCombo
    Write-ZebraLog "پروفایل اضافه شد: $($p.name)" 'OK'
  }
})

function Get-SelectedProfileIndex {
  $i = $script:lstProfiles.SelectedIndex
  if ($i -lt 0) { return -1 }
  return $i
}

$btnEdit.Add_Click({
  $i = Get-SelectedProfileIndex
  if ($i -lt 0) { return }
  $old = @($script:cfg.profiles)[$i]
  $p = Show-ZebraProfileDialog $old
  if ($p) {
    $arr = @($script:cfg.profiles)
    $arr[$i] = $p
    $script:cfg.profiles = $arr
    Save-ZebraConfig $script:cfg
    Refresh-ProfileCombo
    Write-ZebraLog "پروفایل ویرایش شد: $($p.name)" 'OK'
  }
})

$btnDelete.Add_Click({
  $i = Get-SelectedProfileIndex
  if ($i -lt 0) { return }
  if (@($script:cfg.profiles).Count -le 1) {
    [System.Windows.Forms.MessageBox]::Show('حداقل یک پروفایل باید بماند.', 'خطا')
    return
  }
  $old = @($script:cfg.profiles)[$i]
  $script:cfg.profiles = @($script:cfg.profiles | Where-Object { $_.id -ne $old.id })
  if ($script:cfg.defaultProfileId -eq $old.id) { $script:cfg.defaultProfileId = @($script:cfg.profiles)[0].id }
  Save-ZebraConfig $script:cfg
  $script:activeProfile = Get-ZebraProfile $script:cfg $script:cfg.defaultProfileId
  Refresh-ProfileCombo
  Write-ZebraLog "پروفایل حذف شد: $($old.name)" 'OK'
})

$btnDefault.Add_Click({
  $i = Get-SelectedProfileIndex
  if ($i -lt 0) { return }
  $script:cfg.defaultProfileId = @($script:cfg.profiles)[$i].id
  $script:activeProfile = @($script:cfg.profiles)[$i]
  Save-ZebraConfig $script:cfg
  Refresh-ProfileCombo
  Update-StatusView
})

$btnAdopt.Add_Click({
  $items = @(Get-ZebraAdoptablePrinters | ForEach-Object { "$($_.Name)  |  $($_.DriverName)  |  $($_.PortName)" })
  if ($items.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('پرینتری نصب نیست.', 'اطلاع'); return }
  $sel = Show-ZebraPickDialog 'کدام پرینتر نصبشده را اضافه کنیم؟' $items
  if (-not $sel) { return }
  $name = ($sel -split '\s+\|\s+')[0]
  $obj = @(Get-ZebraAdoptablePrinters | Where-Object { $_.Name -eq $name } | Select-Object -First 1)[0]
  $p = [pscustomobject]@{
    id = New-ZebraProfileId $obj.Name
    name = $obj.Name
    printerName = $obj.Name
    driverName = $obj.DriverName
    driverInf = ''
    shareName = ($obj.Name -replace '[^\w]', '')
    printUser = ''
    usbHint = ''
    settingsPath = ''
    label = $null
    testLabel = $false
  }
  $p = Show-ZebraProfileDialog $p
  if ($p) {
    $script:cfg.profiles = @(@($script:cfg.profiles) + $p)
    Save-ZebraConfig $script:cfg
    Refresh-ProfileCombo
    Write-ZebraLog "پروفایل از پرینتر نصبشده ساخته شد: $($p.name)" 'OK'
  }
})

$btnDrivers.Add_Click({
  $d = Join-Path $script:ZebraRoot 'driver'
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  Start-Process explorer.exe $d
})

$btnScan.Add_Click({
  Invoke-ZebraAction 'اسکن شبکه' {
    $script:hosts = @(Find-ZebraHosts $script:cfg)
    Refresh-HostGrid
  }
})

$btnPickHost.Add_Click({
  if ($script:gridHosts.SelectedRows.Count -eq 0) { return }
  $i = $script:gridHosts.SelectedRows[0].Index
  $row = @($script:hosts)[$i]
  Invoke-ZebraAction 'انتخاب میزبان' { Set-ZebraDetectedHost $script:cfg $row; Update-StatusView }
})

$btnTestSmb.Add_Click({
  if ($script:gridHosts.SelectedRows.Count -eq 0) { return }
  $i = $script:gridHosts.SelectedRows[0].Index
  $h = @($script:hosts)[$i]
  Invoke-ZebraAction "تست SMB با $($h.IP)" {
    $txt = Get-ZebraSharesOnHost $h.IP
    foreach ($l in @($txt -split "`n" | Select-Object -First 8)) { Write-ZebraLog "  $l" }
  }
})

$btnRemoteCopy.Add_Click({
  $t = $script:txtRemote.Text.Trim()
  if (-not $t) { return }
  Invoke-ZebraAction "کپی پوشه به $t" {
    $dest = "\\$t\C`$\ZebraManager"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-Path $script:ZebraRoot '*') $dest -Recurse -Force
    Write-ZebraLog "پوشه کپی شد: $dest" 'OK'
  }
})

$btnRemoteInstall.Add_Click({
  $t = $script:txtRemote.Text.Trim()
  if (-not $t) { return }
  Invoke-ZebraAction "نصب از راه دور روی $t" {
    $remotePath = 'C:\ZebraManager'
    $id = [string]$script:activeProfile.id
    $out = Invoke-Command -ComputerName $t -ScriptBlock {
      param($path, $profileId)
      $ZebraRootOverride = $path
      . (Join-Path $path 'lib\Zebra.ps1')
      $c = Initialize-Zebra
      $p = Get-ZebraProfile $c $profileId
      $null = Install-ZebraHost $c $p
      Get-ZebraStatus $c $p
    } -ArgumentList $remotePath, $id -ErrorAction Stop
    foreach ($l in @($out)) { if ($l) { Write-ZebraLog "  remote: $l" } }
  }
})

$btnClearLog.Add_Click({ $script:txtLog.Clear() })
$btnCopyLog.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($script:txtLog.Text) })
$btnOpenLog.Add_Click({
  if (Test-Path $script:ZebraLogPath) { Start-Process notepad.exe $script:ZebraLogPath }
})

$script:form.Add_Shown({
  Refresh-ProfileCombo
  Update-StatusView
  Write-ZebraLog 'نرم افزار مدیریت پرینتر آماده است. هیچ نام سیستمی پیشفرض نشده؛ هاست یا اینجاست یا تو شبکه پیدا میشود.' 'OK'
})

$null = $script:form.ShowDialog()
