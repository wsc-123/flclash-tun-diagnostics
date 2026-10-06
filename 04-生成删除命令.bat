@echo off
setlocal EnableExtensions
rem Read-only command generator. Its dependency lives in the scripts folder.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\generate-route-delete-command.ps1" -LaunchedFromBatch %*
set "ROUTE_COMMAND_EXIT=%ERRORLEVEL%"
endlocal & exit /b %ROUTE_COMMAND_EXIT%
