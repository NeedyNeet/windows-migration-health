# ============================================================================
#  tests/repair.exists.tests.ps1 —— "读不到 ≠ 不存在"（AGENTS.md 硬性约定 10）
#
#  repair-migrated-apps.ps1 曾经是全仓唯一还用裸 Test-Path 判文件存在的地方。
#  权限受限时 Test-Path 会静默返回 False，于是把存在的目标当缺失：
#    * 该改写的值被当成"改不了"而跳过（只是退化，不出错）
#    * 快捷方式那两处更糟：会把一个**本来好的**目标改写掉
#
#  这里测它新的 Test-Exists 助手，并加一条结构性守卫：脚本里不许再出现
#  "判文件存在"用的裸 Test-Path。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\repair-migrated-apps.ps1'

Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Test-Exists')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wmh-ex-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $tmp -Force
    $fileExists = Join-Path $tmp 'exists.txt'
    Set-Content -LiteralPath $fileExists -Value 'x'
    $fileMissing = Join-Path $tmp 'nope.txt'

    Test-Case '存在的文件 -> $true' {
        Assert-True (Test-Exists $fileExists) '存在的文件应判为存在'
    }

    Test-Case '不存在的文件 -> $false' {
        Assert-True (-not (Test-Exists $fileMissing)) '不存在的文件应判为不存在'
    }

    Test-Case '空路径 / $null -> $false，且不抛异常' {
        Assert-True (-not (Test-Exists '')) '空字符串应返回 $false'
        Assert-True (-not (Test-Exists $null)) '$null 应返回 $false'
    }

    Test-Case '目录也算存在（不是文件专用）' {
        Assert-True (Test-Exists $tmp) '目录应判为存在'
    }

    Test-Case '脚本里不再用裸 Test-Path 判文件存在' {
        $text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
        # 先排除助手自身的实现：它内部当然要用 Test-Path —— 那正是"正确的检查"本身。
        # （守卫的第一版没排除，于是把自己报成 4 处违规。）
        $text = $text.Replace((Get-ScriptFunctionText -Path $target -Name 'Test-Exists'), '')
        # 允许保留 Test-Path 的三类用法（其余一律视为违规）：
        #   1. 注册表键        —— $Root（Repair-KeyTree 的根，本脚本里恒为注册表路径）/ HKCU: / HKLM:
        #   2. 自己刚要建的目录 —— $BackupDir
        #   3. 仓库根探测       —— $RepoRoot
        # 将来若确有正当用途，请**有意**扩展白名单，而不是绕过这条测试。
        $allowed = "'HK", 'HKCU:', 'HKLM:', '\$BackupDir', '\$RepoRoot', '\$Root'
        $bad = @()
        foreach ($line in ($text -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -notmatch 'Test-Path') { continue }
            if ($t.StartsWith('#')) { continue }          # 注释里提到 Test-Path 不算违规
            $ok = $false
            foreach ($a in $allowed) { if ($t -match $a) { $ok = $true; break } }
            if (-not $ok) { $bad += $t }
        }
        Assert-True ($bad.Count -eq 0) ("仍有判文件存在用的裸 Test-Path：{0}" -f ($bad -join ' ; '))
    }
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Complete-TestRun 'repair.exists'
