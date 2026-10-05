# ============================================================================
#  tests/repair.config.tests.ps1 —— repair 的配置层：不许把"没查"写成"没事"
#
#  这一类 bug 在本项目出现过三次，症状完全一样（报告说没事，其实一条都没查）：
#    1. 本机映射只有 1 条时，`$localPathMap = if (...) { @($x) } else { @() }` 的输出被拆包成
#       Hashtable，`$Hashtable + $Object[]` 抛 "A hash table can only be added to another hash
#       table."；$ErrorActionPreference='Continue' 让它成为**非终止**错误 → $pathMap 空着 →
#       打印 "(none: every registration already points at an existing path)" 并 exit 0；
#    2. 本机配置语法坏了：Import-PowerShellDataFile 的解析失败同样是**非终止**错误，赋值落空成
#       $null → "配置写坏了"被当成"没有配置"，脚本照样跑完并报"无需改指"；
#    3. 映射表为空时，报告里那句"（本机已无需改指的登记）"把"没查"写成了"没事"。
#  修法都落在"0 条 / 读不到"必须显式报错 + 非 0 退出码上。
#
#  分工：
#    * 形状问题（1）由 tests\repair.mapping.tests.ps1 的 Merge-PathMap 单测覆盖（不用子进程）
#    * 本文件真跑子进程，验证"配置缺失 / 配置损坏"两种状态的**退出码与输出**
#      这两条都在 discovery 那步之前就退出了，所以很快（discovery 才是慢的那一步：
#      reg query /f /s 在 Classes 子树上是分钟级 —— 见 README 里 health-check 的同类教训）。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\repair-migrated-apps.ps1'
# 用当前正在跑的引擎去跑被测脚本，于是两个引擎下都会各测一遍
$engine = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh' } else { 'powershell' }

function New-RepairSandbox {
    param([string]$Tag, [string]$LocalPsd1)
    # 把被测脚本复制到一个临时"仓库根"下，于是它的 local\ 配置指向试验田而不是真仓库
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wmh-repaircfg-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'scripts') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'local')   -Force
    Copy-Item -LiteralPath $target -Destination (Join-Path $tmp 'scripts\repair-migrated-apps.ps1')
    if ($LocalPsd1) {
        Set-Content -LiteralPath (Join-Path $tmp 'local\repair-migrated-apps.local.psd1') -Value $LocalPsd1 -Encoding UTF8
    }
    return $tmp
}

function Invoke-RepairDryRun {
    param([string]$Root)
    # 默认就是试运行（只读）；stderr 也收进来一起断言
    $out = & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\repair-migrated-apps.ps1') 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
}

Test-Case '没有本机配置时：明确报"未执行有效检查"并以退出码 3 结束（不是 0）' {
    $tmp = New-RepairSandbox -Tag 'none' -LocalPsd1 ''
    try {
        $r = Invoke-RepairDryRun $tmp
        Assert-Equal $r.Code 3 ("没有映射时退出码应当是 3（0 会被读成「成功」），实际 {0}" -f $r.Code)
        Assert-Match    $r.Text '未执行有效检查' '必须明确报告"未执行有效检查"'
        # 两个"假绿"标志都不许出现：改造前的汇总括号、以及那句英文"(none: ...)"。
        # 注意别用更短的 '已无需改指' —— guard 自己的提示里就引用了这句话（"不要读成..."）。
        Assert-NotMatch $r.Text '已无需改指的登记' '绝不能把"没有映射"说成"无需改指"'
        Assert-NotMatch $r.Text 'every registration already points at an existing path' '绝不能打印那句"全都指向存在的路径"'
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case '本机配置语法坏了：必须致命退出（不许降级成"没有配置"）' {
    # 尾逗号：在 psd1 里是语法错误，Import-PowerShellDataFile 必然失败。
    # 旧写法下这个失败是**非终止**的 → $script:Cfg 静默变成 $null → 脚本继续跑完并报"无需改指"。
    $broken = "@{`n    PathMap = @(`n        @{ Old = 'C:\Broken'; New = 'D:\Broken' },`n    )`n}`n"
    $tmp = New-RepairSandbox -Tag 'broken' -LocalPsd1 $broken
    try {
        $r = Invoke-RepairDryRun $tmp
        Assert-Equal $r.Code 3 ("配置损坏时退出码应当是 3，实际 {0}" -f $r.Code)
        Assert-Match $r.Text '未执行有效检查' '必须明确报告"未执行有效检查"（而不是静默按空配置继续）'
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Complete-TestRun 'repair.config'
