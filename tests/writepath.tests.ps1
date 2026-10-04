# ============================================================================
#  tests/writepath.tests.ps1 —— 真正**执行**两个写入脚本的写路径
#
#  为什么需要这个文件：在本文件之前，测试覆盖的是**决策逻辑**（门禁函数、映射函数、以及
#  "目标存在就不删"这类判断）与脚本的静态形状。而 `Backup-Key` 的 reg export、`Set-Text`
#  的实际写入、`Del-*` 的实际删除、以及 repair 的"写入 + 回读校验"闭环 —— **从未被执行过**。
#  而那正是唯一会改动注册表的部分。"看起来有覆盖、实际没跑过"是最危险的一种覆盖。
#
#  做法：在 `HKCU:\Software\_wmh_selftest_<随机>` 这块**一次性试验田**里，用 AST 抽出真函数、
#  真的调用它们，然后断言注册表里真的发生了变化、备份文件真的产生了、失败路径真的被挡住。
#
#  四条安全底线：
#    1. **不需要管理员**（全在 HKCU）；
#    2. 所有路径必须匹配 `_wmh_selftest` 前缀，否则抛错中止（防止将来有人改了常量后误动真实键）；
#    3. 开跑前先扫掉任何残留的旧试验田，结束时删掉并断言真的没了；
#    4. **不**执行 `repair-migrated-apps.ps1 -Apply` 的完整主流程 —— 它的目标是真实注册表里
#       扫出来的键，跑一遍就会真改本机。所以只测被提取出来的写函数。
#
#  ⚠ 这是唯一一个会动注册表的测试套件（仅在试验田内）。它改的不是仓库，所以不违反
#     "测试必须只读仓库"那条（CI 里那条断言查的是 git status）。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo = Get-RepoRoot

$guardPattern = '^HKCU:\\Software\\_wmh_selftest'
function Assert-Sandbox([string]$psPath) {
    if ($psPath -notmatch $guardPattern) { throw ("拒绝在试验田之外操作：{0}" -f $psPath) }
}

$sandbox   = 'HKCU:\Software\_wmh_selftest_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$backupDir = Join-Path ([IO.Path]::GetTempPath()) ('wmh-writepath-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $backupDir -Force
New-Item -Path $sandbox -Force | Out-Null
Assert-Sandbox $sandbox

# 开跑前扫掉历史残留（上一次被强杀时可能留下）
foreach ($stale in @(Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue |
                     Where-Object { $_.PSChildName -like '_wmh_selftest_*' -and $_.PSChildName -ne (Split-Path $sandbox -Leaf) })) {
    Remove-Item -LiteralPath $stale.PSPath -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
#  health-fix.ps1 的写路径
# ---------------------------------------------------------------------------
$fixSrc = Join-Path $repo 'scripts\health-fix.ps1'
foreach ($fn in 'Say', 'Open-RegKey', 'Get-RegValue', 'Backup-Key', 'Fix-Acl', 'Del-Key', 'Del-Value', 'Set-Text') {
    Invoke-Expression (Get-ScriptFunctionText -Path $fixSrc -Name $fn)
}

# 这些是脚本顶部的运行期状态。测试自己提供它们 —— AST 抽取不会带上依赖（见 Extract-Function.ps1）。
$Apply    = $false
$rollback = Join-Path $backupDir 'rollback'
$log      = Join-Path $backupDir 'fix-log.txt'
# 照抄被测脚本的写法：5.1 的 Add-Content -Encoding 只接受枚举/字符串，
# 传 Text.UTF8Encoding 对象在 5.1 下会直接抛参数绑定错误（我第一次就猜错了）。
$script:Enc         = if ($PSVersionTable.PSVersion.Major -ge 7) { 'utf8BOM' } else { 'UTF8' }
$script:RunStamp    = 'r1'
$script:backupTried = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:backupOk    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:stat        = [ordered]@{ '改路径' = 0; '删键' = 0; '删值' = 0; '跳过' = 0; '引用清理' = 0 }
$me = New-Object System.Security.Principal.NTAccount($env:USERNAME)

function Reset-BackupState([string]$dir) {
    $script:rollback = $dir
    $script:RunStamp = 'r' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $script:backupTried.Clear(); $script:backupOk.Clear()
}

Test-Case '安全底线：守卫真的会拒绝试验田之外的路径' {
    $threw = $false
    try { Assert-Sandbox 'HKCU:\Software\SomeRealProduct' } catch { $threw = $true }
    Assert-True $threw '守卫没有拦住真实注册表路径'
    Assert-Sandbox "$sandbox\anything"   # 试验田内的必须放行
}

Test-Case 'health-fix：试运行下 Backup-Key 恒返回 $true，且不产出任何备份文件' {
    $k = "$sandbox\dry"; New-Item -Path $k -Force | Out-Null
    Reset-BackupState (Join-Path $backupDir 'dry')
    $Apply = $false
    Assert-True (Backup-Key $k) '试运行下应返回 $true（调用方据此继续）'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:rollback $script:RunStamp))) '试运行不该创建备份目录'
}

