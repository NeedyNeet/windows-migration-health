# ============================================================================
#  tests/health-fix.config.tests.ps1 —— 本机配置的三个失败模式必须分得清
#
#  背景：health-fix 的 A 段（旧路径 -> 新路径改指）完全由 local\health-fix.local.psd1 驱动。
#  这段代码原来长这样：
#      if (Test-Path -LiteralPath $script:CfgPath) { $script:Cfg = Import-PowerShellDataFile ... }
#  三种失败模式全都会**静默退化成"没有配置"**：
#    * 文件不存在        -> 提示一句"将不生效（正常）"，合理；
#    * 文件读不到（权限）-> 裸 Test-Path 静默返回 False，被当成"不存在"（约定 10：读不到 ≠ 不存在）；
#    * 文件语法坏了      -> Import-PowerShellDataFile 的失败在 $ErrorActionPreference='Continue'
#                          下是**非终止**错误，赋值落空成 $null —— 于是 A 段一条规则都不生效，
#                          而输出只有那句"将不生效（正常）"，报告整体看起来是"跑完了"。
#  现在读取逻辑抽成 Read-LocalConfig，状态分 ok / missing / denied / broken，调用方对
#  denied 与 broken 一律致命退出（exit 3）。本套件真跑抽出来的那个函数。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\health-fix.ps1'

Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Read-LocalConfig')

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wmh-hfcfg-' + [guid]::NewGuid().ToString('N').Substring(0,6))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force

try {
    Test-Case '文件不存在 -> missing（正常：该文件属于本机、不进仓库）' {
        $r = Read-LocalConfig (Join-Path $tmpRoot 'nope.psd1')
        Assert-Equal @($r).Count 1 ("返回值应恰好 1 个元素，实际 {0}" -f @($r).Count)
        Assert-Equal $r.Status 'missing' '不存在的配置应当是 missing'
        Assert-True ($null -eq $r.Cfg) 'missing 时 Cfg 应当是 $null'
    }

    Test-Case '空路径 / $null -> missing，且不抛异常' {
        Assert-Equal (Read-LocalConfig '').Status 'missing' '空路径应当是 missing'
        Assert-Equal (Read-LocalConfig $null).Status 'missing' '$null 应当是 missing'
    }

    Test-Case '语法坏了（尾逗号）-> broken，**不许**降级成 missing' {
        $p = Join-Path $tmpRoot 'broken.psd1'
        Set-Content -LiteralPath $p -Value "@{`n    Repoint = @(`n        @{ Path = 'HKLM:\x'; Old = 'a'; New = 'b' },`n    )`n}`n" -Encoding UTF8
        $r = Read-LocalConfig $p
        Assert-Equal $r.Status 'broken' ("语法错误必须判 broken（旧实现下它会静默变成 `$null 然后被当成'没有配置'），实际 {0}" -f $r.Status)
        Assert-True ([bool]$r.Error) 'broken 时应带上错误信息（便于用户直接看到原因）'
    }

    Test-Case '读得到 -> ok，且单条 / 多条映射都完整读进来' {
        $one = Join-Path $tmpRoot 'one.psd1'
        Set-Content -LiteralPath $one -Value "@{`n    Repoint = @(`n        @{ Path = 'HKLM:\x'; Old = 'C:\Old'; New = 'D:\New'; Why = 'test' }`n    )`n}`n" -Encoding UTF8
        $r1 = Read-LocalConfig $one
        Assert-Equal $r1.Status 'ok' '合法文件应当是 ok'
        Assert-Equal @($r1.Cfg.Repoint).Count 1 ("单条映射也要读成 1 条，实际 {0}" -f @($r1.Cfg.Repoint).Count)

        $two = Join-Path $tmpRoot 'two.psd1'
        Set-Content -LiteralPath $two -Value "@{`n    Repoint = @(`n        @{ Path = 'HKLM:\x'; Old = 'a'; New = 'b' },`n        @{ Path = 'HKLM:\y'; Old = 'c'; New = 'd' }`n    )`n}`n" -Encoding UTF8
        $r2 = Read-LocalConfig $two
        Assert-Equal $r2.Status 'ok' '合法文件应当是 ok'
        Assert-Equal @($r2.Cfg.Repoint).Count 2 ("两条映射要读成 2 条，实际 {0}" -f @($r2.Cfg.Repoint).Count)
    }

    Test-Case '调用方对 denied / broken 必须致命退出（不是提示一句继续跑）' {
        # 静态守卫：这条函数测的是"状态判得对不对"，而"判对了之后有没有真的停下来"只能看调用方。
        # 判据只看代码行（注释里正解释着这段历史）。
        $code = (@([IO.File]::ReadAllLines($target, [Text.Encoding]::UTF8)) |
                 Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
        Assert-Match $code 'Read-LocalConfig \$script:CfgPath' '配置必须经由 Read-LocalConfig 读取'
        Assert-Match $code 'exit 3'                             'denied / broken 必须致命退出（非 0），否则 A 段静默失效'
        Assert-NotMatch $code 'Test-Path -LiteralPath \$script:CfgPath' '不许再用裸 Test-Path 判配置是否存在（读不到 ≠ 不存在）'
        Assert-NotMatch $code '\$repoint = if \('               '不许再用 if 语句给 $repoint 赋值（单元素会被拆包）'
    }
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-TestRun 'health-fix.config'
