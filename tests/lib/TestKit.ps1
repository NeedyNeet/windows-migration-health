# ============================================================================
#  tests/lib/TestKit.ps1 —— 零依赖测试小工具
#
#  刻意不用 Pester：本机是 3.4.0、CI 上可能是 5.x，两者语法不兼容；而且本项目的红线是
#  "零第三方依赖，任意 Windows 都能独立跑"——测试也是发布物的一部分。
#
#  用法（在 *.tests.ps1 里）：
#      . "$PSScriptRoot\lib\TestKit.ps1"
#      Test-Case '某件事成立' { Assert-True $x '说明' }
#      Complete-TestRun '套件名'
#
#  约定：每个 *.tests.ps1 由 tests\run-tests.ps1 在**独立子进程**里运行；
#        成败以输出里的 ##RESULT 标记 + 子进程退出码双重判定。
# ============================================================================

$script:TkLibDir   = $PSScriptRoot
$script:TkChecks   = 0
$script:TkSkips    = 0
$script:TkFailures = New-Object System.Collections.Generic.List[string]

# 仓库根：tests/lib/ -> tests/ -> 仓库根
function Get-RepoRoot { return (Split-Path -Parent (Split-Path -Parent $script:TkLibDir)) }

function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:TkChecks++
    try {
        & $Body
        Write-Output ("  [PASS] {0}" -f $Name)
    } catch {
        $msg = $_.Exception.Message
        $script:TkFailures.Add(("{0} -- {1}" -f $Name, $msg))
        Write-Output ("  [FAIL] {0} -- {1}" -f $Name, $msg)
    }
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ("$Actual" -ne "$Expected") { throw ("{0}（期望 [{1}]，实际 [{2}]）" -f $Message, $Expected, $Actual) }
}

function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw ("{0}（未匹配 {1}）" -f $Message, $Pattern) }
}

function Assert-NotMatch([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -match $Pattern) { throw ("{0}（不该匹配 {1}）" -f $Message, $Pattern) }
}

# 显式跳过：慢速 / 依赖环境的测试用它登记。
# 刻意让"跳过"在输出里可见、并在结尾计入统计 —— 静默跳过本身也是一种假绿。
function Skip-Test([string]$Name, [string]$Reason) {
    $script:TkSkips++
    Write-Output ("  [SKIP] {0} -- {1}" -f $Name, $Reason)
}

function Complete-TestRun([string]$SuiteName) {
    Write-Output ("  {0}: 共 {1} 项检查，{2} 项失败，{3} 项跳过" -f $SuiteName, $script:TkChecks, $script:TkFailures.Count, $script:TkSkips)
    if ($script:TkFailures.Count -gt 0) {
        $script:TkFailures | ForEach-Object { Write-Output ("    ! " + $_) }
        Write-Output '##RESULT: FAIL'
        exit 1
    }
    Write-Output '##RESULT: PASS'
    exit 0
}
