# ============================================================================
#  tests/health-check.needles.tests.ps1 —— 旧路径清单的"假绿"防护
#
#  背景（本项目最危险的一类 bug）：旧路径残留扫描原本只判断"命中 0 个键"，就打印
#  "✓ 注册表中已无这些旧路径的引用（回归检查通过）"。于是当清单文件为空（只有注释）
#  或全是占位符时，报告会显示一个**绿色的通过标记**——而检查根本没做。
#  这和 PS7 把"缺失"误判成"读不到"是同一类假阴性。
#
#  分两层测：
#    * 单测：用 AST 抽出脚本里真实的 Get-NeedlesState，验证三种状态判定（默认跑）
#    * 集成：把真脚本复制到临时目录、喂一份只有注释的清单、真跑一次体检，
#            再检查报告与 findings.csv（约 2 分钟/引擎，默认跳过，CI 上启用）
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\health-check.ps1'

Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Get-NeedlesState')

Test-Case '清单为空 -> empty（自动播种的模板就是这种情况）' {
    Assert-Equal (Get-NeedlesState @()) 'empty' '空数组应为 empty'
    Assert-Equal (Get-NeedlesState $null) 'empty' '$null 应为 empty'
}

Test-Case '清单全是占位符 -> placeholder' {
    Assert-Equal (Get-NeedlesState @('C:\Users\<旧用户名>')) 'placeholder' '尖括号占位符应判 placeholder'
    Assert-Equal (Get-NeedlesState @('D:\Apps\Portable\<搬走前的旧名字>', 'C:\Users\<旧用户名>')) 'placeholder' '多条占位符应判 placeholder'
    Assert-Equal (Get-NeedlesState @('C:\Users\旧名')) 'placeholder' '含"旧名"应判 placeholder'
}

Test-Case '只要有一条真实路径 -> ok' {
    Assert-Equal (Get-NeedlesState @('C:\Users\<旧用户名>', 'D:\OldAppFolder')) 'ok' '混有真实路径应为 ok'
    Assert-Equal (Get-NeedlesState @('D:\mpv-lazy')) 'ok' '真实路径应为 ok'
}

if (-not $env:SLOW_TESTS) {
    Skip-Test '集成：空清单时必须报"未执行有效检查"，且不得出现"回归检查通过"' `
        '真跑一次完整体检约 2 分钟/引擎；设 $env:SLOW_TESTS=1 启用（CI 上默认启用）'
} else {
    Test-Case '集成：空清单时必须报"未执行有效检查"，且不得出现"回归检查通过"' {
        # 用当前正在跑的引擎去跑被测脚本，于是两个引擎下都会各测一遍
        $engine = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh' } else { 'powershell' }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wmh-hc-' + [guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'scripts') -Force
            Copy-Item -LiteralPath $target -Destination (Join-Path $tmp 'scripts\health-check.ps1')
            # 只含注释的清单 = 脚本首次运行自动播种出来的那一份
            @('# 一行一个旧路径', '# C:\Users\<旧用户名>', '# D:\OldAppFolder') |
                Set-Content -LiteralPath (Join-Path $tmp 'scripts\health-check.needles.txt') -Encoding UTF8

            $outDir = Join-Path $tmp 'reports'
            # 只读体检；子进程退出码可能是 1（有严重项），与本测试无关，故不检查
            & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\health-check.ps1') `
                -OutDir $outDir -SkipAssocScan -SkipClsidScan 2>&1 | Out-Null

            # 注意：$outDir 下除了 <时间戳>\ 还有 history\。按名字倒序时 history 会排在前面
            # （'h' > 数字），第一次写这个测试就因此跑到 history 里找 report.md 而误报失败。
            $runDirs = @(Get-ChildItem -LiteralPath $outDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d{8}-\d{4}$' } | Sort-Object Name -Descending)
            Assert-True ($runDirs.Count -ge 1) '体检没有产出报告目录（子进程可能运行失败）'
            $runDir = $runDirs[0].FullName

            $reportPath = Join-Path $runDir 'report.md'
            Assert-True (Test-Path -LiteralPath $reportPath) '报告文件不存在'
            $report = [IO.File]::ReadAllText($reportPath, (New-Object Text.UTF8Encoding($false)))

            Assert-Match    $report '未执行有效检查' '空清单必须明确报告"未执行有效检查"'
            Assert-NotMatch $report '回归检查通过'   '空清单绝不能出现"回归检查通过"这个绿标记'

            $rows = @(Import-Csv -LiteralPath (Join-Path $runDir 'findings.csv') -Encoding UTF8)
            Assert-True (@($rows | Where-Object { $_.Category -eq '旧路径残留' }).Count -ge 1) 'findings.csv 里应当有"旧路径残留"的警告行'

            # 顺带覆盖 FIX-15：没加 -NoHistory 时必须真的写出快照
            Assert-True (Test-Path -LiteralPath (Join-Path $runDir 'snapshot.json')) '未加 -NoHistory 时应写出 snapshot.json'

            # 报告文件必须是**完整**的：W() 靠缓冲区凑满 25 行才落盘、章节边界由 Section() 负责，
            # 所以脚本结尾若忘了最后那次 flush，末尾一批内容就只到屏幕、不进文件。
            # 实测过：report.md 停在 "### 14.2 严重项逐条明细"，屏幕上却看着完整 —— 因为
            # W() 同时 Write-Host。用户保存/转发的正是这个文件，所以这条必须是断言。
            Assert-Match $report '\*\*下一步怎么做\*\*' '报告文件被截断：结尾的"下一步怎么做"没有落盘'
            Assert-Match $report '14\.2 严重项逐条明细'  '报告文件缺少 14.2 严重项明细段'
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Complete-TestRun 'health-check.needles'
