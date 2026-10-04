# ============================================================================
#  tests/lint.tests.ps1 —— 把 AGENTS.md「硬性约定」里**能机器化**的那几条变成断言
#
#  为什么要这个文件：约定写在 AGENTS.md 里只是"文档"，靠人自觉。本仓库已经因为
#  "只改了文档、漏了代码"栽过一次（报告里那句 `$pathMap` 的位置），而且维护者在同一次
#  审计里连犯了三条自己写下的规则。能机器化的规则，就该由机器执行。
#
#  本文件覆盖：
#    · 硬性约定 3  —— 禁止按 .NET 异常类型 catch
#    · 硬性约定 14 —— [IO.File]::* 用的是**进程 CWD**（不是 PowerShell 的 cd），不得配相对路径字面量
#    · 硬性约定 14 —— Get-ChildItem -Filter 不带 -Recurse 会静默漏掉子目录
#  刻意**不**在这里覆盖的（已有归属）：
#    · 裸 Test-Path 判存在（约定 10）    -> repair.exists.tests.ps1
#    · BOM / .cmd 编码与行尾 / 钩子 LF（约定 1、2、13）-> encoding.tests.ps1
#
#  豁免写法：在违规行**或其上一行**写 `# lint-ok: <理由>`（理由不能为空）。
#  刻意要求写明理由：这条规则的目的不是"逼你加 -Recurse"，而是"如果你确实只要当层，就写出来"。
#  实测两个需要豁免的地方都是有意为之：history 目录是平的；测试套件按约定只在 tests\ 顶层。
#
#  每条规则都配一个**自测**：喂一段已知违规的片段，断言它真能抓到。
#  否则正则写错会让规则永远返回"无违规" —— 那就是一个假绿的检查器，比没有检查更糟。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo = Get-RepoRoot

# 只检查"在维护的代码"。versions\ 是**冻结的历史快照**（只增不改），它先于这些约定存在，
# 用新规则去要求它只会制造噪音。lint 自己也要排除 —— 下面的自测里存着故意违规的样本。
function Get-LintTargets {
    @(
        Get-ChildItem (Join-Path $repo 'scripts') -Recurse -File -Filter '*.ps1'
        Get-ChildItem (Join-Path $repo 'tests')   -Recurse -File -Filter '*.ps1'
    ) | Where-Object { $_.Name -ne 'lint.tests.ps1' }
}

function Test-LintExempt {
    param([string[]]$Lines, [int]$Index)
    foreach ($i in @($Index, ($Index - 1))) {
        if ($i -ge 0 -and $i -lt $Lines.Count -and $Lines[$i] -match '#\s*lint-ok:\s*\S') { return $true }
    }
    return $false
}

# 规则 1：按 .NET 异常类型 catch。
# 注释要先排除：本仓库有两条注释正是在**解释**这条规则，里面就写着 `catch [System.IO...]`。
# 判据用"# 出现在 catch 之前"，这样整行注释与行尾注释都能排除。
function Find-NetTypeCatch {
    param([string[]]$Lines)
    $out = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l -notmatch 'catch\s*\[') { continue }
        # 注释要排除：判据是"# 是否出现在**这个** catch 之前"。不能用 IndexOf('catch') ——
        # 行尾注释里可能再出现一次 catch（如 `} catch { }  # 别写成 catch [X]`），那样会比错位置。
        $mk = [regex]::Match($l, 'catch\s*\[')
        $hash = $l.IndexOf('#')
        if ($hash -ge 0 -and $hash -lt $mk.Index) { continue }
        if (Test-LintExempt $Lines $i) { continue }
        $out += [pscustomobject]@{ Line = $i + 1; Text = $l.Trim() }
    }
    return $out
}

# 规则 2：[IO.File]::* 之类配了"相对路径字面量"。
# 绝对路径（`D:\`、`\\`）、变量（`$x`）、环境变量（`%TEMP%`）都放行 —— 只有裸字面量会踩 CWD 陷阱。
function Find-RelativeIOLiteral {
    param([string[]]$Lines)
    $out = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l.TrimStart().StartsWith('#')) { continue }
        foreach ($m in [regex]::Matches($l, '\[(?:System\.)?IO\.(?:File|Directory|FileInfo|DirectoryInfo)\]::\w+\(\s*(["''])([^"'']*)\1')) {
            $lit = $m.Groups[2].Value
            if ($lit -match '^([A-Za-z]:[\\/]|\\\\|\$|%)') { continue }
            if (Test-LintExempt $Lines $i) { continue }
            $out += [pscustomobject]@{ Line = $i + 1; Text = $l.Trim(); Literal = $lit }
        }
    }
    return $out
}

