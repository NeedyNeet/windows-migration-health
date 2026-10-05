# ============================================================================
#  tests/health-check.dualengine.tests.ps1 —— 双引擎"结论一致"的执行者
#
#  仓库到处宣称的验收标准是："同一份脚本必须在 5.1 与 7.x 下都通过，且**结论一致**
#  （Compare-Object findings.csv = 0 差异）"。前半句有执行者（CI 矩阵把每个套件在两台引擎下
#  各跑一遍），后半句一直是**手工**做的 —— 也就是说："5.1 与 7.x 报出不同结论"这类回归，
#  没有任何东西会拦住它。本套件把后半句机器化。
#
#  做法：把真脚本复制到临时目录、喂一份**固定**的清单（C:\Program Files，任何 Windows 上都在
#  注册表里留痕），然后分别用两个引擎各跑一次体检（关掉最慢的两项扫描以压时间），最后逐行
#  对比 findings.csv。以下是刻意设计的几处：
#    * 固定清单 + 全新 OutDir + -NoHistory：两次运行的输入完全相同（不引入"上次快照"这个变量）；
#    * 先断言两次都**真的产出了行**：0 行对 0 行也会"零差异"，那是假绿；
#    * 显式排除"每次跑都会变"的类别（容量/目录体积），并把排除条数打印出来（排除也要可见）；
#    * 失败时打印前几处差异与所在引擎，否则调试只能靠猜。
#  成本：本机实测约 3.7 分钟、两份 findings.csv 各 23,380 行（C:\Program Files 这条清单命中很多，
#  正是它让"逐行比对"有意义）。默认跳过，CI 上启用（SLOW_TESTS=1）。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\health-check.ps1'

# 每次跑都会变、与引擎无关的类别：不参与对比，但**必须把排除条数报出来**（静默排除也是假绿）
$volatileCategories = @('容量', '目录体积')

# 易变**位置**：Windows 自己在跑动时会写的缓存/历史键。两个引擎是**先后**跑的（相隔数分钟），
# 期间系统只要新增一条这样的记录，"逐行零差异"就会变成**假红**。
# 实测事故（CI，main 上 2026-10-05，run 37329666998）：`C:\Program Files` 这条清单命中了
#   HKCU\Software\Classes\Local Settings\MrtCache\C:%5CProgram Files%5CWindowsApps\…\resources.pri\…
# 而它是在 pwsh 那次跑完之后、5.1 那次跑之前被系统写进去的 —— 两次相差 1 行（131,397 vs 131,398）。
# 注意：过滤**只针对这类"系统自己会写"的缓存**；真正的旧路径残留（含 Start\TileProperties 这种）
# 一律照常参与对比，绝不为了"让它绿"而放宽判据。
$volatileLocationPatterns = @(
    '\\Local Settings\\MrtCache\\',        # 资源缓存：随 shell/应用活动随时增删
    '\\MrtCache\\',
    '\\MuiCache',                          # 程序显示名缓存
    '\\Shell\\BagMRU', '\\Shell\\Bags',    # 文件夹视图记忆
    '\\ShellNoRoam\\',
    '\\Explorer\\ComDlg32\\',              # 最近打开的对话框路径
    '\\AppCompatFlags\\',                  # 兼容性标记（系统会自己写）
    '\\Explorer\\UserAssist',              # 程序启动历史
    '\\CurrentVersion\\Search\\'           # 搜索历史
)

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

