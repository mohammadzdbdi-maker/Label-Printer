# -*- coding: utf-8 -*-
# هسته مشترک «نرم افزار مدیریت پرینتر»
# PowerShell 5.1 / ویندوز 10 به بالا. هیچ نام کامپیوتر یا IPای هاردکد نشده است.
# این فایل توسط app/ZebraManager.ps1 و fix-client.ps1 dot-source میشود.

# ریشه پروژه: یا صریحاً توسط فراخواننده ($ZebraRootOverride) یا از مسیر همین فایل
$script:ZebraRoot = if ($ZebraRootOverride) { [string]$ZebraRootOverride }
  elseif ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot }
  else { (Get-Location).Path }
$script:ZebraConfigPath = Join-Path $script:ZebraRoot 'config\printers.json'
$script:ZebraLogPath = Join-Path $script:ZebraRoot 'logs\manager.log'
$script:ZebraLogSink = $null

$script:ZebraDefaultConfig = @'
{
  "version": 2,
  "defaultProfileId": "zebra-gk888t",
  "host": { "name": "", "ip": "", "autoDetect": true, "note": "" },
  "discovery": { "scanSubnet": true, "port": 445, "timeoutMs": 350, "maxThreads": 40, "extraHosts": [] },
  "labelServer": { "enabled": true, "port": 8080, "dest": "C:\\ZebraLabelServer", "taskName": "Zebra Label Server" },
  "cleanup": { "mode": "full", "removePrintUser": true, "removeLabelServer": true, "removeUrlAcl": true, "removeOldCredentials": true },
  "profiles": [
    {
      "id": "zebra-gk888t", "name": "Zebra GK888t", "printerName": "Zebra GK888t - EPL",
      "driverName": "Zebra GK888t - EPL", "driverInf": "driver/Zebra.inf", "shareName": "ZebraLabel",
      "printUser": "zebraprint", "usbHint": "GK888", "settingsPath": "settings",
      "label": { "widthMm": 58, "heightMm": 40 }, "testLabel": true
    }
  ]
}
'@

# ---------------------------------------------------------------- لاگ و کانفیگ
function Write-ZebraLog {
  param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO')
  $line = ('{0}  [{1}]  {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
  try {
    $dir = Split-Path -Parent $script:ZebraLogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path $script:ZebraLogPath) -and (Get-Item $script:ZebraLogPath).Length -gt 1048576) {
      Move-Item $script:ZebraLogPath "$script:ZebraLogPath.old" -Force
    }
    Add-Content -Path $script:ZebraLogPath -Value $line -Encoding UTF8
  } catch { }
  if ($script:ZebraLogSink) { try { & $script:ZebraLogSink $line } catch { } }
  Write-Host $line
}

function Initialize-Zebra {
  if (-not (Test-Path $script:ZebraConfigPath)) {
    $dir = Split-Path -Parent $script:ZebraConfigPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($script:ZebraConfigPath, $script:ZebraDefaultConfig, (New-Object Text.UTF8Encoding $false))
  }
  $cfg = Get-Content $script:ZebraConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $cfg.profiles -or @($cfg.profiles).Count -eq 0) { throw 'هیچ پروفایل پرینتری در config/printers.json تعریف نشده است.' }
  return $cfg
}

function Save-ZebraConfig {
  param($Cfg)
  $json = $Cfg | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText($script:ZebraConfigPath, $json, (New-Object Text.UTF8Encoding $false))
  Write-ZebraLog 'تنظیمات ذخیره شد (config/printers.json)' 'OK'
}

function Get-ZebraProfile {
  param($Cfg, [string]$Id)
  $p = @($Cfg.profiles) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $p) { $p = @($Cfg.profiles)[0] }
  return $p
}

function Get-ZebraShareNames {
  param($Cfg)
  return @(@($Cfg.profiles) | ForEach-Object { $_.shareName } | Where-Object { $_ } | Select-Object -Unique)
}

function Test-ZebraAdmin {
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Get-ZebraLocalIdentity {
  $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    Select-Object -ExpandProperty IPAddress)
  $names = @($env:COMPUTERNAME, ([Net.Dns]::GetHostName())) |
    Where-Object { $_ } | ForEach-Object { $_.ToUpper() } | Select-Object -Unique
  return [pscustomobject]@{ Name = $env:COMPUTERNAME; Names = @($names); IPs = @($ips) }
}

