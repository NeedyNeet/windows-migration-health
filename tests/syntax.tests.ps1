# ============================================================================
#  tests/syntax.tests.ps1 —— 语法与数据文件可解析性（在**当前引擎**下）
#
#  为什么单独一条：AGENTS.md 的验收标准要求同一份脚本在 5.1 与 7.6 下语法都通过。
#  run-tests.ps1 会把每个套件在两个引擎下各跑一遍，于是这一条自动成为"双引擎语法校验"。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo = Get-RepoRoot

function Get-ParseErrors([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return @($errors)
}

$scriptPs1 = @(Get-ChildItem (Join-Path $repo 'scripts') -File -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue)
$testPs1   = @(Get-ChildItem (Join-Path $repo 'tests')   -File -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue)
$configPsd1 = @(Get-ChildItem (Join-Path $repo 'config') -File -Filter *.psd1 -ErrorAction SilentlyContinue)
$localPsd1  = @(Get-ChildItem (Join-Path $repo 'local')  -File -Filter *.local.psd1 -ErrorAction SilentlyContinue)

Test-Case 'scripts/ 下所有 .ps1 语法正确' {
    $bad = @()
    foreach ($f in $scriptPs1) {
        $e = Get-ParseErrors $f.FullName
        if ($e.Count -gt 0) { $bad += ("{0}: {1}" -f $f.Name, $e[0].Message) }
    }
    Assert-True ($bad.Count -eq 0) ($bad -join ' ; ')
}

Test-Case 'tests/ 下所有 .ps1 语法正确' {
    $bad = @()
    foreach ($f in $testPs1) {
        $e = Get-ParseErrors $f.FullName
        if ($e.Count -gt 0) { $bad += ("{0}: {1}" -f $f.Name, $e[0].Message) }
    }
    Assert-True ($bad.Count -eq 0) ($bad -join ' ; ')
}

Test-Case 'config/ 下的 .psd1 都能被 Import-PowerShellDataFile 读取' {
    $bad = @()
    foreach ($f in $configPsd1) {
        try { $null = Import-PowerShellDataFile -LiteralPath $f.FullName }
        catch { $bad += ("{0}: {1}" -f $f.Name, $_.Exception.Message) }
    }
    Assert-True ($bad.Count -eq 0) ($bad -join ' ; ')
}

Test-Case '本机真值 psd1（local/，若存在）能被读取且中文未损坏' {
    # 干净检出时 local/ 没有真值文件，这一条自然通过——那是正常的。
    foreach ($f in $localPsd1) {
        $cfg = Import-PowerShellDataFile -LiteralPath $f.FullName
        Assert-True ($null -ne $cfg) ("{0} 读取结果为 null" -f $f.Name)
        $json = $cfg | ConvertTo-Json -Depth 8 -Compress
        Assert-NotMatch $json ([char]0xFFFD) ("{0} 出现替换字符 U+FFFD，说明编码被破坏" -f $f.Name)
    }
}

# 这里曾有一条"psd1 里不许出现 [ordered]"的**纯文本扫描**检查，已删除，两个原因：
#   1. 它是冗余的：psd1 是受限语言，真写了 [ordered] 会让上面的
#      Import-PowerShellDataFile 直接抛错，那条测试就会失败 —— 那才是真正的语义检查。
#   2. 它会误报：注释里提到 "[ordered]"（例如解释"为什么不用它"）就会被命中。
#      （第一次跑这套测试时它就误报了一次。）
# 顺序敏感这件事改由 repair.mapping.tests.ps1 从"结构必须是数组"那一侧守住。

Complete-TestRun 'syntax'
