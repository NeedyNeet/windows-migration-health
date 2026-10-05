# ============================================================================
#  tests/health-check.dualengine.tests.ps1 —— 双引擎"结论一致"的执行者
#
#  仓库到处宣称的验收标准是："同一份脚本必须在 5.1 与 7.x 下都通过，且**结论一致**
#  （两份 findings.csv 零差异）"。前半句有执行者（CI 矩阵把每个套件在两台引擎下各跑一遍），
#  后半句一直是**手工**做的 —— 也就是说："5.1 与 7.x 报出不同结论"这类回归，没有任何东西会拦住它。
#  本套件把后半句机器化。
#
#  做法：把真脚本复制到临时目录，喂一份**受控**的清单，然后分别用两个引擎各跑一次体检
#  （关掉最慢的两项扫描以压时间），最后逐行对比 findings.csv。
#
#  ⚠ 清单为什么是"受控输入"而不是 `C:\Program Files` 这类宽清单：两个引擎是**先后**跑的
#  （相隔数分钟），而 Windows 在这期间会自己改注册表 —— 宽清单会把那些变化也扫进来，
#  于是"零差异"必然随机失败。两次真实假红（CI，2026-10-05）：
#    · `HKCU\…\Local Settings\MrtCache\…WindowsTerminal…` 多了一条（差 1 行，131,397 vs 131,398）；
#    · `HKLM\…\Appx\AppAllUserStore\…SecHealthUI…` 的**包版本号**在两次之间从 1000.26100 变成 1000.29628，
#      `AppModel\StateRepository\Cache\Package\Data` 的子键号从 35 变成 40（差 8 行）。
#  靠"排除易变位置"是打地鼠（第二次假红就换了地方）。现在改成：在 `HKCU\Software\Classes` 下
#  （清单扫描的根之一）造一个带**唯一 GUID** 的 ProgID，清单就是那个 GUID —— 只有我们造的键会命中，
#  比较结果因此是**确定的**：出现任何"不属于 fixture 的行"本身就是真信号。
#  安全底线沿用 tests\writepath.tests.ps1 的约定：只在 `_wmh_selftest` 前缀下、全在 HKCU、
#  结束删除并检查删干净了（它改的不是仓库，CI 里那条"跑完仓库必须干净"的断言查的是 git status）。
#
#  其余刻意设计：
#    * 全新 OutDir + `-NoHistory`：不引入"上次快照"这个变量；
#    * 先断言两次都**真的产出了行**：0 行对 0 行也会"零差异"，那是假绿；
#    * 断言**每一行都属于 fixture**：清单没被隔离时立刻失败，而不是悄悄多比几百行；
#    * 失败时打印前几处差异与所在引擎，否则调试只能靠猜。
#  成本：本机实测约 3 分钟（子进程占绝大部分）。默认跳过，CI 上启用（SLOW_TESTS=1）。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\health-check.ps1'

# 试验田前缀：与 writepath.tests.ps1 用同一个标记，便于一眼看出"这是测试造的"
$script:FixturePrefix = '_wmh_selftest_dualengine_'

# 引擎可启动性自检 —— 与 run-tests.ps1 里那块同一个理由（那边叫 wmh-probe-ok）：
# **MSIX（Microsoft Store）版 pwsh 被 5.1 启动时是"应用激活"而不是子进程**，重定向会得到 0 字节、
# $LASTEXITCODE 为空，甚至会直接报 "The requested operation requires elevation"。
# 实测事故（本套件第一次跑）：托管在 5.1 时 `& pwsh` 启动失败 → 套件中途出错 → 但照样打印
# "共 0 项检查" + ##RESULT: PASS。所以这里先探测，探测失败就**明确跳过**（跳过会计数、看得见）。
function Test-EngineUsable([string]$exe) {
    try {
        $out = @(& $exe -NoProfile -Command 'Write-Output wmh-dual-ok' 2>&1)
        return (($out -join ' ') -match 'wmh-dual-ok')
    } catch { return $false }
}