function Test-ZebraIsSelf {
  param([string]$Target)
  if (-not $Target) { return $false }
  $id = Get-ZebraLocalIdentity
  $t = $Target.ToUpper()
  if (@($id.Names) -contains $t) { return $true }
  if (@($id.IPs) -contains $Target) { return $true }
  return $false
}

# ---------------------------------------------------------------- کشف هاست در شبکه
function Get-ZebraCandidates {
  param($Cfg)
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($v in @($Cfg.host.name, $Cfg.host.ip)) { if ($v) { $list.Add([string]$v) } }
  foreach ($v in @($Cfg.discovery.extraHosts)) { if ($v) { $list.Add([string]$v) } }

  # کامپیوترهایی که net view نشان میدهد (بدون نیاز به اسکن)
  try {
    $nv = cmd /c 'net view 2>&1'
    foreach ($l in $nv) {
      $m = [regex]::Match([string]$l, '^\\\\([A-Za-z0-9._-]+)')
      if ($m.Success) { $list.Add($m.Groups[1].Value) }
    }
  } catch { }

  # همسایههای ARP
  try {
    $arp = cmd /c 'arp -a 2>&1'
    foreach ($l in $arp) {
      $m = [regex]::Match([string]$l, '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s')
      if ($m.Success -and $m.Groups[1].Value -notmatch '^(127\.|169\.254\.|224\.|255\.)') { $list.Add($m.Groups[1].Value) }
    }
  } catch { }

  # اسکن /24 زیرشبکه محلی
  if ($Cfg.discovery.scanSubnet) {
    foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
      $m = [regex]::Match([string]$a.IPAddress, '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}$')
      if (-not $m.Success) { continue }
      if ($a.IPAddress -match '^(127\.|169\.254\.)') { continue }
      $base = $m.Groups[1].Value + '.' + $m.Groups[2].Value + '.' + $m.Groups[3].Value
      for ($i = 1; $i -le 254; $i++) { $list.Add($base + '.' + $i) }
    }
  }
  return @($list | Where-Object { $_ } | Select-Object -Unique)
}

function Test-ZebraPortParallel {
  param([string[]]$Hosts, [int]$Port = 445, [int]$TimeoutMs = 350, [int]$MaxThreads = 40)
  if (-not $Hosts -or $Hosts.Count -eq 0) { return @() }
  $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
  $pool.Open()
  $code = {
    param($h, $p, $t)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
      $task = $c.ConnectAsync($h, $p)
      $ok = $task.Wait($t) -and $task.IsCompleted -and (-not $task.IsFaulted) -and $c.Connected
      if ($ok) { return $true }
    } catch { } finally { $c.Close() }
    return $false
  }
  $jobs = @()
  foreach ($h in $Hosts) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    $null = $ps.AddScript($code).AddArgument($h).AddArgument($Port).AddArgument($TimeoutMs)
    $jobs += [pscustomobject]@{ PS = $ps; Async = $ps.BeginInvoke(); Host = $h }
  }
  $open = New-Object System.Collections.Generic.List[string]
  foreach ($j in $jobs) {
    try {
      $r = $j.PS.EndInvoke($j.Async)
      if ($r -and $r[-1] -eq $true) { $open.Add($j.Host) }
    } catch { }
    try { $j.PS.Dispose() } catch { }
  }
  $pool.Close(); $pool.Dispose()
  return @($open)
}

function Get-ZebraSharesOnHost {
  param([string]$Target)
  try {
    $out = cmd /c "net view \\$Target 2>&1"
    return ($out -join "`n")
  } catch { return '' }
}

