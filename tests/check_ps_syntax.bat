@echo off
:: Real PowerShell syntax check for all .ps1 files (run on Windows)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_ps_syntax.ps1"
pause