# 求"只出现在 First 里、不在 Second 里"的行（HashSet 一次遍历，O(n)，两台引擎走同一份 .NET 实现）。
# 刻意不用 Compare-Object：同规模下它在两台引擎里 0.4 秒的实测，是"两边数组引用相同"的快路径；
# 而这里要比的是两台引擎各自解析出来的字符串，大输入下的行为不想再赌一次。
function Get-RowsOnlyInFirst([string[]]$First, [string[]]$Second) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($x in $First) { [void]$set.Add($x) }
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($x in $Second) { if (-not $set.Contains($x)) { $out.Add($x) } }
    return $out.ToArray()
}

# 跑一次体检，返回该引擎的发现行（子进程输出**留档**，不再 `| Out-Null` 丢掉）。
# 留档的理由：CI 上出现过"5.1 宿主这一趟比 pwsh 宿主慢 5.5 倍"，而 Out-Null 让子进程自己的分段计时
# 消失，只能靠猜（那次 21 分钟的真凶就是这么找出来的）；失败时也能直接看子进程输出。
# 抽成函数还有一个用处：比对发现差异时可以**只重跑有差异的那一侧**（见下面的安全阀）。
# ⚠ 必须定义在**顶层**：lint 规则 7 会拦"嵌在分支里的函数定义"（实测过：那种写法会静默失效）。
function Invoke-EngineHealthCheck([string]$Eng, [string]$TmpDir) {
    $tag = $Eng + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $outDir = Join-Path $TmpDir ('reports-' + $tag)
    $conLog = Join-Path $TmpDir ('console-' + $tag + '.txt')
    $swChild = [Diagnostics.Stopwatch]::StartNew()
    # 只读体检；退出码可能是 1（有严重项），与本测试无关，故不检查
    & $Eng -NoProfile -ExecutionPolicy Bypass -File (Join-Path $TmpDir 'scripts\health-check.ps1') `
        -OutDir $outDir -SkipAssocScan -SkipClsidScan -NoHistory *> $conLog
    $swChild.Stop()
    $runDir = @(Get-ChildItem -LiteralPath $outDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d{8}-\d{4}$' } | Sort-Object Name -Descending)[0]
    if (-not $runDir) { throw ("{0} 没有产出报告目录（自检通过了却跑不起来，属于真失败）" -f $Eng) }
    $csv = Join-Path $runDir.FullName 'findings.csv'
    if (-not (Test-Path -LiteralPath $csv)) { throw ("{0} 没有 findings.csv" -f $Eng) }
    return [pscustomobject]@{
        Rows    = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Seconds = [math]::Round($swChild.Elapsed.TotalSeconds, 1)
        Kb      = $(if (Test-Path -LiteralPath $conLog) { [math]::Round((Get-Item -LiteralPath $conLog).Length / 1KB, 1) } else { 0 })
        CsvKb   = [math]::Round((Get-Item -LiteralPath $csv).Length / 1KB, 1)
        Log     = $conLog
    }
}

# 行签名（排序后的字符串数组）。⚠ 写法别退回慢写法：13.1 万行实测 `'{0}|…' -f …` + `$o += …`
# 在 pwsh 42.7 秒、**5.1 676 秒**（那曾经是 CI 里 21 分钟的全部来源）；单次遍历 + `List.Add` +
# 字符串 `+` 是 4.0 / **0.5 秒**。现在行数少，但这套写法保留，并留注释防止将来被"优化"回去。
function Get-RowSignatures([object[]]$RowSet) {
    $sig = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in $RowSet) {
        $sig.Add($row.Severity + '|' + $row.Category + '|' + [string]$row.Location + '|' + $row.Target + '|' + $row.Status + '|' + $row.Hint)
    }
    $arr = $sig.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return , $arr
}

if (-not $env:SLOW_TESTS) {
    Skip-Test '双引擎：同一份脚本在 5.1 与 7.x 下的 findings.csv 必须零差异' `
        '要真跑两次完整体检（本机实测约 5 分钟）；设 $env:SLOW_TESTS=1 启用（CI 上默认启用）'
} else {
    $unusable = @(@('pwsh', 'powershell') | Where-Object { -not (Test-EngineUsable $_) })
    if ($unusable.Count -gt 0) {
        # 探测失败 → **明确跳过**（跳过会计数、看得见），绝不让它崩成"0 项检查却 PASS"
        Skip-Test '双引擎：同一份脚本在 5.1 与 7.x 下的 findings.csv 必须零差异' `
            ("本机启动不了 {0}（MSIX 商店版 pwsh 被 5.1 启动是应用激活，不是子进程）—— 跨引擎比较无法进行" -f ($unusable -join '、'))
    } else {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wmh-dual-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        # 受控输入：在清单扫描的根之一（HKCU\Software\Classes）下造一个带唯一 GUID 的 ProgID。
        # 安全底线：路径必须匹配 `_wmh_selftest`，否则立刻抛错中止（防止将来有人改了常量后误动真实键）。
        $fixtureGuid = [guid]::NewGuid().ToString('N')
        $fixtureKey  = 'HKCU:\Software\Classes\' + $script:FixturePrefix + $fixtureGuid.Substring(0, 8)
        if ($fixtureKey -notmatch '^HKCU:\\Software\\Classes\\_wmh_selftest') {
            throw ("拒绝在试验田之外操作：{0}" -f $fixtureKey)
        }
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'scripts') -Force
            Copy-Item -LiteralPath $target -Destination (Join-Path $tmp 'scripts\health-check.ps1')
            # 清单 = 那个唯一 GUID：机器上不可能有第二处出现它
            @('# 受控清单（本套件专用：只在 HKCU\Software\Classes\<_wmh_selftest_…> 里出现）', $fixtureGuid) |
                Set-Content -LiteralPath (Join-Path $tmp 'scripts\health-check.needles.txt') -Encoding UTF8
            New-Item -Path $fixtureKey -Force | Out-Null
            Set-ItemProperty -Path $fixtureKey -Name '(default)' -Value $fixtureGuid
            New-Item -Path (Join-Path $fixtureKey 'shell\open\command') -Force | Out-Null
            Set-ItemProperty -Path (Join-Path $fixtureKey 'shell\open\command') -Name '(default)' `
                -Value ('"C:\__wmh_missing__\{0}\app.exe" "%1"' -f $fixtureGuid)
            Write-Output ("    受控 fixture：{0}（键与值里都含这个 GUID；结束时删除）" -f $fixtureKey)

            $rows = @{}
            $childInfo = [ordered]@{}

            foreach ($eng in 'pwsh', 'powershell') {
                $res = Invoke-EngineHealthCheck -Eng $eng -TmpDir $tmp
                $rows[$eng] = $res.Rows
                $childInfo[$eng] = $res
            }
            # 子进程各自的耗时与输出体积：CI 上判断"慢在哪"就靠这一行（本机实测两边都在 1~2 分钟量级）
            Write-Output ("    子进程耗时：pwsh {0} 秒（控制台 {1} KB / findings.csv {2} KB）/ 5.1 {3} 秒（{4} KB / {5} KB）；宿主是 {6}" -f `
                $childInfo['pwsh'].Seconds, $childInfo['pwsh'].Kb, $childInfo['pwsh'].CsvKb,
                $childInfo['powershell'].Seconds, $childInfo['powershell'].Kb, $childInfo['powershell'].CsvKb,
                $(if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh' } else { '5.1' }))

            Test-Case '双引擎：两次体检都真的产出了发现项（0 行对 0 行不算零差异）' {
                foreach ($eng in 'pwsh', 'powershell') {
                    Assert-True ($rows[$eng].Count -gt 0) ("{0} 的 findings.csv 是空的 —— 那样'零差异'毫无意义" -f $eng)
                }
            }

            Test-Case '双引擎：清单扫描只命中受控 fixture（命中别的键说明清单没被隔离）' {
                # 这一条替代了原先的"排除易变位置"：受控输入下，清单扫描的结果**必须是确定的** ——
                # 只命中我们造的键。注意判据只看 `旧路径残留` 这一类别：报告里还有卸载记录/服务/计划任务
                # 等**本机状态**类别（受控清单管不到它们，它们也不参与本断言）。
                $marker = $script:FixturePrefix + $fixtureGuid.Substring(0, 8)
                foreach ($eng in 'pwsh', 'powershell') {
                    $needleRows = @($rows[$eng] | Where-Object { $_.Category -eq '旧路径残留' })
                    Assert-True ($needleRows.Count -gt 0) ("{0} 的清单扫描一条都没命中受控 fixture —— 说明清单没生效" -f $eng)
                    $stray = @($needleRows | Where-Object {
                        ([string]$_.Location).IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -lt 0
                    })
                    Assert-True ($stray.Count -eq 0) ("{0} 的清单扫描命中了 {1} 个受控 fixture 之外的键（清单没被隔离）：例如 {2}" -f `
                        $eng, $stray.Count, (@($stray | Select-Object -First 3 | ForEach-Object { $_.Location }) -join ' ;; '))
                }
            }

            Test-Case '双引擎：findings.csv 逐行零差异（发现差异时重跑一次再判）' {
                $norm = @{}
                foreach ($eng in 'pwsh', 'powershell') { $norm[$eng] = Get-RowSignatures -RowSet $rows[$eng] }
                Write-Output ("    参与对比：pwsh {0} 行 / powershell {1} 行（全类别）" -f $norm['pwsh'].Count, $norm['powershell'].Count)
                # 防线：两边都必须非空（0 行对 0 行也会"零差异"，那是假绿）
                foreach ($eng in 'pwsh', 'powershell') {
                    Assert-True ($norm[$eng].Count -gt 0) ("{0} 一行都没有 —— '零差异'毫无意义" -f $eng)
                }
                # 差异用 HashSet 一次遍历求（O(n)，两台引擎同一份实现）。
                # 刻意不用 Compare-Object：同规模下它在两台引擎里 0.4 秒是"两边引用相同"的快路径，
                # 而这里要比的是两台引擎各自解析出来的字符串 —— 不想再赌一次大输入下的行为。
                $onlyPwsh = @(Get-RowsOnlyInFirst -First $norm['powershell'] -Second $norm['pwsh'])
                $only51 = @(Get-RowsOnlyInFirst -First $norm['pwsh'] -Second $norm['powershell'])
                if (($onlyPwsh.Count + $only51.Count) -gt 0) {
                    # 安全阀：两个引擎是**先后**跑的，差异也可能来自"两次快照之间系统被改动"（本仓库踩过
                    # 两次：MrtCache 多一条、SecHealthUI 的包版本号变了）。**只重跑有差异的那一侧**再比：
                    # 真正的引擎差异是确定性的（重跑仍在），系统改动是偶发的（重跑就没了）。
                    $retry = @()
                    if ($onlyPwsh.Count -gt 0) { $retry += 'pwsh' }
                    if ($only51.Count -gt 0) { $retry += 'powershell' }
                    Write-Output ("    ⚠ 首次比对发现 {0} 处差异（仅 pwsh {1} / 仅 5.1 {2}）—— 重跑 {3} 一次再判" -f `
                        ($onlyPwsh.Count + $only51.Count), $onlyPwsh.Count, $only51.Count, ($retry -join '、'))
                    foreach ($eng in $retry) {
                        $res = Invoke-EngineHealthCheck -Eng $eng -TmpDir $tmp
                        $rows[$eng] = $res.Rows
                        $norm[$eng] = Get-RowSignatures -RowSet $rows[$eng]
                    }
                    $onlyPwsh = @(Get-RowsOnlyInFirst -First $norm['powershell'] -Second $norm['pwsh'])
                    $only51 = @(Get-RowsOnlyInFirst -First $norm['pwsh'] -Second $norm['powershell'])
                    if (($onlyPwsh.Count + $only51.Count) -eq 0) {
                        Write-Output '    重跑后差异消失 → 判定为"两次快照之间系统被改动"，**不是**引擎不一致（重跑耗时已计入本次运行）'
                    }
                }
                if (($onlyPwsh.Count + $only51.Count) -gt 0) {
                    $sample = @()
                    $sample += @($onlyPwsh | Select-Object -First 3 | ForEach-Object { "[仅 pwsh] $_" })
                    $sample += @($only51 | Select-Object -First 3 | ForEach-Object { "[仅 5.1] $_" })
                    Assert-True ($false) ("两个引擎的结论不一致（重跑后仍在）：{0} 处差异，例如 {1}" -f `
                        ($onlyPwsh.Count + $only51.Count), ($sample -join ' ;; '))
                }
            }
        } finally {
            # 试验田必须删干净：先在 finally 里删，再**明确检查**（删不掉要看得见，不许静默留着）。
            Remove-Item -Path $fixtureKey -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -Path $fixtureKey) { Write-Output ("    ⚠ 试验田没删干净，请手工删除：{0}" -f $fixtureKey) }
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Complete-TestRun 'health-check.dualengine'