function Find-ZebraHosts {
  param($Cfg, [int]$LimitSeconds = 30)
  $shares = Get-ZebraShareNames $Cfg
  Write-ZebraLog ("شروع کشف هاست در شبکه؛ شیرها: {0} ..." -f ($shares -join ', '))
  $cands = Get-ZebraCandidates $Cfg
  Write-ZebraLog ("تعداد کاندیداها: {0} (شامل زیرشبکه محلی)" -f @($cands).Count)
  $open = Test-ZebraPortParallel -Hosts $cands -Port ([int]$Cfg.discovery.port) `
    -TimeoutMs ([int]$Cfg.discovery.timeoutMs) -MaxThreads ([int]$Cfg.discovery.maxThreads)
  Write-ZebraLog ("{0} سیستم با پورت SMB باز پیدا شد؛ در حال چک کردن شیرها ..." -f @($open).Count)

  $result = @()
  foreach ($h in $open) {
    $txt = Get-ZebraSharesOnHost $h
    $found = @($shares | Where-Object { $txt -match [regex]::Escape($_) })
    $name = $h
    try { $name = ([Net.Dns]::GetHostEntry($h)).HostName.Split('.')[0] } catch { }
    if (Test-ZebraIsSelf $h) { $name = "$name (این سیستم)" }
    $result += [pscustomobject]@{
      Name      = $name
      IP        = $h
      PortOpen  = $true
      Shares    = ($found -join ', ')
      Match     = ($found.Count -gt 0)
      IsSelf    = (Test-ZebraIsSelf $h)
    }
  }
  $matched = @($result | Where-Object { $_.Match -and -not $_.IsSelf })
  if ($matched.Count -gt 0) {
    Write-ZebraLog ("هاست پرینتر پیدا شد: {0} ({1}) → {2}" -f $matched[0].Name, $matched[0].IP, $matched[0].Shares) 'OK'
  } else {
    Write-ZebraLog 'هیچ سیستمی با شیر پرینتر پیدا نشد. روی سیستمی که کابل USB وصله است «نصب و اشتراک» را بزنید.' 'WARN'
  }
  return $result
}

function Set-ZebraDetectedHost {
  param($Cfg, $Row)
  if (-not $Row) { throw 'ردیفی انتخاب نشده است.' }
  $Cfg.host.name = [string]$Row.Name
  $Cfg.host.ip = [string]$Row.IP
  $Cfg.host.autoDetect = $false
  Save-ZebraConfig $Cfg
  $p = Get-ZebraProfile $Cfg $Cfg.defaultProfileId
  Sync-ZebraHostFile $Cfg $p
  Write-ZebraLog ("میزبان تنظیم شد: \\{0}\{1}" -f $Cfg.host.ip, $p.shareName) 'OK'
}

# ---------------------------------------------------------------- همگامسازی host.txt قدیمی
function Sync-ZebraHostFile {
  param($Cfg, $ZProfile)
  $lines = @([string]$Cfg.host.name, [string]$Cfg.host.ip, [string]$ZProfile.shareName, [string]$ZProfile.printUser)
  $path = Join-Path $script:ZebraRoot 'host.txt'
  [IO.File]::WriteAllLines($path, $lines, (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- درایور / پرینتر
function Install-ZebraDriver {
  param($ZProfile)
  $inf = Join-Path $script:ZebraRoot ([string]$ZProfile.driverInf)
  if (-not (Test-Path $inf)) { throw "فایل INF پیدا نشد: $inf" }
  Write-ZebraLog "نصب درایور: $($ZProfile.driverName)"
  $out = & pnputil.exe /add-driver $inf /install 2>&1
  foreach ($l in @($out)) { if ($l) { Write-ZebraLog ("  pnputil: {0}" -f $l) } }
  if (-not (Get-PrinterDriver -Name $ZProfile.driverName -ErrorAction SilentlyContinue)) {
    Add-PrinterDriver -Name $ZProfile.driverName
    Write-ZebraLog "  Add-PrinterDriver: $($ZProfile.driverName)" 'OK'
  }
}

function Find-ZebraUsbPort {
  param($ZProfile, [int]$WaitSeconds = 60)
  Write-ZebraLog "جستجوی پورت USB (راهنما: $($ZProfile.usbHint)) ... کابل و برق پرینتر چک شود."
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  do {
    $port = Get-PrinterPort -ErrorAction SilentlyContinue |
      Where-Object { $_.Description -match $ZProfile.usbHint -or $_.Name -match $ZProfile.usbHint } |
      Select-Object -First 1
    if ($port) { Write-ZebraLog "  پورت پیدا شد: $($port.Name)" 'OK'; return $port }
    Start-Sleep 2
  } while ((Get-Date) -lt $deadline)
  throw "پورت USB پرینتر پیدا نشد (راهنما: $($ZProfile.usbHint)). کابل/برق/درایور را بررسی کنید یا از دکمه «پرینترهای نصبشده» پورت را دستی انتخاب کنید."
}

function New-ZebraPrinter {
  param($ZProfile, $Port)
  $name = [string]$ZProfile.printerName
  Get-Printer -ErrorAction SilentlyContinue |
    Where-Object { $_.PortName -eq $Port.Name -and $_.Name -ne $name } |
    ForEach-Object {
      Write-ZebraLog "  حذف پرینتر اضافی روی همان پورت: $($_.Name)" 'WARN'
      Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
      Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
    }
  $p = Get-Printer -Name $name -ErrorAction SilentlyContinue
  if (-not $p) {
    Add-Printer -Name $name -DriverName $ZProfile.driverName -PortName $Port.Name
    Write-ZebraLog "  پرینتر ساخته شد: $name" 'OK'
  } elseif ($p.PortName -ne $Port.Name) {
    Set-Printer -Name $name -PortName $Port.Name
    Write-ZebraLog "  پورت پرینتر اصلاح شد: $($Port.Name)" 'OK'
  }
}

function Set-ZebraPrintSettings {
  param($ZProfile, [string]$PrinterName)
  if (-not $ZProfile.settingsPath) { Write-ZebraLog '  تنظیمات لیبل برای این پروفایل تعریف نشده، رد شد.'; return }
  $dir = Join-Path $script:ZebraRoot ([string]$ZProfile.settingsPath)
  $ticket = Join-Path $dir 'PrintTicket.xml'
  if (Test-Path $ticket) {
    Set-PrintConfiguration -PrinterName $PrinterName -PrintTicketXml ([IO.File]::ReadAllText($ticket))
    Write-ZebraLog '  PrintTicket اعمال شد (حرارتی مستقیم + اندازه لیبل)' 'OK'
  }
  foreach ($k in 'DevModePerUser', 'DevModes2') {
    $bin = Join-Path $dir "$k.bin"
    if (-not (Test-Path $bin)) { continue }
    $reg = "HKCU:\Printers\$k"
    if (-not (Test-Path $reg)) { New-Item $reg -Force | Out-Null }
    New-ItemProperty -Path $reg -Name $PrinterName -PropertyType Binary `
      -Value ([IO.File]::ReadAllBytes($bin)) -Force | Out-Null
  }
}

