@echo off
:: Run on the PC the printer is plugged into (asks for administrator rights by itself)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0add-print-user.ps1"
