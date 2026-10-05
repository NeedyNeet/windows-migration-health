# ============================================================================
#  tests/repair.mapping.tests.ps1 —— 迁移映射表的行为与顺序不变量
#
#  顺序敏感是真实踩过的坑：quark 的资源放在带版本号的 app-<version> 子目录里，
#  通用的 quark-cloud-drive 那条若排在前面，就会把路径改成一个**不存在**的位置
#  （好在该脚本写入前会校验目标存在，于是退化为"报出来但修不了"，而不是写坏）。
#
#  去分叉时把这个映射表搬进 local\*.local.psd1，而 psd1 不允许 [ordered]，
#  所以改成「数组 + Old/New」来保住顺序。这个套件就是那次设计的回归网。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo = Get-RepoRoot
$target = Join-Path $repo 'scripts\repair-migrated-apps.ps1'

Test-Case '内置映射表为空：具体路径一律在 local 配置里（硬性约定 8）' {
    # 这张表曾经写死在脚本里（8 条本机路径，含钉版本的 app-3.19.0）。它天生是本机的：
    # 换台机器要么空转，要么把别人的登记改写成另一个不存在的路径。README 也一直写着
    # "脚本本身不含任何机器专属信息、迁移映射表在仓库版里是占位符"——这条断言就是那句话的执行者。
    $text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    Assert-Match    $text '\$pathMapBase = @\(\)' '内置映射表应当是空数组（具体映射放 local\repair-migrated-apps.local.psd1）'
    Assert-NotMatch $text '(?m)^\s*@\{\s*Old\s*=' '脚本里不该再出现具体的 Old/New 映射条目'
}

Test-Case '映射用数组表达（psd1 不允许 [ordered]，数组才保得住顺序）' {
    $text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    Assert-Match $text '\$pathMapBase = @\(' 'pathMapBase 应当是数组'
    Assert-NotMatch $text '\$pathMapBase = \[ordered\]' 'pathMapBase 不应用 [ordered]'
}

Test-Case '顺序敏感的示例留在模板里（具体在前、通用在后）' {
    $tpl   = Join-Path $repo 'config\repair-migrated-apps.local.example.psd1'
    $lines = @(Get-Content -LiteralPath $tpl -Encoding UTF8)
    $i1 = -1; $i2 = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if     ($i1 -lt 0 -and $lines[$i] -match '\\resources''') { $i1 = $i }
        elseif ($i1 -ge 0 -and $i2 -lt 0 -and $lines[$i] -match '<程序>''') { $i2 = $i; break }
    }
    Assert-True ($i1 -ge 0) '模板里找不到"带 \resources 的具体前缀"示例'
    Assert-True ($i2 -ge 0) '模板里找不到"更短的通用前缀"示例'
    Assert-True ($i1 -lt $i2) ("模板里具体示例必须排在通用示例之前（行 {0} vs {1}）" -f ($i1 + 1), ($i2 + 1))
}

# ---- Merge-PathMap：合并的形状与顺序 ----
# 这段逻辑曾经靠调用方"恰好写对"而工作：`$localPathMap = if (...) { @($x) } else { @() }`
# 在本机只有 1 条映射时，语句输出被拆包成 Hashtable，`$Hashtable + $Object[]` 抛
# "A hash table can only be added to another hash table."；而 $ErrorActionPreference='Continue'
# 让它成为非终止错误 → $pathMap 空着 → 打印 "(none: ...)" + exit 0（一条没查却报没事）。
Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Merge-PathMap')

Test-Case 'Merge-PathMap：本机只有 1 条映射时也不许拆包（曾经就是这里假绿）' {
    $m = Merge-PathMap -Local @(@{ Old = 'C:\One'; New = 'D:\One' }) -Base @(@{ Old = 'C:\Base'; New = 'D:\Base' })
    Assert-True ($m -is [System.Collections.IDictionary]) ("合并结果应当是字典，实际 {0}" -f $(if ($null -eq $m) { 'NULL' } else { $m.GetType().Name }))
    Assert-Equal $m.Count 2 ("应当合并出 2 条，实际 {0}" -f $m.Count)
}

Test-Case 'Merge-PathMap：0/1/2/3 条本机映射时条数恒为 本机 + 内置' {
    foreach ($n in 0, 1, 2, 3) {
        $local = @()
        for ($i = 1; $i -le $n; $i++) { $local += @{ Old = "C:\L$i"; New = "D:\L$i" } }
        $m = Merge-PathMap -Local $local -Base @(@{ Old = 'C:\B'; New = 'D:\B' })
        Assert-Equal $m.Count ($n + 1) ("本机 {0} 条时应当合并出 {1} 条，实际 {2}" -f $n, ($n + 1), $m.Count)
    }
}

Test-Case 'Merge-PathMap：返回值形状恰好 1 个对象（不许被多余输出污染成数组）' {
    $m = Merge-PathMap -Local @() -Base @(@{ Old = 'C:\B'; New = 'D:\B' })
    Assert-Equal @($m).Count 1 ("返回值应恰好 1 个元素，实际 {0}" -f @($m).Count)
}

Test-Case 'Merge-PathMap：同一个 Old 只留一条，且本机条目优先' {
    $m = Merge-PathMap -Local @(@{ Old = 'C:\Same'; New = 'D:\Local' }) -Base @(@{ Old = 'C:\Same'; New = 'D:\Base' })
    Assert-Equal $m.Count 1 '重复的 Old 只应留一条'
    Assert-Equal $m['C:\Same'] 'D:\Local' '同一个 Old 应以本机条目为准（本机条目在前）'
}