Test-Case 'health-fix：-Apply 下 Backup-Key 真的导出 .reg（且内容够长）' {
    $k = "$sandbox\bk"; New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -LiteralPath $k -Name 'V' -Value 'backup-me'
    Reset-BackupState (Join-Path $backupDir 'bk')
    $Apply = $true
    Assert-True (Backup-Key $k) '备份应当成功'
    $dir = Join-Path $script:rollback $script:RunStamp
    Assert-True (Test-Path -LiteralPath $dir) '应当创建备份目录'
    $regs = @(Get-ChildItem -LiteralPath $dir -File)
    Assert-True ($regs.Count -eq 1) ("应当恰好产出 1 个备份文件，实际 {0}" -f $regs.Count)
    Assert-True ($regs[0].Length -ge 64) ("备份文件太小（{0} 字节），可能不是有效导出" -f $regs[0].Length)
}

Test-Case 'health-fix：备份失败时 Backup-Key 返回**单个** $false（返回值不能被日志污染）' {
    $k = "$sandbox\bkfail"; New-Item -Path $k -Force | Out-Null
    # 把备份目录指向一个"父级是文件"的路径 —— 目录创建必然失败，于是 reg export 也必然失败
    $blocker = Join-Path $backupDir 'blocker'
    Set-Content -LiteralPath $blocker -Value 'x'
    Reset-BackupState (Join-Path $blocker 'sub')
    $Apply = $true
    $r = Backup-Key $k
    # 关键：断言返回值的**形状**，而不只是真假。曾经 Say 的日志文本混进返回值，使返回值成为
    # @('<日志>', $false)；调用方 `if (-not (Backup-Key ...))` 对非空数组求值为真，
    # 于是"备份失败"被判成"备份成功" —— 改动照做且没有备份。只断言 `-not $r` 是抓不到它的。
    $n = @($r).Count
    Assert-Equal $n 1 ("返回值应恰好 1 个元素，实际 {0}（{1}）" -f $n, ((@($r) | ForEach-Object { $_.GetType().Name }) -join ','))
    Assert-True ($r -is [bool]) ("返回值应是布尔，实际是 {0}" -f $r.GetType().Name)
    Assert-True (-not $r) '备份不可能成功时，必须返回 $false'
}

Test-Case 'health-fix：备份成功时 Backup-Key 也只返回一个 $true' {
    $k = "$sandbox\bkok"; New-Item -Path $k -Force | Out-Null
    Reset-BackupState (Join-Path $backupDir 'bkok')
    $Apply = $true
    $r = Backup-Key $k
    Assert-Equal @($r).Count 1 ("成功路径也应只返回 1 个元素，实际 {0}" -f @($r).Count)
    Assert-True ($r -eq $true) '成功路径应返回 $true'
}

Test-Case 'health-fix：备份失败时 Del-Value 跳过删除，并计入"跳过"' {
    $k = "$sandbox\dvskip"; New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -LiteralPath $k -Name 'V' -Value 'must-survive'
    $blocker = Join-Path $backupDir 'blocker'
    Reset-BackupState (Join-Path $blocker 'sub')
    $Apply = $true
    $before = $script:stat['跳过']
    Del-Value $k 'V' 'test'
    Assert-Equal (Get-RegValue $k 'V') 'must-survive' '备份失败时绝不能删掉值'
    Assert-Equal $script:stat['跳过'] ($before + 1) '应当计入"跳过"'
}

Test-Case 'health-fix：-Apply 下 Set-Text 真的改写，且回读得到新值' {
    $k = "$sandbox\st"; New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -LiteralPath $k -Name 'P' -Value 'C:\old\x.exe'
    Reset-BackupState (Join-Path $backupDir 'st')
    $Apply = $true
    Set-Text $k 'P' 'C:\old' 'C:\new' 'test'
    Assert-Equal (Get-RegValue $k 'P') 'C:\new\x.exe' '写入后回读应当是新值'
}

