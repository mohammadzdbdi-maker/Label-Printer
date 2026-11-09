# سرور لیبل داروی ساختنی - گوشی‌ها روی وای‌فای داروخانه این صفحه را باز می‌کنند و لیبل چاپ می‌شود
# روی کامپیوتری که پرینتر به آن وصل است اجرا می‌شود (نصب: install-label-server.bat)

param(
  [int]$Port = 8080,
  [string]$PrinterName = 'Zebra GK888t - EPL',
  [string]$Prefix = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Prefix) { $Prefix = "http://+:$Port/" }
Add-Type -AssemblyName System.Drawing

$logFile = Join-Path $root 'server.log'
function Log($t) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $t"
  Write-Host $line
  try {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile "$logFile.old" -Force }
    Add-Content $logFile $line -Encoding UTF8
  } catch { }
}

$mime = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
           '.svg' = 'image/svg+xml'; '.ttf' = 'font/ttf'; '.png' = 'image/png'; '.webmanifest' = 'application/manifest+json' }

function Send($ctx, [int]$code, [byte[]]$body, [string]$type) {
  $r = $ctx.Response
  $r.StatusCode = $code
  $r.ContentType = $type
  $r.Headers['Cache-Control'] = 'no-cache'
  $r.ContentLength64 = $body.Length
  $r.OutputStream.Write($body, 0, $body.Length)
  $r.OutputStream.Close()
}
function SendJson($ctx, $obj, [int]$code = 200) {
  Send $ctx $code ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))) 'application/json; charset=utf-8'
}

function Get-Config {
  $cfg = @{ foot = 'داروخانه شبانه روزی دکتر زارعی - سیرجان ، چهار راه شهربابک - 03442204802'; widthMm = 58; heightMm = 40 }
  $f = Join-Path $root 'settings.json'
  if (Test-Path $f) {
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
  }
  $cfg
}

function Get-PrinterState {
  $p = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
  if (-not $p) { return @{ ok = $false; text = 'پرینتر پیدا نشد' } }
  $jobs = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)
  $bad  = @($jobs | Where-Object { $_.JobStatus -match 'Error|Offline|PaperOut|Blocked' })
  $st = [string]$p.PrinterStatus
  @{ ok = ($st -eq 'Normal' -and -not $bad); status = $st; jobs = $jobs.Count; text = $(if ($bad) { 'خطا در صف چاپ' } elseif ($st -eq 'Normal') { 'آماده' } else { $st }) }
}

# چاپ تصویر لیبل (PNG سیاه‌وسفید با رزولوشن پرینتر) از طریق درایور، همان مسیری که برنامهٔ لیبل‌زن استفاده می‌کند
function Print-Label([byte[]]$png, [int]$qty, [double]$wMm, [double]$hMm) {
  $ms  = New-Object IO.MemoryStream(, $png)
  $img = [System.Drawing.Image]::FromStream($ms)
  try {
    $d = New-Object System.Drawing.Printing.PrintDocument
    $d.PrinterSettings.PrinterName = $PrinterName
    if (-not $d.PrinterSettings.IsValid) { throw "Printer '$PrinterName' not found" }
    $d.DocumentName = 'لیبل ساختنی (موبایل)'
    $d.PrintController = New-Object System.Drawing.Printing.StandardPrintController
    $d.PrinterSettings.Copies = [int16]$qty
    $d.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
    $script:pimg = $img; $script:pw = $wMm; $script:ph = $hMm
    $d.add_PrintPage({
      param($s, $e)
      $g = $e.Graphics
      $g.PageUnit = [System.Drawing.GraphicsUnit]::Millimeter
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
      $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
      $g.DrawImage($script:pimg, 0, 0, [single]$script:pw, [single]$script:ph)
      $e.HasMorePages = $false
    })
    $d.Print()
  } finally { $img.Dispose(); $ms.Dispose() }
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($Prefix)
try { $listener.Start() } catch {
  Log "Could not start on $Prefix : $($_.Exception.Message)"
  Log 'Run install-label-server.bat as administrator once (it reserves the port and opens the firewall).'
  exit 1
}
Log "Label server running on $Prefix  (printer: $PrinterName)"

while ($listener.IsListening) {
  try { $ctx = $listener.GetContext() } catch { break }
  $req  = $ctx.Request
  $path = $req.Url.AbsolutePath
  try {
    if ($req.HttpMethod -eq 'POST' -and $path -eq '/print') {
      $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
      $qty  = [Math]::Max(1, [Math]::Min(50, [int]$body.qty))
      $b64  = ([string]$body.png) -replace '^data:image/\w+;base64,', ''
      $cfg  = Get-Config
      Print-Label ([Convert]::FromBase64String($b64)) $qty ([double]$cfg.widthMm) ([double]$cfg.heightMm)
      Log "PRINT x$qty from $($req.RemoteEndPoint.Address)  patient='$($body.pat)'"
      SendJson $ctx @{ ok = $true; qty = $qty }
    }
    elseif ($path -eq '/status') { SendJson $ctx (Get-PrinterState) }
    elseif ($path -eq '/config') { SendJson $ctx (Get-Config) }
    else {
      $rel = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
      $file = Join-Path $root $rel
      $full = [IO.Path]::GetFullPath($file)
      if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $full -PathType Leaf) -and $mime.ContainsKey([IO.Path]::GetExtension($full))) {
        Send $ctx 200 ([IO.File]::ReadAllBytes($full)) $mime[[IO.Path]::GetExtension($full)]
      } else {
        Send $ctx 404 ([Text.Encoding]::UTF8.GetBytes('Not found')) 'text/plain'
      }
    }
  } catch {
    Log "ERROR $($req.HttpMethod) $path : $($_.Exception.Message)"
    try { SendJson $ctx @{ ok = $false; error = $_.Exception.Message } 500 } catch { }
  }
}