if (-not $env:SLOW_TESTS) {
    Skip-Test '双引擎：同一份脚本在 5.1 与 7.x 下的 findings.csv 必须零差异' `
        '要真跑两次完整体检（本机实测约 3.7 分钟）；设 $env:SLOW_TESTS=1 启用（CI 上默认启用）'
} else {
    $unusable = @(@('pwsh', 'powershell') | Where-Object { -not (Test-EngineUsable $_) })
    if ($unusable.Count -gt 0) {
        # 探测失败 → **明确跳过**（跳过会计数、看得见），绝不让它崩成"0 项检查却 PASS"
        Skip-Test '双引擎：同一份脚本在 5.1 与 7.x 下的 findings.csv 必须零差异' `
            ("本机启动不了 {0}（MSIX 商店版 pwsh 被 5.1 启动是应用激活，不是子进程）—— 跨引擎比较无法进行" -f ($unusable -join '、'))
    } else {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wmh-dual-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'scripts') -Force
            Copy-Item -LiteralPath $target -Destination (Join-Path $tmp 'scripts\health-check.ps1')
            # 固定清单：一条任何 Windows 上都存在的旧路径痕迹（ProgID / App Paths / TypeLib 里都有）
            @('# 固定清单（本套件专用，不依赖本机历史）', 'C:\Program Files') |
                Set-Content -LiteralPath (Join-Path $tmp 'scripts\health-check.needles.txt') -Encoding UTF8

            $rows = @{}
            $childInfo = [ordered]@{}
            foreach ($eng in 'pwsh', 'powershell') {
                $outDir = Join-Path $tmp ('reports-' + $eng)
                # 子进程的输出**留档**，不再 `| Out-Null` 丢掉。两个理由：
                #  1) 它是定位慢/怪问题的唯一线索 —— CI 上出现过"5.1 宿主这一趟比 pwsh 宿主慢 5.5 倍"
                #     （21.7 分钟 vs 3.9 分钟，同为这一个套件），而 Out-Null 让子进程自己的分段计时消失，
                #     只能靠猜；留档后下一次 CI 就能看出慢在哪个子进程、慢在哪一段。
                #  2) 失败时可以把子进程输出的尾部直接打出来，不必再复现一遍。
                $conLog = Join-Path $tmp ("console-$eng.txt")
                $swChild = [Diagnostics.Stopwatch]::StartNew()
                # 只读体检；退出码可能是 1（有严重项），与本测试无关，故不检查
                & $eng -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\health-check.ps1') `
                    -OutDir $outDir -SkipAssocScan -SkipClsidScan -NoHistory *> $conLog
                $swChild.Stop()
                $sizeKb = 0
                if (Test-Path -LiteralPath $conLog) { $sizeKb = [math]::Round((Get-Item -LiteralPath $conLog).Length / 1KB, 1) }
                $childInfo[$eng] = [pscustomobject]@{
                    Seconds = [math]::Round($swChild.Elapsed.TotalSeconds, 1)
                    Kb      = $sizeKb
                    Log     = $conLog
                }
                $runDir = @(Get-ChildItem -LiteralPath $outDir -Directory -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match '^\d{8}-\d{4}$' } | Sort-Object Name -Descending)[0]
                if (-not $runDir) { throw ("{0} 没有产出报告目录（自检通过了却跑不起来，属于真失败）" -f $eng) }
                $csv = Join-Path $runDir.FullName 'findings.csv'
                if (-not (Test-Path -LiteralPath $csv)) { throw ("{0} 没有 findings.csv" -f $eng) }
                $childInfo[$eng] | Add-Member -NotePropertyName CsvKb -NotePropertyValue ([math]::Round((Get-Item -LiteralPath $csv).Length / 1KB, 1))
                $rows[$eng] = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
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

            Test-Case '双引擎：findings.csv 逐行零差异（除容量/体积这类每次都会变的类别）' {
                $norm = @{}
                $skippedCat = @{}
                $skippedLoc = @{}
                foreach ($eng in 'pwsh', 'powershell') {
                    $nCat = 0
                    $nLoc = 0
                    # ⚠ 这一段是**整套测试里最贵的地方**，写法必须讲究（CI 上实测过教训：
                    #   同一段逻辑在 5.1 宿主下要十几分钟，是"powershell job 21 分钟"的全部来源）。
                    #   踩过的两种写法：
                    #     · `$kept += $row` —— 数组追加是二次方复制；
                    #     · `'{0}|{1}|…' -f …` —— 每行都要做一次格式解析。
                    #   本机实测（13.1 万行）：`-f` + `+=` 要 **42.7 秒**，换成
                    #   `List[string].Add` + 字符串连接只要 **4.0 秒**，`.ForEach()` 更到 **1.0 秒**。
                    #   这里用单次遍历 + List.Add：既过滤又拼签名，不产生中间对象数组。
                    $sig = New-Object 'System.Collections.Generic.List[string]'
                    foreach ($row in $rows[$eng]) {
                        if ($volatileCategories -contains $row.Category) { $nCat++; continue }
                        $loc = [string]$row.Location
                        $isVol = $false
                        foreach ($p in $volatileLocationPatterns) { if ($loc -match $p) { $isVol = $true; break } }
                        if ($isVol) { $nLoc++; continue }
                        $sig.Add($row.Severity + '|' + $row.Category + '|' + $loc + '|' + $row.Target + '|' + $row.Status + '|' + $row.Hint)
                    }
                    $skippedCat[$eng] = $nCat
                    $skippedLoc[$eng] = $nLoc
                    # 排序用 [Array]::Sort + Ordinal 比较器（两台引擎都走同一份 .NET 实现，行为一致）
                    $arr = $sig.ToArray()
                    [Array]::Sort($arr, [StringComparer]::Ordinal)
                    $norm[$eng] = $arr
                }
                Write-Output ("    参与对比：pwsh {0} 行 / powershell {1} 行（原始 {2} / {3}）" -f `
                    $norm['pwsh'].Count, $norm['powershell'].Count, $rows['pwsh'].Count, $rows['powershell'].Count)
                Write-Output ("    因易变而排除：类别（{0}）{1} / {2} 行；位置（{3} 类）{4} / {5} 行" -f `
                    ($volatileCategories -join '、'), $skippedCat['pwsh'], $skippedCat['powershell'],
                    @($volatileLocationPatterns).Count, $skippedLoc['pwsh'], $skippedLoc['powershell'])
                # 防线：过滤**不许把报告吃掉**。否则"零差异"会因为两边都空而变成假绿 ——
                # 这正是本仓库反复吃过的那一类亏（"检查了 0 项却打勾"）。
                foreach ($eng in 'pwsh', 'powershell') {
                    Assert-True ($norm[$eng].Count -gt 0) ("{0} 过滤后一行都不剩 —— '零差异'毫无意义" -f $eng)
                    Assert-True ($norm[$eng].Count -ge ($rows[$eng].Count / 2)) `
                        ("{0} 的易变过滤吃掉了 {1}/{2} 行（超过一半）—— 过滤范围疑似过宽，会导致假绿" -f `
                            $eng, ($rows[$eng].Count - $norm[$eng].Count), $rows[$eng].Count)
                }
                # 差异用 HashSet 一次遍历求（O(n)，两台引擎同一份实现）。
                # 刻意不用 Compare-Object：同规模下它在该引擎里 0.4 秒是"两边引用相同"的快路径，
                # 而这里要比的是两台引擎各自解析出来的字符串 —— 不想再赌一次大输入下的行为。
                $onlyPwsh = @(Get-RowsOnlyInFirst -First $norm['powershell'] -Second $norm['pwsh'])
                $only51 = @(Get-RowsOnlyInFirst -First $norm['pwsh'] -Second $norm['powershell'])
                $diffCount = $onlyPwsh.Count + $only51.Count
                if ($diffCount -gt 0) {
                    $sample = @()
                    $sample += @($onlyPwsh | Select-Object -First 3 | ForEach-Object { "[仅 pwsh] $_" })
                    $sample += @($only51 | Select-Object -First 3 | ForEach-Object { "[仅 5.1] $_" })
                    Assert-True ($false) ("两个引擎的结论不一致：{0} 处差异，例如 {1}" -f $diffCount, ($sample -join ' ;; '))
                }
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Complete-TestRun 'health-check.dualengine'