Test-Case 'health-fix：试运行下 Set-Text 一个字都不改（这是最重要的安全属性）' {
    $k = "$sandbox\stdry"; New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -LiteralPath $k -Name 'P' -Value 'C:\old\x.exe'
    Reset-BackupState (Join-Path $backupDir 'stdry')
    $Apply = $false
    Set-Text $k 'P' 'C:\old' 'C:\SHOULD-NOT-APPEAR' 'dry'
    Assert-Equal (Get-RegValue $k 'P') 'C:\old\x.exe' '试运行改动了注册表 —— 这是不可接受的'
}

Test-Case 'health-fix：-Apply 下 Del-Key 真的把键删掉' {
    $k = "$sandbox\dk"; New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -LiteralPath $k -Name 'V' -Value 'x'
    Reset-BackupState (Join-Path $backupDir 'dk')
    $Apply = $true
    Del-Key $k 'test'
    Assert-True (-not (Test-Path -LiteralPath $k)) '应当已删除该键'
}

# ---------------------------------------------------------------------------
#  repair-migrated-apps.ps1 的写路径
#  注意顺序：这里会**覆盖**同名函数 Backup-Key（两个脚本各有一个，语义还不同：
#  health-fix 的返回 $true/$false，repair 的不返回任何东西也不会校验备份成功与否）。
#  所以 health-fix 的用例必须全部跑在上面。
# ---------------------------------------------------------------------------
$repSrc = Join-Path $repo 'scripts\repair-migrated-apps.ps1'
foreach ($fn in 'Backup-Key', 'Set-ValueChecked') {
    Invoke-Expression (Get-ScriptFunctionText -Path $repSrc -Name $fn)
}

Test-Case 'repair：-Apply 下 Backup-Key 真的产出 .reg' {
    $k = "$sandbox\repbk"; New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -LiteralPath $k -Name 'V' -Value 'x'
    $script:backedUp = @()
    $Apply = $true
    $BackupDir = Join-Path $backupDir 'repbk'
    Backup-Key -Key $k
    $regs = @(Get-ChildItem -LiteralPath $BackupDir -File -ErrorAction SilentlyContinue)
    Assert-True ($regs.Count -eq 1) ("应当产出 1 个备份文件，实际 {0}" -f $regs.Count)
    Assert-True ($regs[0].Length -gt 0) '备份文件不该是空的'
}

Test-Case 'repair：Set-ValueChecked 正常路径返回 ok，且值真的写进去了' {
    $k = "$sandbox\svc"; New-Item -Path $k -Force | Out-Null
    $state = Set-ValueChecked -Key $k -Name 'V' -New 'NEW'
    Assert-Equal $state 'ok' '写入应当成功'
    Assert-Equal (Get-RegValue $k 'V') 'NEW' '回读应当拿到新值'
}

Test-Case 'repair：Set-ValueChecked 写不进去时必须返回 FAILED（回读校验的意义所在）' {
    # 目标键不存在：Set-ItemProperty 会失败，回读也拿不到 → 必须报 FAILED 而不是沉默
    $missing = "$sandbox\no-such-key\deeper"
    $state = Set-ValueChecked -Key $missing -Name 'V' -New 'X'
    Assert-Equal $state 'FAILED' '写不进去却报 ok，等于假绿'
}

Test-Case 'repair：Set-ValueChecked 也支持空值名（该键的 (Default) 值）' {
    $k = "$sandbox\svc-default"; New-Item -Path $k -Force | Out-Null
    $state = Set-ValueChecked -Key $k -Name '' -New 'DEFAULTVAL'
    Assert-Equal $state 'ok' '空名写入应当成功'
    Assert-Equal (Get-RegValue $k '') 'DEFAULTVAL' '回读 (Default) 应当是新值'
}

# ---------------------------------------------------------------------------
#  收尾：试验田必须真的清干净
# ---------------------------------------------------------------------------
Test-Case '收尾：试验田与临时目录都被清掉，且没有留下任何 _wmh_selftest_* 残留' {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    Assert-True (-not (Test-Path -LiteralPath $sandbox)) '试验田没有清干净'
    $left = @(Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '_wmh_selftest_*' })
    Assert-True ($left.Count -eq 0) ("残留了 {0} 个试验田键：{1}" -f $left.Count, (($left | ForEach-Object { $_.PSChildName }) -join ', '))
}

Complete-TestRun 'writepath'
