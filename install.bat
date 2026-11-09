@echo off
:: Runs install.ps1 (it asks for administrator rights by itself)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
