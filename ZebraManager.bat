@echo off
:: Printer Manager desktop app (asks for administrator rights by itself)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\ZebraManager.ps1"