# 规则 3：Get-ChildItem -Filter 少了 -Recurse。
# 用"前后各 3 行"的窗口而不是"同一行"：参数换行是合法写法，只看同一行会误报。
function Find-FilterWithoutRecurse {
    param([string[]]$Lines)
    $out = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '-Filter') { continue }
        if ($Lines[$i].TrimStart().StartsWith('#')) { continue }
        $lo = [Math]::Max(0, $i - 3); $hi = [Math]::Min($Lines.Count - 1, $i + 3)
        if (($Lines[$lo..$hi] -join ' ') -match '-Recurse') { continue }
        if (Test-LintExempt $Lines $i) { continue }
        $out += [pscustomobject]@{ Line = $i + 1; Text = $Lines[$i].Trim() }
    }
    return $out
}

Test-Case '规则自测：三条规则都能抓到已知违规，也不误报' {
    # 每条断言都把**实测数目**写进消息：这个文件自己就是检查器，检查器出问题时，
    # 失败信息必须能直接告诉我"抓到了几处"，否则调试它又得靠猜。
    $c = @(Find-NetTypeCatch @('try { } catch [System.IO.FileNotFoundException] { }')).Count
    Assert-True ($c -eq 1) ("按类型 catch 应抓到 1 处，实际 {0}" -f $c)
    $c = @(Find-NetTypeCatch @('try { } catch { }')).Count
    Assert-True ($c -eq 0) ("无类型 catch 不应被抓到，实际 {0}" -f $c)
    $c = @(Find-NetTypeCatch @('# 所以 `catch [System.IO.FileNotFoundException]` 永远匹配不上')).Count
    Assert-True ($c -eq 0) ("整行注释里的 catch 不应被抓到，实际 {0}" -f $c)
    $c = @(Find-NetTypeCatch @('} catch { }  # 不要写成 catch [X]')).Count
    Assert-True ($c -eq 0) ("行尾注释里的 catch 不应被抓到，实际 {0}" -f $c)

    $c = @(Find-RelativeIOLiteral @('[IO.File]::ReadAllText(''scripts\x.ps1'', $enc)')).Count
    Assert-True ($c -eq 1) ("相对路径字面量应抓到 1 处，实际 {0}" -f $c)
    $c = @(Find-RelativeIOLiteral @('[IO.File]::ReadAllText(''D:\x.txt'', $enc)')).Count
    Assert-True ($c -eq 0) ("绝对路径不应被抓到，实际 {0}" -f $c)
    $c = @(Find-RelativeIOLiteral @('[IO.File]::ReadAllText((Join-Path $repo ''scripts\x''), $enc)')).Count
    Assert-True ($c -eq 0) ("表达式路径不应被抓到，实际 {0}" -f $c)

    $c = @(Find-FilterWithoutRecurse @('Get-ChildItem $d -Filter "*.ps1"')).Count
    Assert-True ($c -eq 1) ("-Filter 缺 -Recurse 应抓到 1 处，实际 {0}" -f $c)
    $c = @(Find-FilterWithoutRecurse @('Get-ChildItem $d -Recurse -File -Filter "*.ps1"')).Count
    Assert-True ($c -eq 0) ("带 -Recurse 不应被抓到，实际 {0}" -f $c)
    $c = @(Find-FilterWithoutRecurse @('# lint-ok: 只要当层', 'Get-ChildItem $d -Filter "*.ps1"')).Count
    Assert-True ($c -eq 0) ("上一行豁免未生效，实际 {0}" -f $c)
    $c = @(Find-FilterWithoutRecurse @('Get-ChildItem $d -Filter "*.ps1"  # lint-ok: 只要当层')).Count
    Assert-True ($c -eq 0) ("行尾豁免未生效，实际 {0}" -f $c)
}
Test-Case '硬性约定 3：没有按 .NET 异常类型 catch 的地方' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-NetTypeCatch (Get-Content $f.FullName -Encoding UTF8) | ForEach-Object { "{0}:{1}  {2}" -f $f.Name, $_.Line, $_.Text })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '硬性约定 14：[IO.*]:: 不得配相对路径字面量（进程 CWD 陷阱）' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-RelativeIOLiteral (Get-Content $f.FullName -Encoding UTF8) | ForEach-Object { "{0}:{1}  字面量={2}" -f $f.Name, $_.Line, $_.Literal })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '硬性约定 14：Get-ChildItem -Filter 必须配 -Recurse（或显式豁免）' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-FilterWithoutRecurse (Get-Content $f.FullName -Encoding UTF8) | ForEach-Object { "{0}:{1}  {2}" -f $f.Name, $_.Line, $_.Text })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Complete-TestRun 'lint'
