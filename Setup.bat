@echo off
title Mesh Downloader Setup
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0setup.ps1"
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
  echo   Setup failed - see the message above. Make sure the drive is plugged in, then try again.
  pause
  exit /b 1
)
echo.
echo   Done! Use the Mesh Downloader icon on your Desktop from now on.
echo   You can delete the downloaded zip and this folder.
timeout /t 6 >nul
