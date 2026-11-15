@echo off
REM Opens Mesh Downloader. Normally you'd use the Desktop / Start menu icon instead.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0RobloxMeshDownloader.ps1"
