@echo off
:: Run on every other PC that should print to the shared Zebra (asks for administrator rights by itself)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-client.ps1"