function Enable-ZebraShare {
  param($ZProfile)
  $name = [string]$ZProfile.printerName
  Set-Printer -Name $name -Shared $true -ShareName ([string]$ZProfile.shareName)
  Write-ZebraLog "  پرینتر Share شد: $($ZProfile.shareName)" 'OK'
  try {
    $sd = (Get-Printer -Name $name -Full).PermissionSDDL
    if ($sd) {
      $add = ''
      foreach ($sid in 'WD', 'BG', 'AN') {
        if ($sd -notmatch "\(A;;SWRC;;;$sid\)") { $add += "(A;;SWRC;;;$sid)(A;CIIO;GX;;;$sid)" }
      }
      if ($add) {
        $i = $sd.IndexOf('S:')
        $sd = if ($i -ge 0) { $sd.Insert($i, $add) } else { $sd + $add }
        Set-Printer -Name $name -PermissionSDDL $sd
        Write-ZebraLog '  دسترسی چاپ به Everyone / Guests / Anonymous داده شد' 'OK'
      }
    }
  } catch { Write-ZebraLog "  تنظیم PermissionSDDL: $($_.Exception.Message)" 'WARN' }
}

function Enable-ZebraSharingServices {
  $rules = Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -ErrorAction SilentlyContinue
  if (-not $rules) { $rules = Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue }
  $rules = $rules | Where-Object { $_.Profile -match 'Private|Any' }
  if ($rules) { $rules | Enable-NetFirewallRule; Write-ZebraLog '  فایروال File and Printer Sharing (Private) باز شد' 'OK' }
  else { Write-ZebraLog '  قانون فایروال پیدا نشد؛ از Advanced sharing settings باز کنید.' 'WARN' }
  foreach ($svc in 'Spooler', 'LanmanServer') {
    try {
      Set-Service $svc -StartupType Automatic
      if ((Get-Service $svc).Status -ne 'Running') { Start-Service $svc }
    } catch { Write-ZebraLog "  سرویس $svc : $($_.Exception.Message)" 'WARN' }
  }
  $pub = Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public'
  if ($pub) { Write-ZebraLog "  شبکه '$($pub[0].Name)' از نوع Public است؛ آن را Private کنید تا بقیه سیستمها پرینتر را ببینند." 'WARN' }
}

