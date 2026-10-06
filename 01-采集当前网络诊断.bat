@echo off
setlocal EnableExtensions
rem Launch relative to this file; independent of the current working directory.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\tun-diag.ps1" -LaunchedFromBatch %*
set "DIAG_EXIT=%ERRORLEVEL%"
endlocal & exit /b %DIAG_EXIT%
