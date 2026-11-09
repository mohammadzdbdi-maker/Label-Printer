# وصل شدن به پرینتر Zebra اشتراکی از کامپیوترهای دیگر شبکه
# این را روی هر کامپیوتری اجرا کنید که می‌خواهد روی پرینتر چاپ کند (connect-client.bat)

param([switch]$NoPause, [string]$TargetHost, [string]$TargetIp)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
  exit
}

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$DriverName = 'Zebra GK888t - EPL'

function Step($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   OK: $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !! $t" -ForegroundColor Yellow }

try {
  # 1) نام کامپیوتری که پرینتر به آن وصل است
  $hostName = $null; $hostIp = $null; $ShareName = 'ZebraLabel'; $PrintUser = $null
  if (Test-Path "$here\host.txt") {
    $lines = @(Get-Content "$here\host.txt")
    $hostName = $lines[0]; $hostIp = $lines[1]; if ($lines[2]) { $ShareName = $lines[2] }
    if ($lines.Count -ge 4 -and $lines[3]) { $PrintUser = $lines[3] }
  }
  if ($TargetHost) { $hostName = $TargetHost }
  if ($TargetIp)   { $hostIp   = $TargetIp }
  # اگر این سیستم قبلاً میزبان بوده، host.txt ممکن است هنوز به خودش اشاره کند
  $selfIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
  if (($hostName -and $hostName -ieq $env:COMPUTERNAME) -or ($hostIp -and $selfIps -contains $hostIp)) {
    Warn 'host.txt points to this very PC (it used to be the host) - ignoring it.'
    $hostName = $null; $hostIp = $null
  }
  if (-not $hostName) {
    if ($NoPause) { throw 'هاست مشخص نیست. از «نرمافزار مدیریت پرینتر» استفاده کنید یا -TargetHost بدهید.' }
    $hostName = Read-Host 'Name or IP of the PC the printer is connected to'
  }

  Step "Looking for $hostName on the network..."
  $target = $null
  foreach ($h in @($hostName, $hostIp) | Where-Object { $_ }) {
    if (Test-Connection $h -Count 1 -Quiet) { $target = $h; break }
  }
  if (-not $target) {
    Warn "Can't reach $hostName / $hostIp (ping may be blocked) - trying anyway."
    $target = $hostName
  }
  Ok "Using: $target"

  # کاربر مخصوص چاپ: رمز را یک بار می‌پرسد و در ویندوز ذخیره می‌کند
  if ($PrintUser) {
    Step "Saving login for print user '$PrintUser'..."
    $sec = Read-Host "   Password of '$PrintUser' (set on $hostName)" -AsSecureString
    $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    foreach ($h in @($hostName, $hostIp) | Where-Object { $_ }) {
      cmd /c "net use \\$h\IPC$ /delete /y >nul 2>&1"
      cmdkey /add:$h /user:"$hostName\$PrintUser" /pass:"$pw" | Out-Null
    }
    cmd /c "net use \\$target\IPC$ /user:$hostName\$PrintUser `"$pw`" >nul 2>&1"
    if ($LASTEXITCODE -eq 0) { Ok 'Login accepted' } else { Warn 'Login was not accepted - check the password (run again to retry).' }
  }

  # پاکسازی پرینتر/پورتهایی که زمان میزبانی قدیمی به نام همین سیستم ساخته شدهاند
  $selfRe = '^\\\\' + [regex]::Escape($env:COMPUTERNAME) + '\\'
  Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -match $selfRe } | ForEach-Object {
    Warn "Removing stale former-host printer: $($_.Name)"
    Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
    Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
  }

  # 2) نصب درایور روی همین کامپیوتر (تا ویندوز از سرور درایور نخواهد)
  Step 'Installing driver locally...'
  pnputil /add-driver "$here\driver\zebra.inf" /install | Out-Null
  if (-not (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue)) { Add-PrinterDriver -Name $DriverName }
  Ok $DriverName

  # حذف پرینتر اشتباه قدیمی (ZD888) که کارهای چاپ را می‌بلعد
  Get-Printer | Where-Object { $_.Name -like 'ZDesigner ZD888*' } | ForEach-Object {
    Warn "Removing old wrong printer: $($_.Name)"
    Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
    Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
  }

  # 3) وصل شدن به پرینتر اشتراکی
  Step "Connecting to \\$target\$ShareName ..."
  $conn      = "\\$target\$ShareName"
  $LocalName = "Zebra GK888t ($target)"
  # ویندوز اتصال را با نام اصلی پرینتر می‌سازد (مثلا \\HOST-PC\Zebra GK888t - EPL)، نه با نام اشتراک
  $isOurs = { param($p) $p.Name -ieq $conn -or $p.Name -eq $LocalName -or $p.PortName -ieq $conn -or
    ($p.Type -eq 'Connection' -and (@($hostName, $hostIp) | Where-Object { $_ -and $p.Name -like "\\$_\*" })) }
  $printer = Get-Printer | Where-Object { & $isOurs $_ } | Select-Object -First 1
  if (-not $printer) {
    try {
      Add-Printer -ConnectionName $conn -ErrorAction Stop
      $printer = Get-Printer | Where-Object { & $isOurs $_ } | Select-Object -First 1
    } catch {
      # خطای 0x11b ویندوز: به‌جای اتصال معمولی، یک پرینتر محلی با پورت \\PC\Share می‌سازیم
      Warn 'Normal connection blocked by Windows (error 0x11b) - using local port method.'
      if (-not (Get-PrinterPort -Name $conn -ErrorAction SilentlyContinue)) { Add-PrinterPort -Name $conn }
      Add-Printer -Name $LocalName -DriverName $DriverName -PortName $conn
      $printer = Get-Printer -Name $LocalName
      # همان تنظیمات ذخیره‌شده (حرارتی مستقیم + 58x40) برای این پرینتر محلی
      foreach ($k in 'DevModePerUser', 'DevModes2') {
        $reg = "HKCU:\Printers\$k"
        if (-not (Test-Path $reg)) { New-Item $reg -Force | Out-Null }
        New-ItemProperty -Path $reg -Name $LocalName -PropertyType Binary -Value ([IO.File]::ReadAllBytes("$here\settings\$k.bin")) -Force | Out-Null
      }
    }
  }
  if (-not $printer) { throw "Could not connect to $conn" }
  Ok "Connected: $($printer.Name)"

  # 4) تنظیمات: حرارتی مستقیم + لیبل 58x40
  Step 'Applying settings (Direct Thermal, 58x40 mm)...'
  try {
    Set-PrintConfiguration -PrinterName $printer.Name -PrintTicketXml ([IO.File]::ReadAllText("$here\settings\PrintTicket.xml"))
    Ok 'Settings applied'
  } catch { Warn "Could not apply settings here - the printer PC's settings will be used." }

  # 5) کپی برنامه لیبل‌زن روی دسکتاپ
  $app = Get-ChildItem $here -Filter '*.html' | Select-Object -First 1
  if ($app) {
    Copy-Item $app.FullName ([Environment]::GetFolderPath('Desktop')) -Force
    Ok "Label app copied to Desktop: $($app.Name)"
  }

  # 6) لیبل تست
  Step 'Printing a test label...'
  Add-Type -AssemblyName System.Drawing
  $d = New-Object System.Drawing.Printing.PrintDocument
  $d.PrinterSettings.PrinterName = $printer.Name
  $d.DocumentName = 'network-test'
  $d.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
  $d.add_PrintPage({
    param($s, $e)
    $g = $e.Graphics; $g.PageUnit = [System.Drawing.GraphicsUnit]::Millimeter
    $g.DrawRectangle((New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 0.4)), 1.5, 1.5, 55, 37)
    $g.DrawString("NET $env:COMPUTERNAME", (New-Object System.Drawing.Font('Tahoma', 10, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::Black, 5, 15)
  })
  $d.Print()
  Ok 'Test label sent'

  Write-Host "`n==== DONE ====" -ForegroundColor Green
  Write-Host "In the browser print dialog choose: $($printer.Name)  (Margins = None, Scale = 100)"
}
catch {
  Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
if (-not $NoPause) { Read-Host "`nPress Enter to close" }
