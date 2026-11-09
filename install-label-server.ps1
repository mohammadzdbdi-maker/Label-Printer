# نصب سرور لیبل ساختنی برای گوشی‌ها - روی کامپیوتری که پرینتر به آن وصل است (install-label-server.bat)
# بعد از نصب، با هر بار ورود به ویندوز خودکار اجرا می‌شود.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
  exit
}

$ErrorActionPreference = 'Stop'
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dest        = 'C:\ZebraLabelServer'
$Port        = 8080
$PrinterName = 'Zebra GK888t - EPL'
$TaskName    = 'Zebra Label Server'

function Step($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   OK: $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !! $t" -ForegroundColor Yellow }

try {
  Step 'Checking printer...'
  if (-not (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) { throw "Printer '$PrinterName' is not on this PC. Run this on the PC the printer is plugged into." }
  Ok $PrinterName

  # 1) توقف نسخهٔ قبلی (اگر هست) و کپی فایل‌ها
  Step "Copying files to $Dest ..."
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'ZebraLabelServer\\server\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force $Dest | Out-Null
  Copy-Item "$here\label-server\*" $Dest -Recurse -Force -Exclude 'server.log*'
  Ok 'Files copied'

  # 2) اجازهٔ گوش دادن روی پورت و باز کردن فایروال
  Step "Opening port $Port for phones on the network..."
  netsh http delete urlacl url=http://+:$Port/ 2>&1 | Out-Null
  netsh http add urlacl url=http://+:$Port/ sddl='D:(A;;GX;;;WD)' | Out-Null
  Get-NetFirewallRule -DisplayName $TaskName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $TaskName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Private, Domain | Out-Null
  Ok "Port $Port open (private network)"
  if (Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public') { Warn 'Network is Public - phones cannot connect until it is set to Private.' }

  # 3) اجرای خودکار با ورود به ویندوز (با همین کاربر، تا تنظیمات پرینتر همین کاربر استفاده شود)
  Step 'Setting it to start automatically...'
  $user   = "$env:USERDOMAIN\$env:USERNAME"
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Dest\server.ps1`" -Port $Port -PrinterName `"$PrinterName`""
  $trig   = New-ScheduledTaskTrigger -AtLogOn -User $user
  $set    = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  $prin   = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trig -Settings $set -Principal $prin -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Ok "Starts at every logon of $user"

  # 4) بررسی
  Step 'Testing...'
  $okResp = $false
  for ($i = 0; $i -lt 10 -and -not $okResp; $i++) {
    Start-Sleep 1
    try { $r = Invoke-RestMethod "http://localhost:$Port/status" -TimeoutSec 3; $okResp = $true } catch { }
  }
  if ($okResp) { Ok "Server answers: printer = $($r.text)" } else { Warn "Server did not answer yet - check $Dest\server.log" }

  $ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress

  Write-Host "`n==== DONE ====" -ForegroundColor Green
  Write-Host 'On a phone connected to the pharmacy Wi-Fi, open in the browser:'
  Write-Host "     http://$ip`:$Port" -ForegroundColor Yellow
  Write-Host 'Then use the browser menu > "Add to Home screen" for an app icon.'
  Write-Host "`nTip: reserve this IP ($ip) for this PC in the router so the address never changes."
}
catch {
  Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
