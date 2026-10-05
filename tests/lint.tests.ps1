# ============================================================================
#  tests/lint.tests.ps1 —— 把 AGENTS.md「硬性约定」里**能机器化**的那几条变成断言
#
#  为什么要这个文件：约定写在 AGENTS.md 里只是"文档"，靠人自觉。本仓库已经因为
#  "只改了文档、漏了代码"栽过一次（报告里那句 `$pathMap` 的位置），而且维护者在同一次
#  审计里连犯了三条自己写下的规则。能机器化的规则，就该由机器执行。
#
#  本文件覆盖：
#    · 硬性约定 3  —— 禁止按 .NET 异常类型 catch
#    · 硬性约定 8  —— scripts\ 下不得出现机器专属路径字面量
#    · 硬性约定 10 —— 不得调用不存在的 .NET 成员（实测：[System.IO.Directory]::GetAttributes 不存在）
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

# 规则 4：在有值返回的函数里，日志函数 Say 的输出会**污染返回值**。
# 实测事故（本仓库真实发生、由 tests\writepath.tests.ps1 抓到）：Backup-Key 的失败分支写成
# `Say (...)` 紧跟 `return $false`，返回值于是变成 @('<日志文本>', $false)；调用方
# `if (-not (Backup-Key ...))` 对**非空数组**求值为真 → "备份失败"被判成"备份成功"，
# 改动照做而且没有备份 —— 恰好破坏了那条"备份失败则该条改动被跳过"的承诺。
# 判据：函数体内若有 `return <值>`，则其中裸写的 Say（既没被赋值接住、也没接管道）即为违规。
function Find-SayPollutingReturn {
    param([string]$Path)
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs -and @($errs).Count -gt 0) { return $out }
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $valRet = @($fn.Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] -and $n.Pipeline
        }, $true))
        if ($valRet.Count -eq 0) { continue }
        foreach ($c in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ($c.GetCommandName() -ne 'Say') { continue }
            $pipe = $c.Parent
            if ($pipe -is [System.Management.Automation.Language.PipelineAst] -and $pipe.PipelineElements.Count -gt 1) { continue }
            if ($pipe.Parent -is [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
            $out += [pscustomobject]@{ Line = $c.Extent.StartLineNumber; Func = $fn.Name }
        }
    }
    return $out
}
# 规则 5：`$script:X` 与文件级变量**仅大小写不同** —— PowerShell 变量名不区分大小写，
# 所以 `$backupDir`（文件级）与 `$script:BackupDir`（函数里）是**同一个变量**。
# 实测事故：测试给自己用的临时根目录起名 $backupDir，而被测脚本的同名变量是 $BackupDir，
# 于是每个用例把根目录覆盖成上一个用例的子目录，路径一层层嵌套，备份"失败"——
# 全程不报错，只是行为变了。这种覆盖必须由机器来拦。
function Find-ScopeCasingClash {
    param([string]$Path)
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs -and @($errs).Count -gt 0) { return $out }
    $fileVars = @{}
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $name = $v.VariablePath.UserPath
        if ($name -match ':') { continue }
        $p = $v.Parent; $inFn = $false
        while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFn = $true; break }; $p = $p.Parent }
        if ($inFn) { continue }
        if (-not $fileVars.ContainsKey($name.ToLower())) { $fileVars[$name.ToLower()] = $name }
    }
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $name = $v.VariablePath.UserPath
        if ($name -notmatch '^script:(.+)$') { continue }
        $bare = $Matches[1]
        if ($fileVars.ContainsKey($bare.ToLower()) -and $fileVars[$bare.ToLower()] -cne $bare) {
            $out += [pscustomobject]@{ Line = $v.Extent.StartLineNumber; FileVar = $fileVars[$bare.ToLower()]; Scoped = $name }
        }
    }
    return $out
}
# 规则 6：空的 catch 必须写明为什么可以吞。空 catch 把"做不到"变成"看起来做到了"。
# 理由必须写在子句内，**或该行行尾**（`catch { }  # 读不到就当没有`）—— 后者是为了不让一行式
# 写法被迫拆成多行。判据刻意不接受"上一行的注释"：那样的注释多半在说别的事。
function Find-SilentCatch {
    param([string]$Path)
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs -and @($errs).Count -gt 0) { return $out }
    $lines = [IO.File]::ReadAllLines($Path)
    foreach ($c in $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] -and $n.Body.Statements.Count -eq 0
    }, $true)) {
        if ($c.Extent.Text -match '#') { continue }
        $endLine = $lines[$c.Extent.EndLineNumber - 1]
        $col = $c.Extent.EndColumnNumber - 1
        $trailing = if ($col -lt $endLine.Length) { $endLine.Substring($col) } else { '' }
        if ($trailing -match '#') { continue }
        $out += [pscustomobject]@{ Line = $c.Extent.StartLineNumber; Text = ($c.Extent.Text -replace "`r?`n", ' ') }
    }
    return $out
}
# 规则 7：函数定义必须在**顶层**（不嵌在 if / foreach / for / while / try / switch / 另一个函数里）。
# 实测事故：Get-OldPathKind 的定义被编辑脚本插进了 `if ($hits.Count -eq 0) { … }` 分支 ——
# PowerShell 的函数是**执行到定义语句那一刻**才生效的，于是"命中 0 个键"时才定义，
# 真实运行（有命中）时调用直接报「术语不会被识别」。更阴的是 AST 抽取能跨层找到它，
# 所以所有 extract 型测试全绿，只有真跑那条路径才炸。
# 判据只保留"嵌在分支里"这一半：**词法顺序 ≠ 执行顺序** —— 函数体内先调用、后定义是合法的
# （本仓已有 2 处、实测都正确），把那种写法报成违规只会制造噪音，所以不查"定义前先调用"。
function Find-NestedFunction {
    param([string]$Path)
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs -and @($errs).Count -gt 0) { return $out }
    foreach ($d in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $q = $d.Parent
        while ($q) {
            if ($q -is [System.Management.Automation.Language.IfStatementAst] -or
                $q -is [System.Management.Automation.Language.ForEachStatementAst] -or
                $q -is [System.Management.Automation.Language.ForStatementAst] -or
                $q -is [System.Management.Automation.Language.WhileStatementAst] -or
                $q -is [System.Management.Automation.Language.TryStatementAst] -or
                $q -is [System.Management.Automation.Language.SwitchStatementAst] -or
                $q -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $out += [pscustomobject]@{ Line = $d.Extent.StartLineNumber; Func = $d.Name }
                break
            }
            $q = $q.Parent
        }
    }
    return $out
}

