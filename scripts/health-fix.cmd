@echo off
rem ===========================================================================
rem  health-fix: clean up leftovers found by the health check
rem    Dry run by default; pass -Apply to write changes
rem    Backups/logs go to <repo>\local\  (registry backups in local\rollback)
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem    NOTE: this window's output and the script's own log must be DIFFERENT files
rem ===========================================================================
setlocal
set "L=%~dp0..\local"
if not exist "%L%" mkdir "%L%"
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
echo [health-fix] engine: %PS%
echo ==== health-fix %DATE% %TIME% arg=%1 engine=%PS% ==== > "%L%\health-fix-elevated.txt"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0health-fix.ps1" %1 >> "%L%\health-fix-elevated.txt" 2>&1
echo ==== exit %errorlevel% ==== >> "%L%\health-fix-elevated.txt"