Test-Case 'Merge-PathMap：顺序为先本机、后内置（更具体的条目先命中）' {
    $m = Merge-PathMap -Local @(@{ Old = 'C:\A\resources'; New = 'D:\A' }) -Base @(@{ Old = 'C:\A'; New = 'D:\B' })
    $keys = @($m.Keys)
    Assert-Equal $keys[0] 'C:\A\resources' '本机条目应当排在最前'
    Assert-Equal $keys[1] 'C:\A'           '内置条目排在其后'
}

# ---- 抽出真实的 Convert-MappedPath 与它依赖的助手来测行为 ----
# 注意：AST 抽取只拿**指定那一个**函数的定义，不会自动带上它调用的其它函数。
# 第一次加 Replace-PathLiteral 时忘了抽它，于是 6 条断言一起报"术语 ... 不是函数"。
Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Replace-PathLiteral')
Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Convert-MappedPath')

$pathMap = [ordered]@{
    'C:\App\resources' = 'D:\New\app-3.19.0\resources'
    'C:\App'           = 'D:\New'
}
$profileMap = [ordered]@{
    'C:\Users\old\' = 'C:\Users\new\'
    'C:\Users\old'  = 'C:\Users\new'
}

Test-Case '具体前缀优先命中，保住带版本号的子路径' {
    $r = Convert-MappedPath -Text 'C:\App\resources\icon.ico'
    Assert-Equal $r 'D:\New\app-3.19.0\resources\icon.ico' '具体前缀应优先于通用前缀'
}

Test-Case '无匹配时返回 $null（调用方据此判断"不用改"）' {
    $r = Convert-MappedPath -Text 'C:\Nothing\here.txt'
    Assert-True ($null -eq $r) '无匹配必须返回 $null'
}

Test-Case '用户目录映射只在显式开启 WithProfileMap 时生效' {
    $off = Convert-MappedPath -Text 'C:\Users\old\AppData\x.txt'
    Assert-True ($null -eq $off) '未开启时不该改写用户目录'
    $on = Convert-MappedPath -Text 'C:\Users\old\AppData\x.txt' -WithProfileMap
    Assert-Equal $on 'C:\Users\new\AppData\x.txt' '开启后应改写用户目录'
}

Test-Case '用户目录两条映射里，带尾反斜杠的那条先命中' {
    $on = Convert-MappedPath -Text 'C:\Users\old\' -WithProfileMap
    Assert-Equal $on 'C:\Users\new\' '应匹配带尾反斜杠的那条'
}

Test-Case '大小写不敏感匹配（注册表里路径大小写很乱）' {
    $r = Convert-MappedPath -Text 'c:\APP\resources\x.ico'
    Assert-Equal $r 'D:\New\app-3.19.0\resources\x.ico' '应当忽略大小写'
}

Test-Case '替换串里的 $ 必须当字面量（否则含 $ 的路径会被静默写错）' {
    # [regex]::Replace 的替换串把 $ 当特殊字符（$1/$&/$$…）。写 mapping 测试时发现
    # 原实现直接把 $pathMap[$old] 当替换串传进去，所以映射到含 $ 的路径会写错。
    $saved = $script:pathMap
    try {
        $script:pathMap = [ordered]@{ 'C:\App' = 'D:\Apps\$Recycle\bin' }
        $r = Convert-MappedPath -Text 'C:\App\x.exe'
        Assert-Equal $r 'D:\Apps\$Recycle\bin\x.exe' '替换串里的 $ 必须原样输出'
    } finally {
        $script:pathMap = $saved
    }
}

Test-Case '替换串里的 $& / $1 之类也不会被展开' {
    $saved = $script:pathMap
    try {
        $script:pathMap = [ordered]@{ 'C:\App' = 'D:\x$1y$&z' }
        $r = Convert-MappedPath -Text 'C:\App\f.txt'
        Assert-Equal $r 'D:\x$1y$&z\f.txt' '$1 与 $& 都必须原样输出'
    } finally {
        $script:pathMap = $saved
    }
}

Test-Case '合并处的写法：走 Merge-PathMap，且不许再用 if 语句给映射变量赋值' {
    # 原始 bug 的写法（`$localPathMap = if (...) { @($x) } else { @() }`）在**同一条语句**里就埋着
    # "单元素数组被拆包"的地雷。这一条把那种写法钉死，与上面的 Merge-PathMap 行为测试配成一对。
    # 判据只看**代码行**：脚本注释里正解释着那段旧写法，拿整份文件去匹配会把说明文字当成违规。
    $code = (@([IO.File]::ReadAllLines($target, [Text.Encoding]::UTF8)) |
             Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
    Assert-Match    $code '\$pathMap = Merge-PathMap -Local \$localPathMap -Base \$pathMapBase' '合并必须走 Merge-PathMap'
    Assert-NotMatch $code '\$localPathMap = if \('    '不该再用 if 语句给 $localPathMap 赋值（单元素会被拆包）'
    Assert-NotMatch $code '\$localProfileMap = if \(' '同上：$localProfileMap 也不该用 if 语句赋值'
}

Complete-TestRun 'repair.mapping'
