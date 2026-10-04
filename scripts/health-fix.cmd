@echo off
rem ===========================================================================
rem  health-fix: clean up leftovers found by the health check
rem    Dry run by default. -Apply writes changes and asks for administrator
rem    rights (UAC prompt).
rem    Backups/logs go to <repo>\local\  (registry backups under local\rollback)
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem
rem    NOTE: we deliberately do NOT redirect this window's output to a file.
rem    cmd redirection writes the child's stdout in the OEM code page (936 on a
rem    Chinese system), which turned the old health-fix-elevated.txt into GBK
rem    mojibake. The script writes its own UTF-8 log instead
rem    (local\health-fix-log.txt).
rem ===========================================================================
setlocal
set "L=%~dp0..\local"
if not exist "%L%" mkdir "%L%"
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
echo [health-fix] engine: %PS%

rem Already elevated? Then just run.
net session >nul 2>&1
if %errorlevel% equ 0 goto :run
rem Dry run does not need admin; only -Apply does.
if /i not "%~1"=="-Apply" goto :run

echo Administrator rights are required for -Apply.
echo Accept the UAC prompt; the result appears in the new window.
rem -NoExit keeps that window open so the summary can be read.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%PS%' -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0health-fix.ps1','-Apply' -Verb RunAs"
echo.
echo Done. For a preview that writes nothing, run:  health-fix.cmd
pause
exit /b 0

:run
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0health-fix.ps1" %1
set "RC=%errorlevel%"
echo.
echo Full log: "%L%\health-fix-log.txt"
echo exit code: %RC%
pause
exit /b %RC%
