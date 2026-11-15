@echo off
title Mesh Downloader Setup
powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/BrownPeak64495/roblox-mesh-tools/main/install.ps1'))"
if errorlevel 3 (
  echo.
  pause
  exit /b 3
)
if errorlevel 2 (
  timeout /t 4 >nul
  exit /b 2
)
if errorlevel 1 (
  echo.
  echo   Install failed - see the message above. Check your internet and that the drive is plugged in, then try again.
  pause
  exit /b 1
)
echo.
echo   Done! Use the Mesh Downloader icon on your Desktop from now on.
echo   You can delete this installer file.
timeout /t 6 >nul
