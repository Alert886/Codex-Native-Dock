@echo off
setlocal
title Restore Codex Native UI
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0scripts\restore.ps1" -RemoveFiles
set "CND_EXIT=%ERRORLEVEL%"
if not "%CND_EXIT%"=="0" pause
exit /b %CND_EXIT%
