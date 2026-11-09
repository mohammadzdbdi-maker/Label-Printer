# ساخت کاربر مخصوص چاپ روی کامپیوتری که پرینتر به آن وصل است (add-print-user.bat)
# بقیه‌ی کامپیوترها با این کاربر و رمز به پرینتر وصل می‌شوند. حساب اصلی ویندوز بدون رمز می‌ماند.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
  exit
}

$ErrorActionPreference = 'Stop'
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$PrintUser = 'zebraprint'

function Step($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   OK: $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !! $t" -ForegroundColor Yellow }

try {
  Step "Creating print user '$PrintUser'..."
  Write-Host '   Choose a password for printing (you will type it once on each other PC).'
  do {
    $p1 = Read-Host '   Password' -AsSecureString
    $p2 = Read-Host '   Repeat password' -AsSecureString
    $s1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
    $s2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
    if (-not $s1) { Warn 'Password cannot be empty.' } elseif ($s1 -ne $s2) { Warn 'Passwords do not match, try again.' }
  } until ($s1 -and $s1 -eq $s2)

  if (Get-LocalUser -Name $PrintUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $PrintUser -Password $p1 -PasswordNeverExpires $true
    Enable-LocalUser -Name $PrintUser
    Ok 'User already existed - password updated'
  } else {
    New-LocalUser -Name $PrintUser -Password $p1 -PasswordNeverExpires -UserMayNotChangePassword -Description 'Network printing (Zebra)' | Out-Null
    Ok 'User created'
  }
  $usersGroup = (Get-LocalGroup -SID 'S-1-5-32-545').Name
  if (-not (Get-LocalGroupMember -Group $usersGroup -Member $PrintUser -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group $usersGroup -Member $PrintUser
  }

  # در صفحه‌ی ورود ویندوز نشان داده نشود
  $hide = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
  if (-not (Test-Path $hide)) { New-Item $hide -Force | Out-Null }
  New-ItemProperty -Path $hide -Name $PrintUser -PropertyType DWord -Value 0 -Force | Out-Null
  Ok 'Hidden from the Windows login screen'

  # نام کاربر در host.txt برای اسکریپت کامپیوترهای دیگر
  $hostFile = "$here\host.txt"
  $lines = @(if (Test-Path $hostFile) { Get-Content $hostFile } else { @($env:COMPUTERNAME, '', 'ZebraLabel') })
  while ($lines.Count -lt 4) { $lines += '' }
  $lines[3] = $PrintUser
  $lines | Set-Content $hostFile -Encoding ASCII
  Ok 'Saved user name to host.txt'

  Write-Host "`n==== DONE ====" -ForegroundColor Green
  Write-Host "On the other PCs run connect-client.bat and enter this password when asked."
}
catch {
  Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