# 规则 9：调用了**不存在**的 .NET 成员。
# 实测事故（2026-10-05 发现）：`[System.IO.Directory]::GetAttributes` 这个方法压根不存在
# （`[System.IO.Directory].GetMethods()` 里没有它），于是它**恒抛 RuntimeException**：
#   * health-check 的 Get-Status 里，下游两个分支（$cls2 为空 → ok；属 missing 类 → missing）
#     成了死代码，所有走到那里的路径全被兜底成 'denied'；
#   * health-fix 的 Test-Missing 里同样两个分支死掉，一律 return $false（偏保守，所以没出事故）。
# 这类错误不报错、只静默改变判定 —— 正是本项目最怕的那种。判据用反射：代码行里出现
# `[类型]::成员(` 就用 GetMethods() 确认该类型真有这个方法（含继承的公开方法）。
# 只查带 `(` 的调用（属性/枚举值不查）；类型解析不了就跳过（不为拼错的类型名制造噪音）。
# 类型名是从 `[` 里取出的，再走 Invoke-Expression —— 判据正则把它限定成 `[A-Za-z_][\w.+]*`
# （不含引号/分号/括号/反引号），所以这里不存在"执行文件里任意代码"的风险。
function Find-MissingDotNetMember {
    param([string[]]$Lines)
    $out = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l.TrimStart().StartsWith('#')) { continue }
        foreach ($m in [regex]::Matches($l, '\[([A-Za-z_][\w\.\+]*)\]::([A-Za-z_]\w*)\s*\(')) {
            $typeName = $m.Groups[1].Value
            $member   = $m.Groups[2].Value
            # `::new(...)` 是 PowerShell 的构造语法，不是方法名（GetMethods() 里当然没有它）。
            if ($member -eq 'new') { continue }
            $t = $null
            try { $t = [type]::GetType($typeName, $false) } catch { $t = $null }
            if (-not $t) {
                # 短名（[Math]、[IO.File]、[regex]…）交给 PowerShell 自己的类型解析
                try { $t = Invoke-Expression ('[{0}]' -f $typeName) } catch { $t = $null }
            }
            if (-not $t) { continue }
            $found = @()
            try { $found = @($t.GetMethods() | Where-Object { $_.Name -eq $member }) } catch { $found = @() }
            if ($found.Count -eq 0) {
                if (Test-LintExempt $Lines $i) { continue }
                $out += [pscustomobject]@{ Line = $i + 1; Text = $l.Trim(); Type = $typeName; Member = $member }
            }
        }
    }
    return $out
}

