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
    .\tests\run-tests.ps1 -Test needles     # 只跑名字**包含**该串的套件（如 -Test encoding / needles / mapping）

  慢速测试：个别套件含"真跑一次完整体检"级别的集成测试（约 2 分钟/引擎），默认跳过并
  在输出里登记为 [SKIP]。设 $env:SLOW_TESTS=1 启用 —— CI 上默认启用。

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

# 逐个引擎先做一次"真能启动并被捕获"的自检 —— 这一步不能省。
# 如果 pwsh 只有 Microsoft Store（MSIX）版，从 5.1 启动它是一次"应用激活"而不是子进程：
# 实测重定向得到 0 字节文件、$LASTEXITCODE 为空，于是每个套件都会被判成"没有输出 ##RESULT"
# ——8 个全过的套件被报成 8/8 失败。宁可明确跳过，也不能让运行器撒谎。
$usable = @()
foreach ($eng in $candidates) {
    $probeFile = Join-Path ([IO.Path]::GetTempPath()) ('wmh-probe-' + [guid]::NewGuid().ToString('N') + '.txt')
    $probeText = ''
    try {
        & $eng -NoProfile -ExecutionPolicy Bypass -Command 'Write-Output "wmh-probe-ok"' > $probeFile 2>&1
        if (Test-Path -LiteralPath $probeFile) {
            $probeText = [IO.File]::ReadAllText($probeFile, (New-Object Text.UTF8Encoding($false)))
        }
    } catch { $probeText = '' }
    finally { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue }

    if ($probeText -match 'wmh-probe-ok') { $usable += $eng }
    else {
        Write-Output ('  [跳过] 引擎 {0}：无法被本进程启动并捕获输出。' -f $eng)
        Write-Output '         常见原因：pwsh 只有 Microsoft Store（MSIX）版，而本运行器正跑在 5.1 下。'
        Write-Output '         MSIX 应用是被"激活"的、不是子进程 —— 拿不到 stdout 和退出码。'
        Write-Output '         解决：用 pwsh 运行本运行器，或安装 MSI/zip 版 PowerShell 7。'
    }
}
if ($usable.Count -eq 0) {
    Write-Output '没有任何可用的引擎，无法测试。'
    exit 2
}
$candidates = $usable

$suites = @(Get-ChildItem -LiteralPath $testsDir -File -Filter '*.tests.ps1' | Sort-Object Name)
# 名字"包含"即可：套件名形如 health-check.needles.tests.ps1，-Test needles 也要能命中
if ($Test) { $suites = @($suites | Where-Object { $_.Name -like ('*' + $Test + '*') }) }
if ($suites.Count -eq 0) { Write-Output ('没有匹配 "{0}" 的测试套件。' -f $Test); exit 2 }

Write-Output ("仓库根：{0}" -f $repo)
Write-Output ("运行器宿主：PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Output ("套件：{0}" -f (($suites | ForEach-Object { $_.Name }) -join ', '))

$pass = 0
$fail = 0

foreach ($eng in $candidates) {
    $ver = ((& $eng -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1) -join '').Trim()
    Write-Output ''
    Write-Output ('================ 引擎：{0} ({1}) ================' -f $eng, $ver)

    foreach ($s in $suites) {
        Write-Output ('--- {0} ---' -f $s.Name)

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wmh-tk-' + [guid]::NewGuid().ToString('N') + '.txt')
        $env:WIMH_SUITE = $s.FullName
        $cmd = 'try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}; ' +
               '$OutputEncoding = [Text.UTF8Encoding]::new($false); & $env:WIMH_SUITE'

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
