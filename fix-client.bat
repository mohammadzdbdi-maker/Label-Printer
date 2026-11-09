@echo off
:: Clean up a former printer HOST and reconnect it as a CLIENT
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-client.ps1"
