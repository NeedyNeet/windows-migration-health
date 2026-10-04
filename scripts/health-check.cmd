@echo off
rem ===========================================================================
rem  health-check: read-only system health check
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem    Reports go to: <repo>\local\reports\<timestamp>\report.md
rem    For a faster run, change the SKIP line below to:  set SKIP=-SkipOldPathScan
rem    Exit code: 0 = no "severe" findings, 1 = there are severe findings
rem               (same contract as health-check.ps1; usable from CI / batch)
rem ===========================================================================
setlocal
set "SKIP="
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
set "OUT=%~dp0..\local\reports"
if not exist "%OUT%" mkdir "%OUT%"
echo [health-check] engine: %PS%
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0health-check.ps1" -OutDir "%OUT%" %SKIP% %*
set "RC=%errorlevel%"
echo.
echo exit code: %RC%
pause >nul
exit /b %RC%
