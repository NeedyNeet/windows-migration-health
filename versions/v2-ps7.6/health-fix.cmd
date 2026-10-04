@echo off
rem ===========================================================================
rem  health-fix: clean up leftovers found by the health check
rem    Dry run by default; pass -Apply to write changes (backs up to rollback\)
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem    NOTE: this window's output goes to health-fix-elevated.txt
rem          the script writes its own detailed log to health-fix-log.txt
rem          (must be two DIFFERENT files, otherwise they lock each other)
rem ===========================================================================
setlocal
set "DIR=%~dp0"
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
echo [health-fix] engine: %PS%
echo ==== health-fix %DATE% %TIME% arg=%1 engine=%PS% ==== > "%DIR%health-fix-elevated.txt"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%DIR%health-fix.ps1" %1 >> "%DIR%health-fix-elevated.txt" 2>&1
echo ==== exit %errorlevel% ==== >> "%DIR%health-fix-elevated.txt"
