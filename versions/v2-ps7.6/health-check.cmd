@echo off
rem ===========================================================================
rem  health-check: read-only system health check
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem    Report: <this folder>\JianKangTiJian\<timestamp>\report.md
rem    For a faster run, change the SKIP line below to:  set SKIP=-SkipOldPathScan
rem ===========================================================================
setlocal
set "SKIP="
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
echo [health-check] engine: %PS%
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0health-check.ps1" %SKIP% %*
echo.
pause >nul
