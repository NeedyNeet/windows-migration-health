# ============================================================================
#  tests/repair.discovery.tests.ps1 —— 发现阶段（Find-MigratedKeys）的行为
#
#  这一段的职责：在三个 Classes 大树里找出"名字或数据里仍写着旧路径"的键，交给改写器。
#  它原来用 `reg.exe query <根> /f <needle> /s`：**逐条 needle 各跑一遍**，而实测约 98% 的
#  时间是"读取每一个值的数据"（与 needle 内容无关）→ 13 条 needle 要把最贵的活重复 13 遍，
#  本机实测 30~40 分钟。现在改成 .NET 一次性遍历（与 health-check 第 12 节同一套做法）。
#
#  换实现最容易换掉的是**命中判据**：旧实现认三种命中（键路径含 / 值名是 / 值数据含），
#  这里就用沙箱键把三种都钉住，外加"非字符串值不看""打不开要记账"两条。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\repair-migrated-apps.ps1'

$script:unreadable = @()
Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Find-MigratedKeys')

# 沙箱：沿用其它套件的 _wmh_selftest_* 命名（writepath 套件开头的清理会扫掉残留）
$sandbox = Join-Path 'HKCU:\Software' ('_wmh_selftest_disc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$needle = 'D:\OldPlace'
$null = New-Item -Path $sandbox -Force

try {
    # 1) 值数据里含 needle
    $kData = Join-Path $sandbox 'ByData'
    $null = New-Item -Path $kData -Force
    Set-ItemProperty -LiteralPath $kData -Name 'Icon' -Value ("{0}\app.ico" -f $needle)
    # 2) 嵌套子键：should 也要走到
    $kNested = Join-Path $sandbox 'Parent\Child'
    $null = New-Item -Path $kNested -Force
    Set-ItemProperty -LiteralPath $kNested -Name 'Path' -Value ("{0}\bin" -f $needle)
    # 3) 键名里含 needle
    $kName = Join-Path $sandbox 'ByName'
    $null = New-Item -Path $kName -Force
    $subName = Join-Path $kName $needle
    $null = New-Item -Path $subName -Force
    # 4) **值名**是 needle（旧实现的第三种命中）
    $kValueName = Join-Path $sandbox 'ByValueName'
    $null = New-Item -Path $kValueName -Force
    Set-ItemProperty -LiteralPath $kValueName -Name $needle -Value 'x'
    # 5) 只有 DWORD（非字符串）—— 不该命中
    $kDword = Join-Path $sandbox 'ByDword'
    $null = New-Item -Path $kDword -Force
    New-ItemProperty -LiteralPath $kDword -Name 'Num' -Value 123 -PropertyType DWord | Out-Null
    # 6) 完全无关的键
    $kClean = Join-Path $sandbox 'Clean'
    $null = New-Item -Path $kClean -Force
    Set-ItemProperty -LiteralPath $kClean -Name 'V' -Value 'C:\Current\place'

    Test-Case '三种命中都能抓到：值数据 / 嵌套子键 / 键名 / 值名' {
        $hits = Find-MigratedKeys -Roots @($sandbox) -Needles @($needle)
        Assert-True ($hits.ContainsKey($kData))        ('值数据里含旧路径的键应当命中：{0}' -f $kData)
        Assert-True ($hits.ContainsKey($kNested))      ('嵌套子键里含旧路径的键应当命中（要递归）：{0}' -f $kNested)
        Assert-True ($hits.ContainsKey($subName))      ('键名里含旧路径的键应当命中：{0}' -f $subName)
        Assert-True ($hits.ContainsKey($kValueName))   ('值名是旧路径的键应当命中：{0}' -f $kValueName)
    }

    Test-Case '不该命中的不要报：非字符串值、无关的键' {
        $hits = Find-MigratedKeys -Roots @($sandbox) -Needles @($needle)
        Assert-True (-not $hits.ContainsKey($kDword)) ('只有 DWORD 的键不该命中：{0}' -f $kDword)
        Assert-True (-not $hits.ContainsKey($kClean)) ('无关的键不该命中：{0}' -f $kClean)
    }

    Test-Case '返回的是"PowerShell 路径"（HK*:\\…），能直接喂给 Repair-KeyTree' {
        $hits = Find-MigratedKeys -Roots @($sandbox) -Needles @($needle)
        foreach ($k in $hits.Keys) {
            Assert-Match $k '^HK(LM|CU):\\' ('返回的键路径必须是 PowerShell 形式（可被 Get-Item -LiteralPath 直接用）：{0}' -f $k)
        }
        # 根键**自己**的路径也参与判定：否则以"名字就含旧路径"的键为根时，整棵子树会被无声漏掉
        $h2 = Find-MigratedKeys -Roots @($subName) -Needles @($needle)
        Assert-True ($h2.ContainsKey($subName)) ('根键自身路径含旧路径时也要算进去：{0}' -f $subName)
    }

    Test-Case 'needle 大小写不敏感（注册表里路径大小写很乱）' {
        $hits = Find-MigratedKeys -Roots @($sandbox) -Needles @('d:\oldplace')
        Assert-True ($hits.ContainsKey($kData)) '小写 needle 也应当命中'
    }

    Test-Case '打不开的根要记账（读不到 ≠ 这棵树里没有旧路径）' {
        $before = $script:unreadable.Count
        $hits = Find-MigratedKeys -Roots @('HKLM:\SECURITY') -Needles @($needle)
        Assert-Equal @($hits.Keys).Count 0 '打不开的根不该报出任何命中'
        Assert-True ($script:unreadable.Count -gt $before) '打不开必须记账（否则会静默变成"扫过且干净"）'
        Assert-Match ([string]$script:unreadable[-1].Key) 'SECURITY' '记账里应当写明是哪个根'
    }
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Complete-TestRun 'repair.discovery'