# 规则 8：scripts\ 下不得出现**机器专属路径字面量**（硬性约定 8 的机械部分）。
# 判据（刻意保守，宁漏不误报）：
#   * 盘符不是 C: 的绝对路径（`D:\...`、`E:\...`）—— C: 是 Windows 的默认系统盘，系统路径
#     （C:\Windows、C:\Program Files…）与注册表路径（HKLM:\…、HKCU:\…）都放行；
#   * `C:\Users\<具体名字>`：占位符 `<...>` / 变量 `$...` / 环境变量 `%...%` 开头的放行
#     （`"C:\Users\$OldProfileName"` 是通用规则，不是机器值）。
# 目标是拦住"把本机布局写进产品脚本"这一类：同一张表在别人机器上要么空转，要么把登记
# 改写成另一个不存在的路径。含 `<`（占位符惯例）或 `...` 的字面量视为模板，放行。
# 只查 scripts\：tests\ 里的 D:\New / C:\Users\old 是**合成的**测试夹具，不是机器值。
function Find-MachinePathLiteral {
    param([string[]]$Lines)
    $out = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l.TrimStart().StartsWith('#')) { continue }
        $lits = @()
        foreach ($m in [regex]::Matches($l, "'([^']*)'"))    { $lits += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($l, '"([^"]*)"'))    { $lits += $m.Groups[1].Value }
        foreach ($v in $lits) {
            if ($v -notmatch '[A-Za-z]:\\') { continue }
            if ($v -match '<' -or $v -match '\.\.\.') { continue }   # 模板/占位符
            $bad = $false
            if ($v -match '(^|[^A-Za-z0-9])[D-Zd-z]:\\') { $bad = $true }          # 非系统盘
            elseif ($v -match '^C:\\Users\\([^\\]+)') {
                if ($matches[1] -notmatch '^[<$%]') { $bad = $true }               # 具体用户名
            }
            if (-not $bad) { continue }
            if (Test-LintExempt $Lines $i) { continue }
            $out += [pscustomobject]@{ Line = $i + 1; Text = $l.Trim(); Literal = $v }
        }
    }
    return $out
}

