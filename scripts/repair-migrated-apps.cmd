@echo off
rem ===========================================================================
rem  repair-migrated-apps: rewrite Windows registrations for apps that moved
rem    Fill in the "old -> new" mapping in local\repair-migrated-apps.local.psd1 first.
rem
rem    repair-migrated-apps.cmd          -> DRY RUN (default): prints the plan, writes nothing
rem    repair-migrated-apps.cmd -Apply   -> apply the repair (asks for administrator rights)
rem    ("dry" is still accepted as an alias of the default, for old habits)
rem    Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell 5.1
rem
rem  NOTE: the default used to be -Apply. That was inconsistent with the .ps1, with
rem  health-fix.cmd and with the project rule "a script that writes must default to a
rem  dry run", so running this launcher with no arguments silently wrote to the
rem  registry (with a UAC prompt) while the README presented it as a preview.
rem ===========================================================================
setlocal
set "SCRIPT=%~dp0repair-migrated-apps.ps1"
set "MODE="
if /i "%~1"=="-Apply" set "MODE=-Apply"
if /i "%~1"=="apply"  set "MODE=-Apply"
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"

if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%".
    pause
    exit /b 1
)

rem A dry run must not require administrator rights.
if not defined MODE goto :run

net session >nul 2>&1
if %errorlevel% equ 0 goto :run

echo Administrator rights are required to apply. Accept the UAC prompt and read
echo the result in the new window.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%PS%' -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPT%','-Apply' -Verb RunAs"
echo.
echo Done (see the elevated window). To preview without writing anything, run:
echo     repair-migrated-apps.cmd
pause
exit /b 0

:run
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %MODE%
set "RC=%errorlevel%"
echo.
echo exit code: %RC%
pause
exit /b %RC%
