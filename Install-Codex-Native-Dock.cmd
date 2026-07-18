@echo off
setlocal
title Codex Native Dock Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"
set "CND_EXIT=%ERRORLEVEL%"
if not "%CND_EXIT%"=="0" (
  echo.
  echo Installation failed. No Codex application files were modified.
  pause
)
exit /b %CND_EXIT%
