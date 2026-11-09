# اشتراک‌گذاری پرینتر Zebra روی شبکه
# این را روی کامپیوتری اجرا کنید که پرینتر با USB به آن وصل است (share-host.bat)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
  exit
}

$ErrorActionPreference = 'Stop'
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$PrinterName = 'Zebra GK888t - EPL'
$ShareName   = 'ZebraLabel'

function Step($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   OK: $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !! $t" -ForegroundColor Yellow }

try {
  Step 'Checking printer...'
  if (-not (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
    throw "Printer '$PrinterName' is not installed on this PC. Run install.bat first."
  }
  Ok $PrinterName

  # 1) اشتراک‌گذاری
  Step 'Sharing printer...'
  Set-Printer -Name $PrinterName -Shared $true -ShareName $ShareName
  Ok "Shared as: $ShareName"

  # اجازه‌ی چاپ برای همه‌ی کاربران شبکه (Everyone، Guests، و اتصال بدون رمز)
  $sd = (Get-Printer -Name $PrinterName -Full).PermissionSDDL
  $add = ''
  foreach ($sid in 'WD', 'BG', 'AN') {
    if ($sd -notmatch "\(A;;SWRC;;;$sid\)") { $add += "(A;;SWRC;;;$sid)(A;CIIO;GX;;;$sid)" }
  }
  if ($add) {
    $i = $sd.IndexOf('S:')
    $sd = if ($i -ge 0) { $sd.Insert($i, $add) } else { $sd + $add }
    Set-Printer -Name $PrinterName -PermissionSDDL $sd
  }
  Ok 'Print permission given to all network users'

  # پاک کردن کارهای چاپی گیرکرده (نیمه‌کاره یا خطادار، قدیمی‌تر از ۱۰ دقیقه)
  $stuck = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue |
    Where-Object { $_.JobStatus -match 'Spooling|Error|Deleting' -and $_.SubmittedTime -lt (Get-Date).AddMinutes(-10) }
  if ($stuck) {
    $stuck | ForEach-Object { Remove-PrintJob -InputObject $_ -ErrorAction SilentlyContinue }
    Ok "Removed $(@($stuck).Count) stuck print job(s)"
    if (Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue | Where-Object { $_.JobStatus -match 'Deleting' }) {
      Restart-Service Spooler -Force
      Ok 'Print Spooler restarted to clear the queue'
    }
  }

  # 2) فایروال: File and Printer Sharing برای شبکه‌ی Private
  Step 'Opening firewall for printer sharing (private network)...'
  $rules = Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -ErrorAction SilentlyContinue
  if (-not $rules) { $rules = Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue }
  $rules = $rules | Where-Object { $_.Profile -match 'Private|Any' }
  if ($rules) {
    $rules | Enable-NetFirewallRule
    Ok 'File and Printer Sharing enabled'
  } else {
    Warn 'Firewall rules not found. Turn on "File and printer sharing" manually:'
    Warn 'Control Panel > Network and Sharing Center > Advanced sharing settings > Private.'
  }

  $public = Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public'
  if ($public) {
    Warn "Network '$($public[0].Name)' is set to Public - other PCs may not see this printer."
    Warn 'Settings > Network & Internet > Properties > set network profile to Private.'
  }

  # 3) سرویس‌های لازم
  foreach ($svc in 'Spooler', 'LanmanServer') {
    Set-Service $svc -StartupType Automatic
    if ((Get-Service $svc).Status -ne 'Running') { Start-Service $svc }
  }
  Ok 'Print Spooler and Server services running'

  # 4) ذخیره نام این کامپیوتر برای اسکریپت کامپیوترهای دیگر
  $ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } |
    Select-Object -First 1).IPAddress
  "$env:COMPUTERNAME`r`n$ip`r`n$ShareName" | Set-Content "$here\host.txt" -Encoding ASCII
  Ok 'Saved connection info to host.txt'

  Write-Host "`n==== DONE ====" -ForegroundColor Green
  Write-Host "Printer address on the network:" -NoNewline
  Write-Host "  \\$env:COMPUTERNAME\$ShareName" -ForegroundColor Yellow
  Write-Host "Or by IP:                       " -NoNewline
  Write-Host "  \\$ip\$ShareName" -ForegroundColor Yellow
  Write-Host "`nNow copy this whole folder to the other PCs and run connect-client.bat there."
  Write-Host 'This PC must stay ON for others to print.'
}
catch {
  Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
