@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BUILD-4TW-OS.ps1" -LaunchedFromCmd
set "fourtw_exit=%ERRORLEVEL%"
if not "%fourtw_exit%"=="0" (
  echo.
  echo The 4TW-OS launcher stopped. Review the message above.
  pause
)
exit /b %fourtw_exit%
