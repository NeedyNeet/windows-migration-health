# ============================================================================
#  tests/conventions.tests.ps1 —— 检查"约定有没有执行者"
#
#  为什么需要它：一条约定如果**没有任何东西能让它失败**，它就不是约定，是愿望。
#  本仓库吃过两次亏（详见 AGENTS.md「约定必须有执行者」）。这个套件把"必须有执行者"
#  这件事本身变成可检查的：AGENTS.md 里每条硬性约定都要带标签，而标签引用的东西必须真实存在。
#
#  它**不**检查那些执行者是否真的有效（那是各个套件自己的事）。它只保证两件事：
#  每条约定都指得出名字，以及指的那个东西真的在 —— 一个不存在的执行者比没有执行者更糟。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo       = Get-RepoRoot
$agentsPath = Join-Path $repo 'AGENTS.md'
$lintPath   = Join-Path $repo 'tests\lint.tests.ps1'
$agents     = [IO.File]::ReadAllText($agentsPath, [Text.Encoding]::UTF8)
$mdLines    = $agents -split "`r?`n"

# 取某个 "### xxx" 小节的正文行（到下一个 "### " 为止）
function Get-MdSectionLines([string]$header) {
    $start = -1; $out = @()
    for ($i = 0; $i -lt $mdLines.Count; $i++) {
        if ($start -lt 0) { if ($mdLines[$i] -match ('^###\s*' + [regex]::Escape($header))) { $start = $i } ; continue }
        if ($mdLines[$i] -match '^###\s') { break }
        $out += $mdLines[$i]
    }
    if ($start -lt 0) { throw ("AGENTS.md 里找不到小节：{0}" -f $header) }
    return $out
}

# 硬性约定的编号块（每条 = 编号行 + 后续到下一个编号为止的行）
function Get-ConventionBlocks {
    $lines = @(Get-MdSectionLines '硬性约定')
    $blocks = @(); $cur = $null
    foreach ($l in $lines) {
        if ($l -match '^\s*(\d+)\.\s+\*\*') {
            if ($cur) { $blocks += $cur }
            $cur = [pscustomobject]@{ Num = [int]$Matches[1]; Text = $l }
        } elseif ($cur) { $cur.Text = $cur.Text + "`n" + $l }
    }
    if ($cur) { $blocks += $cur }
    return $blocks
}

$blocks  = @(Get-ConventionBlocks)
$tagText = (@($blocks | ForEach-Object { $_.Text }) + @(Get-MdSectionLines '动手改文件时的约定')) -join "`n"
$tagLines = @($tagText -split "`n" | Where-Object { $_ -match '\[(lint-\d+|test|hook|manual)\]' })

Test-Case '硬性约定的编号是 1..N 连续、无重复' {
    $nums = @($blocks | ForEach-Object { $_.Num } | Sort-Object)
    Assert-True ($nums.Count -ge 14) ("约定数量应当 >= 14，实际 {0}" -f $nums.Count)
    Assert-Equal ($nums -join ',') ((1..$nums.Count) -join ',') '编号必须是 1..N 连续'
}

Test-Case '每条硬性约定都带执行者标签' {
    $bad = @()
    foreach ($b in $blocks) {
        if ($b.Text -notmatch '\[(lint-\d+|test|hook|manual)\]') {
            $bad += ("第 {0} 条没有执行者标签：{1}" -f $b.Num, ($b.Text -split "`n")[0].Trim())
        }
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '[manual] 必须紧接着写明"为什么不能机器化"' {
    $bad = @()
    foreach ($l in @($tagLines | Where-Object { $_ -match '\[manual\]' })) {
        $after = ($l -replace '^.*\[manual\]', '') -replace '^[\s`*\-—:：]+', ''
        if ($after.Trim().Length -lt 8) { $bad += ("标了 [manual] 却没写理由：{0}" -f $l.Trim().Substring(0, [Math]::Min(60, $l.Trim().Length))) }
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 2) -join ' / ')
}

Test-Case '[lint-N] 引用的规则真的存在于 tests\lint.tests.ps1' {
    $lint = [IO.File]::ReadAllText($lintPath, [Text.Encoding]::UTF8)
    $bad = @()
    foreach ($m in [regex]::Matches($tagText, '\[lint-(\d+)\]')) {
        $n = [int]$m.Groups[1].Value
        if ($lint -notmatch ("(?m)^# 规则 {0}：" -f $n)) { $bad += ("[lint-{0}] 在 tests\lint.tests.ps1 里找不到「# 规则 {0}：」" -f $n) }
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '[test] 后面写的文件真的存在' {
    $bad = @()
    foreach ($l in @($tagLines | Where-Object { $_ -match '\[test\]' })) {
        $tail = ($l -replace '^.*?\[test\]', '')
        $refs = @([regex]::Matches($tail, '([\w\.\-\\/]+\.(?:ps1|yml|yaml|cmd|txt))') | ForEach-Object { $_.Groups[1].Value })
        if ($refs.Count -eq 0) { $bad += ("[test] 后面没写明是哪个文件：{0}" -f $tail.Trim()) ; continue }
        foreach ($r in $refs) {
            if (-not (Test-Path -LiteralPath (Join-Path $repo ($r -replace '/', '\')))) { $bad += ("[test] 引用的文件不存在：{0}" -f $r) }
        }
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Complete-TestRun 'conventions'