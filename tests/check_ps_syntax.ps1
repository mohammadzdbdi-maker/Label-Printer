# بررسی سینتکس واقعی همه فایلهای PowerShell با پارسر خود ویندوز (PowerShell 5.1)
# اجرا روی سیستم مقصد:  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\check_ps_syntax.ps1
# خروجی: تعداد خطاها و شماره خط هر کدام. ExitCode=1 یعنی خطا وجود دارد.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -Filter '*.ps1' |
  Where-Object { $_.FullName -notmatch '\\\.git\\' } | Sort-Object FullName

$total = 0
foreach ($f in $files) {
  $tokens = $null
  $errs = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) | Out-Null
  if ($errs.Count -gt 0) {
    $total += $errs.Count
    Write-Host ('ERROR  {0}' -f $f.FullName.Substring($root.Length + 1)) -ForegroundColor Red
    foreach ($e in $errs) {
      Write-Host ('       line {0}: {1}' -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Yellow
    }
  } else {
    Write-Host ('OK     {0}' -f $f.FullName.Substring($root.Length + 1)) -ForegroundColor Green
  }
}
Write-Host ''
Write-Host ("فایلها: {0} | خطاها: {1}" -f $files.Count, $total) -ForegroundColor $(if ($total) { 'Red' } else { 'Cyan' })
exit $(if ($total) { 1 } else { 0 })
