@echo off
rem ===========================================================================
rem  repair-migrated-apps: rewrite Windows registrations for apps that moved
rem    (edit the $pathMap table at the top of the .ps1 first)
rem
rem    repair-migrated-apps.cmd        -> apply the repair (asks for admin)
rem    repair-migrated-apps.cmd dry    -> preview only, nothing is written
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem ===========================================================================
setlocal
set "SCRIPT=%~dp0repair-migrated-apps.ps1"
set "MODE=-Apply"
if /i "%~1"=="dry" set "MODE="
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"

if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%".
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% equ 0 goto :run

echo Administrator rights are required; accept the UAC prompt and read the result
echo in the new window.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%PS%' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPT%','%MODE%' -Verb RunAs"
echo.
echo Done (see the elevated window). To preview without writing anything, run:
echo     repair-migrated-apps.cmd dry
pause
exit /b 0

:run
echo Running elevated (engine: %PS%)...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %MODE%
echo.
pause
exit /b 0
