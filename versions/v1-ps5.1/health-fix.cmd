@echo off
setlocal
set "DIR=<工作区>"
set "LOG=%DIR%\health-fix-elevated.txt"
echo ==== health-fix %DATE% %TIME% arg=%1 ==== > "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\health-fix.ps1" %1 >> "%LOG%" 2>&1
echo ==== exit %errorlevel% ==== >> "%LOG%"
