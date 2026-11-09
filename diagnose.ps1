# عیب‌یابی اتصال به پرینتر اشتراکی Zebra - یک فایل لاگ می‌سازد (diagnose.bat)
# بدون دسترسی ادمین اجرا می‌شود تا وضعیت واقعی کاربر را ببیند. یک لیبل تست هم می‌فرستد.
# نکته: هیچ نام کامپیوتر/IPای هاردکد نیست؛ همهچیز از host.txt خوانده میشود.

param([switch]$NoPause)

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$logName   = "diag-$env:COMPUTERNAME-$stamp.txt"
$logPath   = Join-Path $here $logName
$LogShares = @()   # مسیر شیر لاگ دلخواه خود را اینجا اضافه کنید

$hostName = $null; $hostIp = $null; $ShareName = 'ZebraLabel'; $PrintUser = $null
if (Test-Path "$here\host.txt") {
  $l = @(Get-Content "$here\host.txt")
  if ($l[0]) { $hostName = $l[0] }; if ($l.Count -gt 1 -and $l[1]) { $hostIp = $l[1] }
  if ($l.Count -gt 2 -and $l[2]) { $ShareName = $l[2] }; if ($l.Count -gt 3 -and $l[3]) { $PrintUser = $l[3] }
}

$out = New-Object System.Collections.Generic.List[string]
if (-not $hostName) {
  $out.Add('توجه: host.txt هنوز تنظیم نشده است. ابتدا در نرم افزار مدیریت پرینتر دکمه «پیدا کردن هاست» یا «نصب و اشتراک» را بزنید.')
}
function Section($t) { $out.Add(''); $out.Add("===== $t ====="); Write-Host ">> $t" -ForegroundColor Cyan }
function Log($t)     { $out.Add([string]$t) }
function Run($title, [scriptblock]$sb) {
  Section $title
  try { (& $sb 2>&1 | Out-String -Width 250).TrimEnd() -split "`r?`n" | ForEach-Object { Log $_ } }
  catch { Log "EXCEPTION: $($_.Exception.Message)" }
}

Run 'System' {
  "Computer : $env:COMPUTERNAME"
  "User     : $env:USERDOMAIN\$env:USERNAME"
  "Date     : $(Get-Date)"
  $os = Get-CimInstance Win32_OperatingSystem
  "OS       : $($os.Caption) $($os.Version) build $($os.BuildNumber)"
  "Admin    : $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
  "Target   : \\$hostName\$ShareName  ($hostIp)  user=$PrintUser"
  "host.txt : $(Test-Path "$here\host.txt")"
}

Run 'Network' {
  Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^127\.' } | Select-Object InterfaceAlias, IPAddress, PrefixLength
  Get-NetConnectionProfile | Select-Object Name, InterfaceAlias, NetworkCategory
}

Run 'Reach printer PC' {
  foreach ($h in $hostName, $hostIp) {
    $ping = Test-Connection $h -Count 1 -Quiet -ErrorAction SilentlyContinue
    $dns  = try { ([Net.Dns]::GetHostAddresses($h) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1).IPAddressToString } catch { "FAIL ($($_.Exception.Message))" }
    $c = New-Object Net.Sockets.TcpClient
    $smb = try { $c.ConnectAsync($h, 445).Wait(2000) } catch { $false }
    $c.Close()
    "{0,-16} ping={1,-5} resolves={2,-16} port445={3}" -f $h, $ping, $dns, $smb
  }
}

Run 'SMB client settings' {
  Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' -ErrorAction SilentlyContinue |
    Select-Object AllowInsecureGuestAuth, RequireSecuritySignature, EnableSecuritySignature
  "Policy AllowInsecureGuestAuth: " + (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -ErrorAction SilentlyContinue).AllowInsecureGuestAuth
  Get-Service LanmanWorkstation, Spooler | Select-Object Name, Status, StartType
}