function New-ZebraPrintUser {
  param($ZProfile, [SecureString]$Password)
  if (-not $Password) { Write-ZebraLog '  کاربر چاپ ساخته نشد (دسترسی مهمان/Everyone کافی است).' 'WARN'; return }
  $u = [string]$ZProfile.printUser
  if (-not $u) { return }
  if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $u -Password $Password -PasswordNeverExpires $true
    Enable-LocalUser -Name $u
  } else {
    New-LocalUser -Name $u -Password $Password -PasswordNeverExpires `
      -UserMayNotChangePassword -Description 'Network printing (Zebra Manager)' | Out-Null
  }
  $grp = (Get-LocalGroup -SID 'S-1-5-32-545').Name
  if (-not (Get-LocalGroupMember -Group $grp -Member $u -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group $grp -Member $u
  }
  $hide = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
  if (-not (Test-Path $hide)) { New-Item $hide -Force | Out-Null }
  New-ItemProperty -Path $hide -Name $u -PropertyType DWord -Value 0 -Force | Out-Null
  Write-ZebraLog "  کاربر چاپ '$u' ساخته/بروز شد" 'OK'
}

# ---------------------------------------------------------------- نصب بهعنوان میزبان
function Install-ZebraHost {
  param($Cfg, $ZProfile, [SecureString]$PrintPassword, [string]$PortName = '', [switch]$SkipLabelServer)
  if (-not (Test-ZebraAdmin)) { throw 'برای نصب و اشتراک، نرمافزار باید با دسترسی Administrator اجرا شود.' }
  Write-ZebraLog "==== نصب بهعنوان میزبان: $($ZProfile.name) ====" 'OK'
  Install-ZebraDriver $ZProfile
  $port = if ($PortName) { Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue } else { $null }
  if (-not $port) { $port = Find-ZebraUsbPort $ZProfile }
  New-ZebraPrinter $ZProfile $port
  Set-ZebraPrintSettings $ZProfile ([string]$ZProfile.printerName)
  Enable-ZebraShare $ZProfile
  Enable-ZebraSharingServices
  New-ZebraPrintUser $ZProfile $PrintPassword

  # این سیستم میزبان است؛ نام/IP خودش ذخیره میشود، هیچ اسمی هاردکد نیست
  $id = Get-ZebraLocalIdentity
  $Cfg.host.name = $id.Name
  $Cfg.host.ip = @($id.IPs)[0]
  $Cfg.host.autoDetect = $false
  Save-ZebraConfig $Cfg
  Sync-ZebraHostFile $Cfg $ZProfile

  if (-not $SkipLabelServer -and $Cfg.labelServer.enabled) {
    try { Install-ZebraLabelServer $Cfg $ZProfile }
    catch { Write-ZebraLog "  سرور لیبل موبایل: $($_.Exception.Message)" 'WARN' }
  }
  Write-ZebraLog ("==== انجام شد. آدرس پرینتر روی شبکه: \\{0}\{1} ====" -f $Cfg.host.ip, $ZProfile.shareName) 'OK'
  return $Cfg
}

function Install-ZebraLabelServer {
  param($Cfg, $ZProfile)
  $s = Join-Path $script:ZebraRoot 'install-label-server.ps1'
  if (-not (Test-Path $s)) { throw 'install-label-server.ps1 پیدا نشد.' }
  $out = & $s -NoPause 2>&1
  foreach ($l in @($out)) { if ($l) { Write-ZebraLog ("  server: {0}" -f $l) } }
}

# ---------------------------------------------------------------- پاکسازی بقایای میزبان قدیمی
function Remove-ZebraFormerHost {
  param(
    $Cfg, $ZProfile,
    [ValidateSet('full', 'minimal', 'report')][string]$Mode = 'full',
    [string[]]$StalePrefixes = @(),
    [switch]$Quiet
  )
  $id = Get-ZebraLocalIdentity
  $selfPrefixes = @($id.Names) + @($id.IPs)
  $old = @($StalePrefixes) + @($Cfg.host.name, $Cfg.host.ip)
  $prefixes = @($selfPrefixes + $old) | Where-Object { $_ } | Select-Object -Unique
  $report = New-Object System.Collections.Generic.List[string]
  $do = ($Mode -ne 'report')

  if (-not $Quiet) { Write-ZebraLog "==== پاکسازی بقایای میزبانی قدیمی (حالت $Mode) ====" 'OK' }

  # 1) پرینترها و پورتها
  $printers = @(Get-Printer -ErrorAction SilentlyContinue)
  foreach ($p in $printers) {
    $stale = $false
    if ($p.Name -eq $ZProfile.printerName) { $stale = $true }
    if ($p.Name -like 'ZDesigner ZD888*') { $stale = $true }
    if ($p.PortName) {
      foreach ($x in $prefixes) {
        if ($p.PortName -match ('^\\\\' + [regex]::Escape($x) + '\\')) { $stale = $true; break }
      }
    }
    if (-not $stale) { continue }
    $report.Add("پرینتر: $($p.Name)  [پورت: $($p.PortName)]")
    if ($do) {
      Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
      Remove-Printer -Name $p.Name -ErrorAction SilentlyContinue
    }
  }
  $ports = @(Get-PrinterPort -ErrorAction SilentlyContinue)
  foreach ($p in $ports) {
    $stale = $false
    foreach ($x in $prefixes) {
      if ($p.Name -match ('^\\\\' + [regex]::Escape($x) + '\\')) { $stale = $true; break }
    }
    if (-not $stale) { continue }
    $report.Add("پورت: $($p.Name)")
    if ($do) { Remove-PrinterPort -Name $p.Name -ErrorAction SilentlyContinue }
  }

  # 2) Share قدیمی روی همین سیستم
  foreach ($p in $printers) {
    if ($p.Shared -and $p.ShareName -eq $ZProfile.shareName) {
      $report.Add("اشتراک: $($p.ShareName) روی $($p.Name)")
      if ($do) { Set-Printer -Name $p.Name -Shared $false -ErrorAction SilentlyContinue }
    }
  }

  if ($Mode -eq 'minimal') {
    foreach ($r in $report) { Write-ZebraLog "  $r" }
    return @($report)
  }

  # 3) credential / اتصالهای SMB قدیمی
  if ($Cfg.cleanup.removeOldCredentials) {
    foreach ($x in $prefixes) {
      $report.Add("credential: $x")
      if ($do) {
        cmd /c "cmdkey /delete:$x >nul 2>&1"
        cmd /c "net use \\$x\IPC$ /delete /y >nul 2>&1"
      }
    }
  }

  # 4) تسک سرور لیبل / urlacl / فایروال / پوشه
  if ($Cfg.cleanup.removeLabelServer) {
    $tn = [string]$Cfg.labelServer.taskName
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
      $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
      if ($t) {
        $report.Add("تسک: $tn")
        if ($do) {
          Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
          Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        }
      }
    }
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
      $fw = Get-NetFirewallRule -DisplayName $tn -ErrorAction SilentlyContinue
      if ($fw) { $report.Add("فایروال: $tn"); if ($do) { $fw | Remove-NetFirewallRule -ErrorAction SilentlyContinue } }
    }
    $dest = [string]$Cfg.labelServer.dest
    if ($dest -and (Test-Path $dest)) {
      $report.Add("پوشه: $dest")
      if ($do) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  if ($Cfg.cleanup.removeUrlAcl) {
    $u = "http://+:$( [int]$Cfg.labelServer.port )/"
    $report.Add("urlacl: $u")
    if ($do) { cmd /c "netsh http delete urlacl url=$u >nul 2>&1" }
  }

  # 5) کاربر محلی چاپ (فقط روی میزبان قدیمی معنی دارد)
  if ($Cfg.cleanup.removePrintUser -and $ZProfile.printUser) {
    $u = [string]$ZProfile.printUser
    if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) {
      $report.Add("کاربر محلی: $u")
      if ($do) {
        Remove-LocalUser -Name $u -ErrorAction SilentlyContinue
        $hide = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
        if (Test-Path $hide) { Remove-ItemProperty -Path $hide -Name $u -ErrorAction SilentlyContinue }
      }
    }
  }

  # 6) DEVMODEهای رجیستری
  foreach ($k in 'DevModePerUser', 'DevModes2') {
    $reg = "HKCU:\Printers\$k"
    if (-not (Test-Path $reg)) { continue }
    try {
      $vals = (Get-Item $reg).GetValueNames()
      foreach ($v in $vals) {
        if ($v -like "*$($ZProfile.printerName)*") {
          $report.Add("رجیستری: $k\$v")
          if ($do) { Remove-ItemProperty -Path $reg -Name $v -Force -ErrorAction SilentlyContinue }
        }
      }
    } catch { }
  }

  if ($do) {
    try { Restart-Service Spooler -Force -ErrorAction SilentlyContinue } catch { }
    Write-ZebraLog ("پاکسازی انجام شد ({0} مورد)." -f $report.Count) 'OK'
  } else {
    Write-ZebraLog ("گزارش پاکسازی ({0} مورد) — هیچ چیز حذف نشد." -f $report.Count) 'WARN'
  }
  foreach ($r in $report) { Write-ZebraLog "  $r" }
  return @($report)
}

# ---------------------------------------------------------------- اتصال بهعنوان کلاینت
function Connect-ZebraClient {
  param(
    $Cfg, $ZProfile,
    [string]$Target = '',
    [SecureString]$PrintPassword = $null,
    [switch]$SkipCleanup
  )
  if (-not (Test-ZebraAdmin)) { throw 'برای اتصال، نرمافزار باید با دسترسی Administrator اجرا شود.' }

  # تعیین هاست: پارامتر > کانفیگ > کشف خودکار (بدون هیچ نام هاردکد)
  if (-not $Target) { $Target = [string]$Cfg.host.ip }
  if (-not $Target) { $Target = [string]$Cfg.host.name }
  if (-not $Target -or (Test-ZebraIsSelf $Target)) {
    if ((Test-ZebraIsSelf $Target)) { Write-ZebraLog 'کانفیگ قدیمی به همین سیستم اشاره میکند (میزبان سابق)؛ نادیده گرفته شد.' 'WARN' }
    Write-ZebraLog 'هاست مشخص نیست → جستجوی خودکار در شبکه ...'
    $rows = Find-ZebraHosts $Cfg
    $hit = @($rows | Where-Object { $_.Match -and -not $_.IsSelf } | Select-Object -First 1)
    if ($hit.Count -eq 0) { throw 'هیچ میزبانی با شیر پرینتر پیدا نشد. اول روی سیستمی که کابل USB وصله است «نصب و اشتراک» را بزنید.' }
    $Target = [string]$hit[0].IP
    $Cfg.host.name = [string]$hit[0].Name
    $Cfg.host.ip = $Target
    $Cfg.host.autoDetect = $false
    Save-ZebraConfig $Cfg
    Sync-ZebraHostFile $Cfg $ZProfile
  }

  $conn = '\\' + $Target + '\' + $ZProfile.shareName
  Write-ZebraLog "==== اتصال به $conn بهعنوان کلاینت ====" 'OK'

  # پاکسازی بقایای میزبانی قدیمی، بهجز اتصالهایی که به هاست جدید هستند
  if (-not $SkipCleanup) {
    $old = @([string]$Cfg.host.name, [string]$Cfg.host.ip) | Where-Object { $_ -and $_ -ne $Target }
    Remove-ZebraFormerHost -Cfg $Cfg -Profile $ZProfile -Mode ([string]$Cfg.cleanup.mode) -StalePrefixes $old | Out-Null
  }

  # رمز کاربر چاپ (اختیاری)
  if ($PrintPassword -and $ZProfile.printUser) {
    $sec = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrintPassword))
    cmd /c "net use \\$Target\IPC$ /delete /y >nul 2>&1"
    cmd /c "cmdkey /add:$Target /user:`"$($Cfg.host.name)\$($ZProfile.printUser)`" /pass:`"$sec`" >nul 2>&1"
    cmd /c "net use \\$Target\IPC$ /user:$($Cfg.host.name)\$($ZProfile.printUser) `"$sec`" >nul 2>&1"
    Write-ZebraLog "  ورود کاربر $($ZProfile.printUser) ذخیره شد" 'OK'
  }

  Install-ZebraDriver $ZProfile

  $localName = "$($ZProfile.printerName) ($Target)"
  $isOurs = {
    param($p)
    $p.Name -ieq $conn -or $p.Name -eq $localName -or $p.PortName -ieq $conn -or
    ($p.Type -eq 'Connection' -and $p.Name -like "\\$Target\*")
  }
  $printer = Get-Printer | Where-Object { & $isOurs $_ } | Select-Object -First 1
  if (-not $printer) {
    try {
      Add-Printer -ConnectionName $conn -ErrorAction Stop
      $printer = Get-Printer | Where-Object { & $isOurs $_ } | Select-Object -First 1
    } catch {
      Write-ZebraLog "  اتصال معمولی ویندوز blockers شد (0x11b) → روش پورت محلی" 'WARN'
      if (-not (Get-PrinterPort -Name $conn -ErrorAction SilentlyContinue)) { Add-PrinterPort -Name $conn }
      Add-Printer -Name $localName -DriverName $ZProfile.driverName -PortName $conn
      $printer = Get-Printer -Name $localName
      Set-ZebraPrintSettings $ZProfile $localName
    }
  }
  if (-not $printer) { throw "اتصال به $conn برقرار نشد." }
  Write-ZebraLog "  متصل شد: $($printer.Name)" 'OK'
  try { Set-ZebraPrintSettings $ZProfile ([string]$printer.Name) } catch {
    Write-ZebraLog "  تنظیمات اینجا اعمال نشد؛ تنظیمات میزبان استفاده میشود." 'WARN'
  }
  return $printer.Name
}

# ---------------------------------------------------------------- وضعیت / عیبیابی
function Get-ZebraStatus {
  param($Cfg, $ZProfile)
  $id = Get-ZebraLocalIdentity
  $o = New-Object System.Collections.Generic.List[string]
  $o.Add('=== این سیستم ===')
  $o.Add(('  نام: {0}    IPها: {1}' -f $id.Name, ($id.IPs -join ', ')))
  $o.Add(('  ادمین: {0}' -f (Test-ZebraAdmin)))
  try {
    $prof = Get-NetConnectionProfile | Select-Object -First 1
    $o.Add(('  پروفایل شبکه: {0}' -f $prof.NetworkCategory))
  } catch { }
  foreach ($svc in 'Spooler', 'LanmanServer') {
    try { $o.Add(('  سرویس {0}: {1}' -f $svc, (Get-Service $svc).Status)) } catch { }
  }
  $o.Add('')
  $o.Add('=== پروفایل فعال ===')
  $o.Add(('  {0}  |  درایور: {1}  |  شیر: {2}' -f $ZProfile.name, $ZProfile.driverName, $ZProfile.shareName))
  $o.Add(('  میزبان ثبتشده: {0} ({1})' -f $(if ($Cfg.host.name) { $Cfg.host.name } else { 'نامشخص' }),
    $(if ($Cfg.host.ip) { $Cfg.host.ip } else { '-' })))
  $o.Add('')
  $o.Add('=== پرینترهای نصبشده ===')
  try {
    $ps = @(Get-Printer -ErrorAction Stop)
    if ($ps.Count -eq 0) { $o.Add('  (هیچ پرینتری نصب نیست)') }
    foreach ($p in $ps) {
      $jobs = 0
      try { $jobs = @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue).Count } catch { }
      $shared = if ($p.Shared) { " | SHARED: $($p.ShareName)" } else { '' }
      $o.Add(('  {0}  [{1}]  پورت={2}  وضعیت={3}  صف={4}{5}' -f
        $p.Name, $p.Type, $p.PortName, $p.PrinterStatus, $jobs, $shared))
    }
  } catch { $o.Add("  خطا: $($_.Exception.Message)") }
  $o.Add('')
  $o.Add('=== سرور لیبل موبایل ===')
  try {
    $t = Get-ScheduledTask -TaskName $Cfg.labelServer.taskName -ErrorAction SilentlyContinue
    $o.Add(('  تسک {0}: {1}' -f $Cfg.labelServer.taskName, $(if ($t) { $t.State } else { 'نصب نشده' })))
  } catch { }
  return ($o -join [Environment]::NewLine)
}

function Invoke-ZebraDiagnose {
  param($Cfg)
  $s = Join-Path $script:ZebraRoot 'diagnose.ps1'
  if (-not (Test-Path $s)) { throw 'diagnose.ps1 پیدا نشد.' }
  $before = @(Get-ChildItem $script:ZebraRoot -Filter 'diag-*.txt' | Select-Object -ExpandProperty FullName)
  $out = & $s -NoPause 2>&1
  foreach ($l in @($out)) { if ($l) { Write-ZebraLog ("  diag: {0}" -f $l) } }
  $after = @(Get-ChildItem $script:ZebraRoot -Filter 'diag-*.txt' | Sort-Object LastWriteTime -Descending)
  return $(if ($after.Count -gt 0) { $after[0].FullName } else { '(لاگ جدیدی ساخته نشد)' })
}

function Get-ZebraAdoptablePrinters {
  return @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
      Name       = $_.Name
      DriverName = $_.DriverName
      PortName   = $_.PortName
      Type       = $_.Type
      Shared     = $_.Shared
    }
  })
}

function New-ZebraProfileId {
  param([string]$Name)
  $s = ($Name -replace '[^\w\u0600-\u06FF]+', '-').Trim('-').ToLower()
  if (-not $s) { $s = 'printer' }
  return $s
}
