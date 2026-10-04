<#
  tests\run-tests.ps1 —— 零依赖测试运行器

  设计要点：
    * 刻意不用 Pester：本机是 3.4.0、CI 上可能是 5.x，两者语法不兼容；而且本项目的红线是
      "零第三方依赖，任意 Windows 都能独立跑"——测试也是发布物的一部分。
    * 每个 *.tests.ps1 在**独立子进程**里跑：互不污染，且能天然覆盖 5.1 与 7.x 两个引擎。
    * 子进程的输出编码被显式固定为 UTF-8。否则 Windows PowerShell 5.1 在 GBK 代码页下
      会把中文写成 GBK 字节（本项目 local\health-fix-elevated.txt 就是这么变成乱码的）。
    * 成败用"##RESULT 标记 + 子进程退出码"双重判定：标记能抓到"套件中途崩掉"，
      退出码能抓到"标记写了但进程仍然失败"。

  用法：
    .\tests\run-tests.ps1                   # 装了哪个引擎就跑哪个（通常两个都跑）
    .\tests\run-tests.ps1 -Engine pwsh      # 只跑 PowerShell 7
    .\tests\run-tests.ps1 -Engine powershell
    .\tests\run-tests.ps1 -Test encoding    # 只跑文件名以 encoding 开头的套件

  退出码：0 = 全通过；1 = 有失败；2 = 环境/参数问题（没有匹配的套件或找不到引擎）。
#>
[CmdletBinding()]
param(
    [ValidateSet('auto','pwsh','powershell')][string]$Engine = 'auto',
    [string]$Test
)

$ErrorActionPreference = 'Continue'

$testsDir = $PSScriptRoot
$repo     = Split-Path -Parent $testsDir

$candidates = @(@('pwsh','powershell') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
if ($Engine -ne 'auto') { $candidates = @($candidates | Where-Object { $_ -eq $Engine }) }
if ($candidates.Count -eq 0) {
    Write-Output ("找不到可用的 PowerShell 引擎：{0}" -f $Engine)
    exit 2
}

$suites = @(Get-ChildItem -LiteralPath $testsDir -File -Filter '*.tests.ps1' | Sort-Object Name)
if ($Test) { $suites = @($suites | Where-Object { $_.Name -like ($Test + '*') }) }
if ($suites.Count -eq 0) { Write-Output '没有匹配的测试套件。'; exit 2 }

Write-Output ("仓库根：{0}" -f $repo)
Write-Output ("套件：{0}" -f (($suites | ForEach-Object { $_.Name }) -join ', '))

$pass = 0
$fail = 0

foreach ($eng in $candidates) {
    $ver = ((& $eng -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1) -join '').Trim()
    Write-Output ''
    Write-Output ('================ 引擎：{0} ({1}) ================' -f $eng, $ver)

    foreach ($s in $suites) {
        Write-Output ('--- {0} ---' -f $s.Name)

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dsh-tk-' + [guid]::NewGuid().ToString('N') + '.txt')
        $env:DSH_TESTKIT_SUITE = $s.FullName
        $cmd = 'try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}; ' +
               '$OutputEncoding = [Text.UTF8Encoding]::new($false); & $env:DSH_TESTKIT_SUITE'

        & $eng -NoProfile -ExecutionPolicy Bypass -Command $cmd > $tmp 2>&1
        $code = $LASTEXITCODE

        $out = ''
        if (Test-Path -LiteralPath $tmp) {
            $out = [IO.File]::ReadAllText($tmp, (New-Object Text.UTF8Encoding($false)))
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        foreach ($line in ($out -split "`r?`n")) { Write-Output $line }

        $ok = ($code -eq 0) -and ($out -match '##RESULT: PASS')
        if ($out -notmatch '##RESULT: (PASS|FAIL)') {
            Write-Output ('  !! {0} 在 {1} 下没有输出 ##RESULT 标记（退出码 {2}）—— 套件可能没跑完' -f $s.Name, $eng, $code)
            $ok = $false
        }
        if ($ok) { $pass++ }
        else { $fail++; Write-Output ('  !! 失败：{0} @ {1}（退出码 {2}）' -f $s.Name, $eng, $code) }
    }
}

Write-Output ''
Write-Output ('================ 汇总：通过 {0} / 失败 {1} ================' -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