Run 'Saved logins & open connections' {
  cmd /c "cmdkey /list 2>&1" | Select-String -Pattern $hostName, $hostIp -SimpleMatch -Context 0, 2
  cmd /c "net use 2>&1"
}

Run "net view \\$hostName" { cmd /c "net view \\$hostName 2>&1" }
Run "net view \\$hostIp"   { cmd /c "net view \\$hostIp 2>&1" }

Run 'Zebra driver & printers on this PC' {
  Get-PrinterDriver | Where-Object Name -match 'Zebra|ZDesigner' | Select-Object Name, MajorVersion
  Get-Printer | Where-Object { $_.Name -match 'Zebra|ZDesigner' -or $_.PortName -match [regex]::Escape($ShareName) } |
    Select-Object Name, Type, PortName, PrinterStatus, JobCount | Format-List
  Get-Printer | Where-Object { $_.Name -match 'Zebra' } | ForEach-Object {
    Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue | Select-Object @{n = 'Printer'; e = { $_.PrinterName } }, Id, DocumentName, JobStatus, SubmittedTime
  }
}

# تست ۱: ارسال مستقیم یک لیبل به پرینتر اشتراکی
Run 'TEST 1: send label directly to share' {
  if (-not $hostName) { 'SKIP: host.txt تنظیم نشده است.'; return }
  $f = Join-Path $env:TEMP 'zebra-diag.txt'
  [IO.File]::WriteAllText($f, "`r`nN`r`nA30,40,0,3,1,1,N,`"DIAG $env:COMPUTERNAME`"`r`nP1`r`n")
  foreach ($h in $hostName, $hostIp) {
    $r = cmd /c "copy /b `"$f`" \\$h\$ShareName 2>&1"
    "\\$h\$ShareName -> exit=$LASTEXITCODE : $(($r | Where-Object { $_ }) -join ' | ')"
    if ($LASTEXITCODE -eq 0) { break }
  }
}

# تست ۲: اتصال معمولی ویندوز (برای دیدن کد خطا، مثلا 0x11b)
Run 'TEST 2: Windows printer connection (error code only)' {
  if (-not $hostName) { 'SKIP: host.txt تنظیم نشده است.'; return }
  $conn = "\\$hostName\$ShareName"
  $had  = [bool](Get-Printer | Where-Object { $_.Type -eq 'Connection' -and ($_.Name -like "\\$hostName\*" -or $_.Name -like "\\$hostIp\*") })
  $net  = New-Object -ComObject WScript.Network
  try {
    $net.AddWindowsPrinterConnection($conn); 'OK - connected'
    if (-not $had) { $net.RemovePrinterConnection($conn, $true, $true) }   # فقط تست بود، پاکش می‌کنیم
  }
  catch { 'FAILED: {0} (0x{1:X8})' -f $_.Exception.Message, $_.Exception.HResult }
}

Run 'Recent print errors (PrintService log)' {
  Get-WinEvent -LogName 'Microsoft-Windows-PrintService/Admin' -MaxEvents 10 -ErrorAction Stop |
    Select-Object TimeCreated, Id, @{n = 'Message'; e = { ($_.Message -replace '\s+', ' ').Substring(0, [Math]::Min(220, $_.Message.Length)) } } |
    Format-List
}

# ذخیره لاگ
[IO.File]::WriteAllLines($logPath, $out, (New-Object Text.UTF8Encoding $true))
Write-Host "`nLog saved: $logPath" -ForegroundColor Green
$sent = $false
foreach ($s in $LogShares) {
  try { Copy-Item $logPath (Join-Path $s $logName) -ErrorAction Stop; Write-Host "Log also sent to: $s" -ForegroundColor Green; $sent = $true; break } catch { }
}
if (-not $sent) { Write-Host 'Log was not sent over the network - copy this file manually if needed.' -ForegroundColor Yellow }
if (-not $NoPause) {
  Start-Process notepad.exe $logPath
  Read-Host "`nPress Enter to close"
}
