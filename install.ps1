# نصب خودکار پرینتر Zebra GK888t - حرارتی مستقیم، لیبل 58x40 میلی‌متر
# اجرا: روی install.bat دوبار کلیک کنید (خودش دسترسی ادمین می‌گیرد)

# اگر ادمین نیست، خودش را با دسترسی ادمین دوباره اجرا می‌کند
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
  exit
}

$ErrorActionPreference = 'Stop'
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$PrinterName = 'Zebra GK888t - EPL'
$DriverName  = 'Zebra GK888t - EPL'

function Step($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   OK: $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !! $t" -ForegroundColor Yellow }

# ---------- ارسال مستقیم دستور به پرینتر ----------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class RawPrinter {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public class DOCINFO { public string pDocName; public string pOutputFile; public string pDataType; }
  [DllImport("winspool.drv", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool OpenPrinter(string n, out IntPtr h, IntPtr d);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool ClosePrinter(IntPtr h);
  [DllImport("winspool.drv", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int StartDocPrinter(IntPtr h, int l, DOCINFO di);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool EndDocPrinter(IntPtr h);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool StartPagePrinter(IntPtr h);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool EndPagePrinter(IntPtr h);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool WritePrinter(IntPtr h, byte[] b, int c, out int w);
  public static int Send(string printer, byte[] bytes, string doc) {
    IntPtr h; if (!OpenPrinter(printer, out h, IntPtr.Zero)) return -Marshal.GetLastWin32Error();
    var di = new DOCINFO { pDocName = doc, pDataType = "RAW" };
    StartDocPrinter(h, 1, di); StartPagePrinter(h);
    int w; WritePrinter(h, bytes, bytes.Length, out w);
    EndPagePrinter(h); EndDocPrinter(h); ClosePrinter(h); return w;
  }
}
"@
function Send-Raw($data, $doc) { [RawPrinter]::Send($PrinterName, [Text.Encoding]::ASCII.GetBytes($data), $doc) | Out-Null }

try {
  # 1) نصب درایور
  Step 'Installing driver...'
  pnputil /add-driver "$here\driver\zebra.inf" /install | Out-Null
  if (-not (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue)) {
    Add-PrinterDriver -Name $DriverName
  }
  Ok "Driver: $DriverName"

  # 2) پیدا کردن پورت USB پرینتر
  Step 'Looking for the printer on USB (it must be plugged in and ON)...'
  $port = $null
  for ($i = 0; $i -lt 60 -and -not $port; $i++) {
    $port = Get-PrinterPort | Where-Object { $_.Description -match 'GK888' } | Select-Object -First 1
    if (-not $port) {
      if ($i -eq 0) { Warn 'Printer not found. Plug in the USB cable and turn the printer on... (waiting 2 minutes)' }
      Start-Sleep 2
    }
  }
  if (-not $port) { throw 'Printer not found on USB. Check the cable and power, then run again.' }
  Ok "Port: $($port.Name)"

  # 3) حذف صف‌های اضافه روی همین پورت (مثلا درایور اشتباهی که ویندوز خودش نصب کرده)
  Get-Printer | Where-Object { $_.PortName -eq $port.Name -and $_.Name -ne $PrinterName } | ForEach-Object {
    Warn "Removing extra printer on the same port: $($_.Name)"
    Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
    Remove-Printer -Name $_.Name
  }

  # 4) ساخت پرینتر
  Step 'Creating printer...'
  $p = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
  if (-not $p) { Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $port.Name }
  elseif ($p.PortName -ne $port.Name) { Set-Printer -Name $PrinterName -PortName $port.Name }
  Ok $PrinterName

  # 5) تنظیمات: حرارتی مستقیم + لیبل 58x40
  Step 'Applying settings (Direct Thermal, 58x40 mm)...'
  $ticket = [IO.File]::ReadAllText("$here\settings\PrintTicket.xml")
  Set-PrintConfiguration -PrinterName $PrinterName -PrintTicketXml $ticket
  foreach ($k in 'DevModePerUser', 'DevModes2') {
    $reg = "HKCU:\Printers\$k"
    if (-not (Test-Path $reg)) { New-Item $reg -Force | Out-Null }
    New-ItemProperty -Path $reg -Name $PrinterName -PropertyType Binary -Value ([IO.File]::ReadAllBytes("$here\settings\$k.bin")) -Force | Out-Null
  }
  $t = (Get-PrintConfiguration -PrinterName $PrinterName).PrintTicketXML
  $method = [regex]::Match($t, 'JobPrintMethod">\s*<psf:Option name="[^"]+:(opt\d)"').Groups[1].Value
  $w = [regex]::Match($t, 'MediaSizeWidth">\s*<psf:Value[^>]*>(\d+)').Groups[1].Value
  $h = [regex]::Match($t, 'MediaSizeHeight">\s*<psf:Value[^>]*>(\d+)').Groups[1].Value
  if ($method -eq 'opt0') { Ok 'Print method: Direct Thermal' } else { Warn 'Print method is not Direct Thermal - set it in Printing Preferences > Stock' }
  Ok ("Printer default size: {0:N1} x {1:N1} mm" -f ($w / 1000), ($h / 1000))

  # 6) تنظیم خود پرینتر و کالیبره
  Step 'Setting printer to Direct Thermal and calibrating (a few blank labels will feed)...'
  Send-Raw "`r`nOD`r`nq464`r`nxa`r`n" 'calibrate'
  Start-Sleep 8
  Ok 'Calibration sent'

  # 7) لیبل تست از طریق درایور
  Step 'Printing a test label...'
  Add-Type -AssemblyName System.Drawing
  $d = New-Object System.Drawing.Printing.PrintDocument
  $d.PrinterSettings.PrinterName = $PrinterName
  $d.DocumentName = 'test-58x40'
  $d.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
  $d.add_PrintPage({
    param($s, $e)
    $g = $e.Graphics; $g.PageUnit = [System.Drawing.GraphicsUnit]::Millimeter
    $g.DrawRectangle((New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 0.4)), 1.5, 1.5, 55, 37)
    $g.DrawString('TEST 58x40', (New-Object System.Drawing.Font('Tahoma', 12, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::Black, 8, 15)
  })
  $d.Print()
  Ok 'Test label sent - the frame should fit on ONE label'

  # 8) کپی برنامه لیبل‌زن روی دسکتاپ
  $app = Get-ChildItem $here -Filter '*.html' | Select-Object -First 1
  if ($app) {
    Copy-Item $app.FullName ([Environment]::GetFolderPath('Desktop')) -Force
    Ok "Label app copied to Desktop: $($app.Name)"
  }

  Write-Host "`n==== DONE ====" -ForegroundColor Green
  Write-Host 'If the light blinks green: press FEED once.  Red: check the cover/labels, then press FEED.'
  Write-Host 'In the browser print dialog: Margins = None, Scale = 100.'
}
catch {
  Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