Test-Case '规则自测：每条规则都能抓到已知违规，也不误报' {
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
    # 规则 4 需要真实文件才能解析
    $probe = Join-Path ([IO.Path]::GetTempPath()) ('wmh-lint-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $fixture = @(
            'function Bad { Say ''x''; return $false }'
            'function Good { $null = Say ''x''; return $false }'
            'function GoodNoValueReturn { Say ''x'' }'
            'function GoodPiped { Say ''x'' | Out-Null; return $true }'
        )
        Set-Content -LiteralPath $probe -Encoding ascii -Value $fixture
        $hits = @(Find-SayPollutingReturn $probe)
        Assert-Equal $hits.Count 1 ("应当只抓到 Bad 一处，实际 {0}（{1}）" -f $hits.Count, (($hits | ForEach-Object { $_.Func }) -join ','))
        Assert-Equal $hits[0].Func 'Bad' '抓到的应当是 Bad'
    } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    # 规则 5 也需要真实文件
    $probe2 = Join-Path ([IO.Path]::GetTempPath()) ('wmh-lint5-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $fixture2 = @(
            '$backupDir = ''file-scope'''
            'function F { $script:BackupDir = ''clash'' }'
            'function G { $script:backupDir = ''same-casing-ok'' }'
            'function H { $script:RunThing = ''no-file-scope-counterpart'' }'
        )
        Set-Content -LiteralPath $probe2 -Encoding ascii -Value $fixture2
        $hits2 = @(Find-ScopeCasingClash $probe2)
        Assert-Equal $hits2.Count 1 ("规则 5 应当只抓到 1 处，实际 {0}" -f $hits2.Count)
        Assert-Equal $hits2[0].FileVar 'backupDir' '抓到的应当是 $backupDir 与 $script:BackupDir 的撞车'
    } finally { Remove-Item -LiteralPath $probe2 -Force -ErrorAction SilentlyContinue }

    # 规则 6 也需要真实文件
    $probe3 = Join-Path ([IO.Path]::GetTempPath()) ('wmh-lint6-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $fixture3 = @(
            'function A { try { x } catch {} }'
            'function B { try { x } catch { } }   # 读不到就当没有'
            'function C { try { x } catch { $global:y = 1 } }'
            'function D {'
            '    try { x } catch {'
            '        # 读不到就当没有'
            '    }'
            '}'
        )
        Set-Content -LiteralPath $probe3 -Encoding ascii -Value $fixture3
        $hits3 = @(Find-SilentCatch $probe3)
        Assert-Equal $hits3.Count 1 ("规则 6 应当只抓到 A 一处，实际 {0}" -f $hits3.Count)
    } finally { Remove-Item -LiteralPath $probe3 -Force -ErrorAction SilentlyContinue }
    # 规则 7：嵌在 if / foreach / 函数里的定义必须被抓到；顶层的不得误报
    $probe4 = Join-Path ([IO.Path]::GetTempPath()) ('wmh-lint7-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $fixture4 = @(
            'function OkTopLevel { return 1 }'
            'if ($true) {'
            '    function NestedInIf { return 2 }'
            '}'
            'foreach ($x in 1..2) {'
            '    function NestedInLoop { return 3 }'
            '}'
            'function Outer {'
            '    function NestedInFunction { return 4 }'
            '}'
        )
        Set-Content -LiteralPath $probe4 -Encoding ascii -Value $fixture4
        $hits4 = @(Find-NestedFunction $probe4)
        Assert-Equal $hits4.Count 3 ("规则 7 应当抓到 3 处（if/foreach/函数内），实际 {0}（{1}）" -f $hits4.Count, (($hits4 | ForEach-Object { $_.Func }) -join ','))
    } finally { Remove-Item -LiteralPath $probe4 -Force -ErrorAction SilentlyContinue }
    # 规则 8：机器专属路径字面量
    $c = @(Find-MachinePathLiteral @("@{ Old = 'C:\X'; New = 'D:\Apps\Installed\Y' }")).Count
    Assert-True ($c -eq 1) ("非 C 盘路径字面量应抓到 1 处，实际 {0}" -f $c)
    $c = @(Find-MachinePathLiteral @('$k = ''HKLM:\Software\Classes\x''')).Count
    Assert-True ($c -eq 0) ("注册表路径不该被抓到，实际 {0}" -f $c)
    $c = @(Find-MachinePathLiteral @('$p = ''C:\Program Files (x86)\x''')).Count
    Assert-True ($c -eq 0) ("系统路径不该被抓到，实际 {0}" -f $c)
    $c = @(Find-MachinePathLiteral @('$p = ''C:\Users\<旧用户名>\x''')).Count
    Assert-True ($c -eq 0) ("占位符应当放行，实际 {0}" -f $c)
    $c = @(Find-MachinePathLiteral @('$p = ''C:\Users\someone\x''')).Count
    Assert-True ($c -eq 1) ("具体用户名应抓到 1 处，实际 {0}" -f $c)
    $c = @(Find-MachinePathLiteral @('$p = "C:\Users\$OldName\x"')).Count
    Assert-True ($c -eq 0) ("变量拼接应当放行，实际 {0}" -f $c)
    $c = @(Find-MachinePathLiteral @('# D:\OldAppFolder')).Count
    Assert-True ($c -eq 0) ("整行注释不该被抓到，实际 {0}" -f $c)
    $c = @(Find-MachinePathLiteral @('# lint-ok: 模板示例', '''D:\OldAppFolder'',''')).Count
    Assert-True ($c -eq 0) ("上一行豁免应当生效，实际 {0}" -f $c)
    # 规则 9：不存在的 .NET 成员
    $c = @(Find-MissingDotNetMember @("[void][System.IO.Directory]::GetAttributes('C:\')")).Count
    Assert-True ($c -eq 1) ("不存在的成员应抓到 1 处，实际 {0}" -f $c)
    $c = @(Find-MissingDotNetMember @("[void][System.IO.File]::GetAttributes('C:\')")).Count
    Assert-True ($c -eq 0) ("存在的成员不该被抓到，实际 {0}" -f $c)
    $c = @(Find-MissingDotNetMember @('$m = [regex]::Match(''a'', ''b'')')).Count
    Assert-True ($c -eq 0) ("短类型名也要能解析，实际 {0}" -f $c)
    $c = @(Find-MissingDotNetMember @("[System.IO.File]::NoSuchMethodXyz('C:\')")).Count
    Assert-True ($c -eq 1) ("拼错的方法名应抓到 1 处，实际 {0}" -f $c)
    $c = @(Find-MissingDotNetMember @("[Some.UnloadableType]::Foo('x')")).Count
    Assert-True ($c -eq 0) ("类型加载不了应跳过，实际 {0}" -f $c)
    $c = @(Find-MissingDotNetMember @('[System.IO.File]::ReadAllText  # 无括号，不查属性')).Count
    Assert-True ($c -eq 0) ("不查属性/字段，实际 {0}" -f $c)
    $c = @(Find-MissingDotNetMember @('$e = [Text.UTF8Encoding]::new($true)')).Count
    Assert-True ($c -eq 0) ("::new() 是构造语法，不该被抓到，实际 {0}" -f $c)
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

