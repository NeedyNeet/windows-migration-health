@echo off
rem ===========================================================================
rem  一键健康体检（只读，不会修改任何东西）
rem  双击运行即可；报告输出到本目录的「健康体检\<时间戳>\report.md」
rem
rem  想要更快的体检（跳过最慢的"旧路径残留扫描"）：
rem      在本文件上右键 → 编辑，把下面 SKIP 那一行改成 set SKIP=-SkipOldPathScan
rem ===========================================================================
setlocal
set "SKIP="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0health-check.ps1" %SKIP% %*
echo.
echo 按任意键关闭窗口...
pause >nul
