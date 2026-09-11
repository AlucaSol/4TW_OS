@echo off
setlocal
set "fourtw_cleanup_args="
if "%~1"=="" goto run_cleanup
if /I "%~1"=="--dry-run" (
  if not "%~2"=="" goto bad_argument
  set "fourtw_cleanup_args=-DryRun"
  goto run_cleanup
)

:bad_argument
echo Usage: CLEANUP-4TW-OS.cmd [--dry-run]
pause
exit /b 2

:run_cleanup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CLEANUP-4TW-OS.ps1" %fourtw_cleanup_args% -LaunchedFromCmd
set "fourtw_exit=%ERRORLEVEL%"
if not "%fourtw_exit%"=="0" (
  echo.
  echo The 4TW-OS cleanup stopped. Review the message above.
  pause
)
exit /b %fourtw_exit%