Test-Case '日志函数 Say 的输出不会污染有值返回的函数（实测出过假绿）' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-SayPollutingReturn $f.FullName | ForEach-Object { "{0}:{1}  在函数 {2} 里裸写 Say" -f $f.Name, $_.Line, $_.Func })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '硬性约定 14：没有"仅大小写不同"的变量名撞车（PowerShell 变量名不区分大小写）' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-ScopeCasingClash $f.FullName | ForEach-Object { "{0}:{1}  ${2} 与 {3} 是同一个变量" -f $f.Name, $_.Line, $_.FileVar, $_.Scoped })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '空的 catch 必须写明为什么可以吞（空 catch 会把"做不到"变成"看起来做到了"）' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-SilentCatch $f.FullName | ForEach-Object { "{0}:{1}  {2}" -f $f.Name, $_.Line, ($_.Text -replace '^(.{0,44}).*', '$1') })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '函数定义必须在顶层（实测：插进 if 分支里会静默失效，且 extract 型测试抓不到）' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-NestedFunction $f.FullName | ForEach-Object { "{0}:{1}  函数 {2} 嵌在分支/函数里" -f $f.Name, $_.Line, $_.Func })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '硬性约定 8：scripts\ 下不得出现机器专属路径字面量（换机器就会失效或误改）' {
    # 只扫 scripts\（产品）；tests\ 里的 D:\New / C:\Users\old 是合成的夹具，不是机器值。
    # 这条规则是本次"把 $pathMapBase 搬空"的防复发装置：搬走了还得保证搬不回来。
    $bad = @()
    foreach ($f in (Get-ChildItem (Join-Path $repo 'scripts') -Recurse -File -Filter '*.ps1')) {
        $bad += @(Find-MachinePathLiteral (Get-Content $f.FullName -Encoding UTF8) | ForEach-Object { "{0}:{1}  字面量={2}" -f $f.Name, $_.Line, $_.Literal })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Test-Case '硬性约定 10：脚本里不许调用不存在的 .NET 成员（实测：Directory.GetAttributes 根本不存在）' {
    $bad = @()
    foreach ($f in Get-LintTargets) {
        $bad += @(Find-MissingDotNetMember (Get-Content $f.FullName -Encoding UTF8) | ForEach-Object { "{0}:{1}  [{2}]::{3}" -f $f.Name, $_.Line, $_.Type, $_.Member })
    }
    Assert-True ($bad.Count -eq 0) (($bad | Select-Object -First 3) -join ' / ')
}

Complete-TestRun 'lint'
