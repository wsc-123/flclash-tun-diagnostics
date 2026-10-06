@echo off
setlocal EnableExtensions
rem Run as administrator after the fault returns, before deleting the route.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\route-origin-trace.ps1" -Action Stop -LaunchedFromBatch %*
set "TRACE_EXIT=%ERRORLEVEL%"
endlocal & exit /b %TRACE_EXIT%
