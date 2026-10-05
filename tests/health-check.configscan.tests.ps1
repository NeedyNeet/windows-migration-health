# ============================================================================
#  tests/health-check.configscan.tests.ps1 —— "文本配置里的旧路径"那一步的假绿防护
#
#  背景：这一段的目标是"扫程序根目录下的 conf/ini/json…，看还有没有写死的旧路径"。
#  它有过两次假绿：
#    * 清单为空时会遍历 0 个关键词并打印 "- ✓ 未发现"；
#    * 扫描根原来**写死**成 D:\Apps —— 在别的机器上根不存在，于是整段只剩一个空标题，
#      连"未发现"都没有：最容易被读成"没问题"的形状。
#  现在扫描根由 -AppsRoot 给出，且 缺根 / 根下没有可扫文件 两种状态必须能被区分出来。
#  本套件真跑抽出来的那个纯函数（AST 抽取，测的是脚本里的真实代码）。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\health-check.ps1'

Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Get-ConfigFileOldPathHits')

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wmh-cfgscan-' + [guid]::NewGuid().ToString('N').Substring(0,6))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force

try {
    Test-Case '根不存在 -> no-root（不是「未发现」）' {
        $r = Get-ConfigFileOldPathHits -Root (Join-Path $tmpRoot 'nope') -Needles @('C:\Users\old')
        Assert-Equal @($r).Count 1 ("返回值应恰好 1 个元素，实际 {0}" -f @($r).Count)
        Assert-Equal $r.Status 'no-root' '根不存在应当是 no-root'
        Assert-Equal $r.Files 0 '根不存在时扫到的文件数应当是 0'
        Assert-Equal @($r.Hits).Count 0 '根不存在时不该报任何命中'
    }

    Test-Case '空目录 / 只有不在扩展名清单里的文件 -> no-files' {
        $empty = Join-Path $tmpRoot 'empty'; $null = New-Item -ItemType Directory -Path $empty -Force
        $r = Get-ConfigFileOldPathHits -Root $empty -Needles @('C:\Users\old')
        Assert-Equal $r.Status 'no-files' '空目录应当是 no-files（不许说成"未发现"）'
        Assert-Equal $r.Files 0 '空目录文件数应为 0'

        $onlyMd = Join-Path $tmpRoot 'onlymd'; $null = New-Item -ItemType Directory -Path $onlyMd -Force
        Set-Content -LiteralPath (Join-Path $onlyMd 'readme.md') -Value 'C:\Users\old' -Encoding UTF8
        $r2 = Get-ConfigFileOldPathHits -Root $onlyMd -Needles @('C:\Users\old')
        Assert-Equal $r2.Status 'no-files' '.md 不在扫描扩展名清单里，应当判 no-files 而不是"扫过且干净"'
    }

    Test-Case '有配置文件且命中 -> ok + 命中明细（含 Needle）' {
        $dir = Join-Path $tmpRoot 'hit'; $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.ini') -Value 'path=C:\Users\old\AppData\x' -Encoding UTF8
        $r = Get-ConfigFileOldPathHits -Root $dir -Needles @('C:\Users\old')
        Assert-Equal $r.Status 'ok' '有文件且能扫，状态应当是 ok'
        Assert-Equal $r.Files 1 ("应当扫到 1 个文件，实际 {0}" -f $r.Files)
        Assert-Equal @($r.Hits).Count 1 ("应当命中 1 处，实际 {0}" -f @($r.Hits).Count)
        Assert-Equal $r.Hits[0].Needle 'C:\Users\old' '命中里要带上是哪条关键词'
    }

    Test-Case '有配置文件但没命中 -> ok + Files（结论要能说出"扫了几个"）' {
        $dir = Join-Path $tmpRoot 'clean'; $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.cfg') -Value 'path=C:\Current\place' -Encoding UTF8
        $r = Get-ConfigFileOldPathHits -Root $dir -Needles @('C:\Users\old')
        Assert-Equal $r.Status 'ok' '有文件且能扫，状态应当是 ok'
        Assert-Equal $r.Files 1 ("应当扫到 1 个文件，实际 {0}" -f $r.Files)
        Assert-Equal @($r.Hits).Count 0 '不该有命中'
    }

    Test-Case '递归子目录会扫到，不在清单里的扩展名不会被算进 Files' {
        $dir = Join-Path $tmpRoot 'nested'; $null = New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force
        Set-Content -LiteralPath (Join-Path $dir 'sub\deep.json') -Value '{"p":"C:\Users\old"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'note.md')       -Value 'C:\Users\old'        -Encoding UTF8
        $r = Get-ConfigFileOldPathHits -Root $dir -Needles @('C:\Users\old')
        Assert-Equal $r.Files 1 ("只应把 .json 计进文件数（.md 不在清单里），实际 {0}" -f $r.Files)
        Assert-Equal @($r.Hits).Count 1 ("应当命中 1 处（子目录里的那份），实际 {0}" -f @($r.Hits).Count)
    }
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-TestRun 'health-check.configscan'
