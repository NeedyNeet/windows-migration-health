@echo off
rem Double-click this file to repair the Windows registrations of the apps moved into D:\Apps.
rem It asks for administrator rights (machine-wide registry keys must be rewritten).
rem
rem   repair-migrated-apps.cmd        -> apply the repair
rem   repair-migrated-apps.cmd dry    -> preview only, nothing is written
setlocal
set "SCRIPT=%~dp0repair-migrated-apps.ps1"
set "MODE=-Apply"
if /i "%~1"=="dry" set "MODE="

if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%".
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% equ 0 goto :run

echo Administrator rights are required; accept the UAC prompt and read the result
echo in the new window.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPT%','%MODE%' -Verb RunAs"
echo.
echo Done (see the elevated window). To preview without writing anything, run:
echo     repair-migrated-apps.cmd dry
pause
exit /b 0

:run
echo Running elevated...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %MODE%
echo.
pause
exit /b 0
