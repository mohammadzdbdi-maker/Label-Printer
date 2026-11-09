@echo off
:: Collects a diagnostic log for the shared Zebra printer (no admin needed)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"
