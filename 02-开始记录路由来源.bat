@echo off
setlocal EnableExtensions
rem Right-click this file and select Run as administrator. No automatic elevation.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\route-origin-trace.ps1" -Action Start -LaunchedFromBatch %*
set "TRACE_EXIT=%ERRORLEVEL%"
endlocal & exit /b %TRACE_EXIT%
