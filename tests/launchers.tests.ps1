# ============================================================================
#  tests/launchers.tests.ps1 —— 三个 .cmd 启动器的「默认安全」不变量
#
#  红线（AGENTS.md 硬性约定 5）：**会写系统的脚本，默认必须是试运行**，只有显式传参才写入。
#
#  这条曾经被违反：repair-migrated-apps.cmd 默认就把 MODE 设成 -Apply，于是
#    · 无参数运行 = 直接写注册表（还弹 UAC）
#    · 与它自己的 .ps1（默认试运行）、与 health-fix.cmd、与 README 的说法**全都相反**
#    · README 的「快速开始」把这一行写成"先试运行" —— 照文档走的人以为在预览，其实已经在写
#
#  用静态断言钉住它。之所以不真跑：完整跑一次 repair 要 4 分钟，不适合进默认套件。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo = Get-RepoRoot
function Get-ScriptText([string]$name) { return [IO.File]::ReadAllText((Join-Path $repo ('scripts\' + $name))) }

Test-Case 'repair-migrated-apps.cmd 默认不写入（必须显式 -Apply）' {
    # 断言方式很关键：**不能**简单断言"文件里不出现 set "MODE=-Apply"" —— 那一行在 -Apply
    # 分支里是合法存在的。本测试的第一版就是那么写的，于是把正确实现报成了违规（又是
    # "用代理信号代替语义"这个老毛病）。要断言的是语义：默认赋值必须无条件为空，
    # 而 -Apply 只允许出现在 if 里。
    $lines   = (Get-ScriptText 'repair-migrated-apps.cmd') -split "`r?`n"
    $default = @($lines | Where-Object { $_.Trim() -eq 'set "MODE="' })
    $uncond  = @($lines | Where-Object { $_.Trim() -match '^set "MODE=-Apply"' })
    $cond    = @($lines | Where-Object { $_.Trim() -match '^if .+set "MODE=-Apply"' })
    Assert-True ($default.Count -ge 1) '找不到无条件的默认赋值 set "MODE="（默认应为空 = 试运行）'
    Assert-True ($uncond.Count -eq 0)  '存在无条件的 set "MODE=-Apply"：无参数运行就会写注册表'
    Assert-True ($cond.Count -ge 1)    '看不到任何「传了 -Apply 才写入」的条件赋值'
}

Test-Case 'repair-migrated-apps.cmd 的试运行不要求管理员（提权只在 -Apply 时）' {
    $t = Get-ScriptText 'repair-migrated-apps.cmd'
    Assert-Match $t 'if not defined MODE goto :run' '看不到「试运行直接跳过提权」的分支'
}

Test-Case 'health-fix.cmd 只在 -Apply 时提权（试运行不弹 UAC）' {
    $t = Get-ScriptText 'health-fix.cmd'
    Assert-Match $t 'if /i not "%~1"=="-Apply" goto :run' '看不到「非 -Apply 就直接跳过提权」的分支'
}

Test-Case 'health-check.cmd 是只读的（不出现 -Apply）' {
    $t = Get-ScriptText 'health-check.cmd'
    Assert-NotMatch $t '-Apply' '只读体检的启动器里不该出现 -Apply'
}

Test-Case '两个会写入的 .ps1 都是「仅 -Apply 才写」' {
    foreach ($n in 'health-fix.ps1', 'repair-migrated-apps.ps1') {
        $t = [IO.File]::ReadAllText((Join-Path $repo ('scripts\' + $n)))
        Assert-Match $t '\[switch\]\$Apply' ("{0} 没有 -Apply 开关" -f $n)
        Assert-Match $t 'if \(-not \$Apply\)' ("{0} 里看不到「未加 -Apply 就不写」的分支" -f $n)
    }
}

Complete-TestRun 'launchers'
