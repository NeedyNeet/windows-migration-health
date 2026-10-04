@echo off
rem ===========================================================================
rem  run-tests: zero-dependency test runner for this repository
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem    Runs every tests\*.tests.ps1 in an isolated child process, on both engines
rem    Exit code: 0 = all passed, 1 = something failed, 2 = nothing to run
rem ===========================================================================
setlocal
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
echo [run-tests] engine: %PS%
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-tests.ps1" %*
set "RC=%errorlevel%"
echo.
echo exit code: %RC%
pause
exit /b %RC%
