# -*- coding: utf-8 -*-
# تعمیر یککلیک سیستمی که قبلاً «میزبان» پرینتر بوده و حالا میخواهد «کلاینت» باشد
# (مخصوص سیستمی که قبلا هاست پرینتر بوده): بقایا پاک، هاست جدید پیدا، وصل میشود.
# نیازی نیست نام هیچ کامپیوتری را بدانیم.

param([switch]$NoPause, [switch]$NoElevate, [string]$TargetHost)

$ErrorActionPreference = 'Stop'
$ZebraRootOverride = Split-Path -Parent $PSScriptRoot
. (Join-Path $ZebraRootOverride 'lib\Zebra.ps1')

if (-not (Test-ZebraAdmin)) {
  if ($NoElevate) { throw 'برای پاکسازی و اتصال، دسترسی Administrator لازم است.' }
  $quoted = '"' + $MyInvocation.MyCommand.Path + '"'
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quoted, '-NoElevate')
  if ($NoPause) { $a += '-NoPause' }
  if ($TargetHost) { $a += '-TargetHost'; $a += $TargetHost }
  Start-Process powershell -Verb RunAs -ArgumentList $a
  exit
}

$cfg = Initialize-Zebra
$p = Get-ZebraProfile $cfg $cfg.defaultProfileId

Write-ZebraLog '==== تعمیر سیستم میزبان سابق → کلاینت ====' 'OK'
Write-ZebraLog "سیستم: $env:COMPUTERNAME | پروفایل: $($p.name)"

try {
  # ۱) پاکسازی کامل: پرینتر/پورت/شیر/credential/تسک سرور/urlacl/کاربر چاپ/DEVMODE
  $rows = Remove-ZebraFormerHost $cfg $p 'full'
  Write-ZebraLog ("تعداد موارد پاکشده: {0}" -f @($rows).Count) 'OK'

  # ۲) پیدا کردن خودکار هاست جدید (یا استفاده از -TargetHost) و اتصال
  $name = Connect-ZebraClient $cfg $p -Target $TargetHost
  Write-ZebraLog "اتصال برقرار شد: $name" 'OK'
  Write-ZebraLog (Get-ZebraStatus $cfg $p)
} catch {
  Write-ZebraLog "خطا: $($_.Exception.Message)" 'ERROR'
}

if (-not $NoPause) { Read-Host "`nPress Enter to close" }
