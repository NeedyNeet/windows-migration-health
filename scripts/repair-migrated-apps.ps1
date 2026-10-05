# repair-migrated-apps.ps1
# Repairs Windows registrations for applications whose files were moved somewhere else.
#
# Symptom it fixes: the app files now live at a NEW location, but Windows still points at the
# ORIGINAL install path, so it cannot find the app: search does not find it, double-clicking an
# associated file fails, and Settings > Apps shows a dead entry.
#
# 映射表（旧路径 -> 新路径）**不在本文件里**：它是机器专属值，放
#   local\repair-migrated-apps.local.psd1（模板 config\repair-migrated-apps.local.example.psd1）。
# 没配置映射时本脚本会明确报"未执行有效检查"并以退出码 3 结束 —— 那是"没查"，不是"没事"。
#
# Default is DRY RUN: nothing is written, every planned change is printed.
#   powershell -ExecutionPolicy Bypass -File .\repair-migrated-apps.ps1
# Apply:
#   powershell -ExecutionPolicy Bypass -File .\repair-migrated-apps.ps1 -Apply
# Applying rewrites machine-wide keys, so run it from an elevated prompt
# (or just double-click repair-migrated-apps.cmd).
#
# Every key that gets rewritten is first exported with reg.exe into -BackupDir,
# so the repair can be undone by importing those .reg files.

[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$BackupDir
)

$ErrorActionPreference = 'Continue'

# -Apply 要写 HKLM/HKCU：没有管理员权限就明确报错退出，而不是逐条写入失败刷屏。
# 与 health-fix.ps1 保持一致 —— 两个会写入的脚本都不许在非提权下"假装成功"。
if ($Apply) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Output 'ERROR: -Apply 需要管理员权限。请用 repair-migrated-apps.cmd -Apply，或从已提权的窗口运行。'; exit 2 }
}

# 仓库根：先把脚本目录与仓库根解析出来（-BackupDir 显式给出时也要能定位 local\ 配置）
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
if (-not (Test-Path (Join-Path $RepoRoot 'scripts'))) { $RepoRoot = $ScriptDir }

# 备份位置：默认写到"仓库根/local/rollback"（与 health-fix 一致，且该目录已被 .gitignore 排除）。
# 单独把这个脚本放到别处时，退化为脚本同目录下的 local\rollback。
if (-not $BackupDir) {
    $BackupDir = Join-Path $RepoRoot 'local\rollback'
}

# "读不到" ≠ "不存在"：权限受限的路径**绝不能**被判成缺失（AGENTS.md 硬性约定 10）。
# 本脚本原来用裸 Test-Path 判文件是否存在，是全仓唯一没跟上那条修复的地方。权限受限时
# Test-Path 会静默返回 False，于是把存在的目标当成缺失：
#   * 该改写的值被当成"改不了"而跳过（只是退化，不出错）
#   * 快捷方式那两处更糟：会把一个**本来好的**目标改写掉
# 定义位置刻意靠前：下面的配置文件探测也要用它。
function Test-Exists([string]$p) {
    if (-not $p) { return $false }
    if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $true }
    $cls = $null
    try { [void][System.IO.File]::GetAttributes($p) }
    catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; $cls = $e.GetType().Name }
    if (-not $cls) { return $true }
    if ($cls -in 'UnauthorizedAccessException','SecurityException') { return $true }
    return $false
}

# 机器专属映射：不写死在本文件里；真值放在 local\repair-migrated-apps.local.psd1
$script:CfgPath = Join-Path $RepoRoot 'local\repair-migrated-apps.local.psd1'
$script:Cfg = $null
if (Test-Exists $script:CfgPath) {
    # Import-PowerShellDataFile 只读数据、不执行代码，5.1 与 7.x 都可用。
    # 但**解析失败是非终止错误**：在 $ErrorActionPreference='Continue' 下它只往 stderr 丢一条，
    # 赋值落空成 $null —— 于是"配置写坏了"被当成"没有配置"，脚本继续跑完并报"本机已无需改指"。
    # 那正是本项目最危险的假绿（报告说没事，其实一条都没查），所以这里自己接住并致命退出。
    try {
        $script:Cfg = Import-PowerShellDataFile -LiteralPath $script:CfgPath -ErrorAction Stop
    } catch {
        Write-Output ("ERROR: 读不了本机配置 {0}" -f $script:CfgPath)
        Write-Output ("       {0}" -f $_.Exception.Message)
        Write-Output '       先修好语法（模板见 config\repair-migrated-apps.local.example.psd1）再重跑。'
        Write-Output '       **本次未执行有效检查** —— 不要把它读成"本机无需改指"。'
        exit 3
    }
} else {
    Write-Output ("note: {0} not found - 本机映射未配置（模板见 config\repair-migrated-apps.local.example.psd1）。" -f $script:CfgPath)
}

# ---------------------------------------------------------------- path mapping
# Old (registered) path prefix -> real current path.
#
# 这个内置表**刻意是空的**：一条具体路径都不放。硬性约定 8 点名了"repair 的迁移映射表"必须
# 放在 local\repair-migrated-apps.local.psd1，理由不是洁癖，是三条实测：
#   1. 这张表天生是本机的。写死在脚本里，换台机器要么空转（旧前缀不存在），要么更糟 ——
#      在别人机器上把指向旧位置的登记**改写成同样不存在的路径**：写入前的存在性校验只覆盖
#      exe/dll/ico/com/bat/cpl/msc/sys 这类文件值，纯目录值（InstallLocation、WorkingDirectory、
#      指向文件夹的 IconLocation）与 .png/.jar/.py/.url 这类扩展名**没有任何校验就写**；
#   2. 带版本号的条目会腐烂（曾经写死过 app-3.19.0、IntelliJ IDEA 2024.2.2）。映射是"全表按序
#      替换"，具体条目先命中 → 程序一升级就改到不存在的版本目录，而通用条目再也匹配不上；
#   3. README 早就写着"脚本本身不含任何机器专属信息、迁移映射表在仓库版里是占位符"——
#      留着这张表是代码欠文档的债。
# 为什么保留这个空数组而不是删掉变量：合并处的形状（见 Merge-PathMap）与"0 条 = 未配置"的
# 判定需要一个明确的位置，将来真有通用规则也往这里放（目前认为一条都没有）。
#
# 顺序敏感：更具体的旧前缀必须排在更短的前面（例如某程序的资源在带版本号的 app-<version>
# 子目录里，那条必须优先于它的通用前缀那条）。psd1 不允许 [ordered]，所以顺序靠
# 「数组 + Old/New」保住：本机条目排在前面，且**先到先得**。
$pathMapBase = @()

# 合并两张表：本机条目在前，先到先得（同一个 Old 以更具体的本机条目为准）。
# 单独成函数是为了让测试够得着（AST 抽取只能抽函数）——这段逻辑曾经靠调用方"恰好"写对而工作：
#     $localPathMap = if (...) { @($script:Cfg.PathMap) } else { @() }
# 本机配置里只有 1 条映射时，if 的输出被去掉数组包装、退回成 Hashtable，
# `$Hashtable + $Object[]` 抛 "A hash table can only be added to another hash table."；
# 而 $ErrorActionPreference='Continue' 让它成为**非终止**错误：脚本继续跑，$pathMap 空着，
# 最后打印 "(none: every registration already points at an existing path)" 并 exit 0 ——
# 一条都没查，报告却说没事。修法两层：拼接两侧各包一次 @()（对任何形状都安全），
# 并且返回值形状由 tests\repair.mapping.tests.ps1 锁死。
function Merge-PathMap {
    param($Local, $Base)
    $map = [ordered]@{}
    foreach ($e in (@($Local) + @($Base))) {
        if ($e -and $e.Old -and -not $map.Contains([string]$e.Old)) { $map[[string]$e.Old] = [string]$e.New }
    }
    return $map
}

# 先初始化再赋值（与下面 $verifyPaths 的写法一致）。刻意**不**写成 `= if (...) {...}`：
# 语句输出的数组在只有 1 个元素时会被拆包成单对象，见上面那段注释。
$localPathMap = @()
if ($script:Cfg -and $script:Cfg.PathMap) { $localPathMap = @($script:Cfg.PathMap) }
$pathMap = Merge-PathMap -Local $localPathMap -Base $pathMapBase

# 0 条映射 = **没有执行任何有效的路径检查**，绝不许退化成"本机已无需改指"（最典型的假绿）。
# 分开说清楚：本机没配（正常，但必须明说）／配置里有条目却合并不出来（脚本自身故障）。
if ($pathMap.Count -eq 0) {
    Write-Output '⚠ **未执行有效检查**：没有任何"旧路径 -> 新路径"映射可用。'
    if (@($localPathMap).Count -eq 0) {
        Write-Output ("   本机映射未配置或为空：{0}" -f $script:CfgPath)
        Write-Output '   模板见 config\repair-migrated-apps.local.example.psd1（一行一条：Old -> New）。'
        Write-Output '   本次不会改写任何登记 —— 请不要把这份输出读成"本机已无需改指"。'
    } else {
        Write-Output ("   本机配置里有 {0} 条映射，合并后却是 0 条：这是脚本自身的故障，请报告。" -f @($localPathMap).Count)
    }
    exit 3
}

# The Windows profile folder was renamed too (e.g. C:\Users\<old-name> -> C:\Users\<user>).
# Only applied inside HKCU\Software\Classes (URL handlers etc.), never to uninstall
# records: rewriting a dead install path to another dead profile path helps nobody.
# 这两个映射同样是机器专属，来自 local\repair-migrated-apps.local.psd1 的 ProfileMap。
# 同样是"先初始化再赋值"：做成 `= if (...)` 时，单条映射会退回成 Hashtable。
# 这里眼下侥幸能工作（PowerShell 不枚举 Hashtable，单条时 $e 就是那个 Hashtable，
# 而 $e.Old 走键查找恰好取到值），但不该靠这种巧合：改法一旦被复制到别处就复发。
$localProfileMap = @()
if ($script:Cfg -and $script:Cfg.ProfileMap) { $localProfileMap = @($script:Cfg.ProfileMap) }
$profileMap = [ordered]@{}
foreach ($e in @($localProfileMap)) {
    if ($e -and $e.Old) { $profileMap[[string]$e.Old] = [string]$e.New }
}

# 把 Old 替换成 New（忽略大小写）。必须转义 New 里的 `$`：正则替换串把 `$` 当特殊字符。
# 实测（见 tests\repair.mapping.tests.ps1）：
#   * `$&`（整个匹配）、`` $` ``、`$'`、`$+`、`$_` **在任何模式里都有效**，会被真的替换掉 ——
#     例如 New = 'D:\x$&y' 会把"被替换掉的旧路径"插进去，写出完全错误的字符串
#   * `$$` -> 一个 `$`
#   * `$1`、`$Recycle` 这类不存在的组，.NET 当字面量留着 —— 所以**不是每种写法都会暴露问题**，
#     正因为如此这个坑更容易被漏掉
function Replace-PathLiteral([string]$Text, [string]$Old, [string]$New) {
    return [regex]::Replace($Text, [regex]::Escape($Old), ([string]$New).Replace('$', '$$'), 'IgnoreCase')
}

function Convert-MappedPath {
    param([string]$Text, [switch]$WithProfileMap)
    $result = $Text
    $hit = $false
    foreach ($old in $pathMap.Keys) {
        if ($result.IndexOf($old, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $result = Replace-PathLiteral $result $old $pathMap[$old]
            $hit = $true
        }
    }
    if ($WithProfileMap) {
        foreach ($old in $profileMap.Keys) {
            if ($result.IndexOf($old, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $result = Replace-PathLiteral $result $old $profileMap[$old]
                $hit = $true
            }
        }
    }
    if ($hit) { return $result }
    return $null
}

# ---------------------------------------------------------------- registry work
$script:pendingEdits = @()
$script:backedUp    = @()
# 备份记忆与"每次运行一个子目录"的时间戳：与 health-fix.ps1 同一契约（见那里的注释）。
$script:RunStamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:backupTried = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:backupOk    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:skipped     = @()

function Repair-KeyTree {
    param(
        [string]$Root,
        [int]$Depth = 4,
        [switch]$WithProfileMap
    )
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Key = $Root; Level = 0 })
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $key  = $item.Key
        $lvl  = $item.Level
        $keyItem = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $keyItem) { continue }

        foreach ($name in @($keyItem.GetValueNames())) {
            $raw = $keyItem.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
            if (-not ($raw -is [string]) -or $raw.Length -eq 0) { continue }
            $new = Convert-MappedPath -Text $raw -WithProfileMap:$WithProfileMap
            if ($null -eq $new) { continue }
            # Never repoint a value at a file that does not exist either: such an entry
            # (e.g. a JetBrains uninstaller that only Toolbox ships now, or an asset the new
            # layout keeps somewhere else) is reported instead of being made differently dead.
            # 字符类排除 " | ; —— 不排除会跨过字段分隔符拼出非法路径
            # （health-fix 的 Get-ExeFrom 早就为此排除了 |，这里当时漏了）
            $fileRef = [regex]::Match($new, '([A-Za-z]:\\[^"|;]*?\.(?:exe|dll|ico|com|bat|cpl|msc|sys))')
            if ($fileRef.Success -and -not (Test-Exists $fileRef.Groups[1].Value)) {
                $script:skipped += [pscustomobject]@{ Key = $key; Name = $name; Text = $new; Missing = $fileRef.Groups[1].Value }
                continue
            }
            $script:pendingEdits += [pscustomobject]@{
                Key = $key; Name = $name; Old = $raw; New = $new
            }
        }
        if ($lvl -ge $Depth) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
            $subPath = ($key.TrimEnd('\') + '\' + $sub.PSChildName)
            $queue.Enqueue([pscustomobject]@{ Key = $subPath; Level = ($lvl + 1) })
        }
    }
}

# 返回 $true = 可以安全改动（试运行恒为 $true）；$false = **备份失败，调用方必须放弃这次改动**。
# 这个契约与 health-fix.ps1 的同名函数一致。原来这里只 export、既不校验退出码也不返回值，
# 于是"备份失败"会静默地变成"没有备份也照样改" —— 而本项目的承诺是"改前必备份"，
# 那条承诺只有在备份真失败的那一刻才有意义。
# （注意：本函数有返回值，所以失败信息由**调用方**打印。在返回值的函数里 Write-Output/ Say
#   会把文本算进返回值 —— health-fix 那边正是这样踩过一次，见 tests\lint.tests.ps1 规则 4。）
function Backup-Key {
    param([string]$Key)
    if (-not $Apply) { return $true }
    if ($script:backupOk.Contains($Key)) { return $true }
    if ($script:backupTried.Contains($Key)) { return $false }   # 试过且没成功：不再重试，直接放弃
    [void]$script:backupTried.Add($Key)
    $regPath = $Key -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
    $safe = ($regPath -replace '[\\:*?"<>|]', '_')
    # 每次运行一个子目录：第二次跑 -Apply 时，绝不会用"已改过的状态"覆盖第一次的原始备份。
    $dir = Join-Path $BackupDir $script:RunStamp
    if (-not (Test-Exists $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $file = Join-Path $dir ("$safe.reg")
    & reg.exe export $regPath $file /y | Out-Null
    $code = $LASTEXITCODE
    # 校验导出结果：退出码 + 文件真的在 + 内容够长（半截文件不算备份）。
    # 用 Test-Exists 而不是裸 Test-Path：约定 10 要求"读不到"不能当成"不存在"。
    # 而备份文件读不到时，这里按"没有可用备份"处理 —— 宁可跳过这次改动。
    $ok = $false
    if ($code -eq 0 -and (Test-Exists $file)) {
        try { $ok = (Get-Item -LiteralPath $file).Length -ge 64 } catch { $ok = $false }
    }
    if (-not $ok) { return $false }
    [void]$script:backupOk.Add($Key)
    $script:backedUp += $Key
    return $true
}

# 写入一个值，并**回读校验**，返回 'ok' 或 'FAILED'。
# 单独成函数是为了让测试能真正调用它：这段逻辑原来内联在主流程里，测试只能断言"代码看起来有写"，
# 而它恰恰是本脚本唯一的"写完到底成没成"的判断点。
# 空值名 = 该键的 (Default) 值：Set-ItemProperty 不接受空 -Name，所以走 Set-Item。
function Set-ValueChecked {
    param([string]$Key, [string]$Name, [string]$New)
    if ($Name) {
        Set-ItemProperty -LiteralPath $Key -Name $Name -Value $New -ErrorAction Continue
    } else {
        Set-Item -LiteralPath $Key -Value $New -ErrorAction Continue
    }
    $written = $null
    try { $written = (Get-Item -LiteralPath $Key).GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } catch { }  # 读不到就算"没写进去"：回读拿不到值时必须报 FAILED，而不是沉默
    if ($written -eq $New) { return 'ok' }
    return 'FAILED'
}

# ---- 通用登记位置 ----------------------------------------------------------
# 这里**只放"位置"，不放"本机的程序"**（硬性约定 8）。分两类：
#   * 下面这张表 = Windows 自带的通用登记位置。它们**不在** Classes 子树里，discovery 的
#     reg.exe 搜索覆盖不到，所以必须整棵走一遍（走整棵也是好事：位置里的任何程序都会被覆盖）。
#   * 厂商条目（notion / xmind / cloudmusic.* / BeyondCompare.* / io.mpv* / Toolbox.* …）一律不列，
#     交给下面的 discovery：它按"旧路径文本"搜 Classes 子树，找到的键更全，也不会随程序增删腐烂。
$targets = @(
    # "打开方式"与"应用路径"（App Paths 决定 exe 名字能不能直接运行/被搜索到）
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths';                 Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths';     Profile = $false }
    @{ Root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths';                 Profile = $false }
    # 卸载记录（"设置 -> 应用"里那条点了没反应的项）
    @{ Root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall';                 Profile = $false }
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall';                 Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall';     Profile = $false }
    # "打开方式"对话框与任务栏跳转列表里的动词
    @{ Root = 'HKLM:\Software\Classes\Applications';                                      Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Classes\Applications';                          Profile = $false }
    @{ Root = 'HKCU:\Software\Classes\Applications';                                      Profile = $false }
    # 自动播放处理程序与"默认程序"里的媒体客户端（走通用父键，任何程序都在内）
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; Profile = $false }
    @{ Root = 'HKLM:\Software\Clients\Media';                                             Profile = $false }
)

# ------------------------------------------------------------------ discovery pass
# Enumerating ProgIDs by hand kept missing places (context-menu verbs, CLSID in-proc shell
# extensions, "Open with" verbs, URL handlers...). So instead: let reg.exe find EVERY key
# whose name or data still contains an old path, then hand those keys to the reliable
# walker above. reg.exe does the searching natively (fast); the walker does the writing.
function Find-KeysByText {
    param([string]$Root, [string]$Needle)
    $found = @()
    $current = ''
    foreach ($line in (& reg.exe query $Root /f $Needle /s 2>$null)) {
        if ($line -match '^(HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER)\\(.+)$') {
            $hive = if ($matches[1] -eq 'HKEY_LOCAL_MACHINE') { 'HKLM:' } else { 'HKCU:' }
            $current = $hive + '\' + $matches[2]
            # the matching key itself is the most precise target
            if ($line -match [regex]::Escape($Needle)) { $found += $current }
        } elseif ($line -match [regex]::Escape($Needle)) {
            if ($current) { $found += $current }   # needle is in one of this key's values
        }
    }
    return ($found | Sort-Object -Unique)
}

$discoveryRoots = @(
    'HKCU\Software\Classes',
    'HKLM\Software\Classes',
    'HKLM\Software\WOW6432Node\Classes'
)
# 搜索的关键词就是本机映射表里的旧前缀（表是空的就没得搜 —— 那种情况在上面已经致命退出了）。
# 旧用户目录（C:\Users\<旧用户名>）是**另一个、宽得多**的问题：搜它会拖进所有曾在旧用户目录里
# 待过的无关程序（GIMP、360se、PowerToys、GitHub Desktop…），而它们的路径没有有效的新目标，
# 所以它刻意不进这一步；用户目录改名只走 ProfileMap（且只在 HKCU\Software\Classes 下生效）。
#
# 顺带一个不该被"发现"的坑：HKCU\Software\Classes\jetbrains（URL 处理器）指向 JetBrains Toolbox
# 守护进程，那个进程在改名后的用户目录里已经不存在了 —— discovery 会找到它，但写入前的存在性
# 校验会把它报成"修不了"而不是改成一个同样不存在的路径。要修就重装 Toolbox，或直接删掉那个键。
# 同理，mpv 的 io.mpv.<类型> 一族建议重跑它自己的安装器（<新位置>\installer\mpv-install.bat），
# 本脚本只兜底处理它漏下的部分。
$needles = @($pathMap.Keys)
$discovered = @{}
foreach ($root in $discoveryRoots) {
    foreach ($needle in $needles) {
        foreach ($key in (Find-KeysByText -Root $root -Needle $needle)) {
            if (-not $discovered.ContainsKey($key)) { $discovered[$key] = $true }
        }
    }
}
foreach ($key in $discovered.Keys) {
    $targets += @{ Root = $key; Profile = ($key -like 'HKCU:\Software\Classes\*') }
}
Write-Output ("discovery: {0} additional key(s) located by reg.exe search" -f $discovered.Count)

# the same key can arrive from several places (explicit list + discovery):
# walk each key once
$seenRoot = @{}
$uniqueTargets = @()
foreach ($t in $targets) {
    if (-not $seenRoot.ContainsKey($t.Root)) { $seenRoot[$t.Root] = $true; $uniqueTargets += $t }
}
$targets = $uniqueTargets

Write-Output '=========================================================='
Write-Output ("repair-migrated-apps  mode = {0}" -f $(if ($Apply) { 'APPLY' } else { 'DRY RUN (nothing written)' }))
Write-Output '=========================================================='

foreach ($t in $targets) {
    Repair-KeyTree -Root $t.Root -WithProfileMap:$t.Profile
}

# dedupe planned writes (the same value can be reached from more than one walked key)
$seenEdit = @{}
$uniqueEdits = @()
foreach ($e in $script:pendingEdits) {
    $id = $e.Key + '|' + $e.Name
    if (-not $seenEdit.ContainsKey($id)) { $seenEdit[$id] = $true; $uniqueEdits += $e }
}
$script:pendingEdits = $uniqueEdits

Write-Output ''
Write-Output '--- registry values to rewrite ---'
if ($script:pendingEdits.Count -eq 0) {
    Write-Output '(none: every registration already points at an existing path)'
} else {
    foreach ($e in $script:pendingEdits) {
        $label = $e.Name
        if (-not $label) { $label = '(default)' }
        Write-Output ("{0}`n    [{1}]`n    - {2}`n    + {3}" -f $e.Key, $label, $e.Old, $e.New)
        if ($Apply) {
            if (-not (Backup-Key -Key $e.Key)) {
                # 宁可这次改不了，也不能改了却回不去。reg export 自己的报错就在上面。
                Write-Output '    -> skipped: backup failed (this key was NOT modified)'
                continue
            }
            $state = Set-ValueChecked -Key $e.Key -Name $e.Name -New $e.New
            Write-Output ("    -> write {0}" -f $state)
        }
    }
}

if ($Apply -and $script:backedUp.Count -gt 0) {
    Write-Output ''
    Write-Output ("backups: {0} key(s) exported to {1}" -f $script:backedUp.Count, (Join-Path $BackupDir $script:RunStamp))
}

if ($script:skipped.Count -gt 0) {
    Write-Output ''
    Write-Output ("--- cannot be repaired automatically ({0} value(s)) ---" -f $script:skipped.Count)
    # group by the missing file: the same dead target usually appears in many keys
    $grouped = $script:skipped | Group-Object Missing | Sort-Object Count -Descending
    $shown = 0
    foreach ($g in $grouped) {
        Write-Output ("missing: {0}   ({1} place(s))" -f $g.Name, $g.Count)
        foreach ($s in ($g.Group | Select-Object -First 2)) {
            Write-Output ("    {0}  [{1}]" -f $s.Key, $(if ($s.Name) { $s.Name } else { '(default)' }))
        }
        $shown++
        if ($shown -ge 12) { Write-Output ("    ... and {0} more distinct missing target(s)" -f ($grouped.Count - $shown)); break }
    }
    Write-Output '  (a JetBrains uninstaller is the usual case: only JetBrains Toolbox ships it now.'
    Write-Output '   Reinstall Toolbox to manage those IDEs, or delete the dead entry by hand.)'
}

# ---------------------------------------------------------------- shortcuts
Write-Output ''
Write-Output '--- Start menu shortcuts ---'
$sp = New-Object -ComObject WScript.Shell

function Set-ShortcutTarget {
    param([string]$Lnk, [string]$Target, [string]$Arguments = '', [string]$Icon = '')
    if ($Apply) {
        $s = $sp.CreateShortcut($Lnk)
        $s.TargetPath = $Target
        if ($Arguments) { $s.Arguments = $Arguments }
        if ($Icon)      { $s.IconLocation = $Icon }
        $s.Save()
        Write-Output ("  FIXED   {0} -> {1}" -f $Lnk, $Target)
    } else {
        Write-Output ("  WOULD FIX {0} -> {1}" -f $Lnk, $Target)
    }
}

# 1. rewrite existing shortcuts whose target points at an old location
#    (the whole "Start Menu" tree, not only its Programs subfolder: some installers
#     drop the .lnk directly into "Start Menu", e.g. "Beyond Compare 5.lnk")
$roots = @("$env:APPDATA\Microsoft\Windows\Start Menu",
           "$env:ProgramData\Microsoft\Windows\Start Menu")
foreach ($root in $roots) {
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)) {
        $old = ''
        try { $old = $sp.CreateShortcut($f.FullName).TargetPath } catch {}  # 读不出来就保持空串（这一行只负责取值）
        if (-not $old) { continue }
        $new = Convert-MappedPath -Text $old
        if ($null -eq $new) { continue }
        if (Test-Exists $old) { continue }   # target is fine, leave it alone（读不到≠不存在）
        if (-not (Test-Exists $new)) { continue }
        Set-ShortcutTarget -Lnk $f.FullName -Target $new
    }
}

# 2. 整条缺失的快捷方式（这类程序对"开始"搜索完全不可见）。
#    清单来自本机配置（机器专属值不进脚本，硬性约定 8）：local\...local.psd1 的 MissingShortcuts。
#    未配置时明确说"未配置 / 未做检查"，**不**打印一片空行假装检查过（同 VerifyPaths 的写法）。
$missing = @()
if ($script:Cfg -and $script:Cfg.MissingShortcuts) { $missing = @($script:Cfg.MissingShortcuts) }
$userPrograms = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
if ($missing.Count -eq 0) {
    Write-Output '  （本机"整条缺失的快捷方式"清单：未配置 —— 未做检查，不等于没有缺失）'
} else {
    foreach ($m in $missing) {
        if (-not $m -or -not $m.Name -or -not $m.Target) { continue }
        $lnk = Join-Path $userPrograms ("{0}.lnk" -f [string]$m.Name)
        if (Test-Exists $lnk) { continue }
        if (-not (Test-Exists ([string]$m.Target))) { continue }
        Set-ShortcutTarget -Lnk $lnk -Target ([string]$m.Target)
    }
}

# ---------------------------------------------------------------- verification
Write-Output ''
Write-Output '--- verification ---'
# ① 映射表本次到底被用到没有 —— 明说，免得"什么都没打印"被当成"全都对"。
#    能走到这里 $pathMap 一定非空（0 条在上面已致命退出），所以"匹配到 0 条"是真的"无需改指"；
#    把两部分的条数也报出来，本机配置漏填/填错时一眼能看出来。
$usedOld = @($script:pendingEdits | ForEach-Object { $_.Old } | Where-Object { $_ } | Sort-Object -Unique)
Write-Output ("映射表 {0} 条（本机配置 {1} + 内置 {2}），本次匹配到 {3} 条{4}" -f $pathMap.Count, @($localPathMap).Count, @($pathMapBase).Count, $usedOld.Count, $(if ($usedOld.Count -eq 0) { '（本机已无需改指的登记）' } else { '' }))
# ② 本机验收清单（可选）。原来这里**写死**了 10 条本机绝对路径：换台机器就是 10 条假 ABSENT，
#    而且会随程序搬家而腐烂 —— 本机有一条停在迁移前的 BCompare 路径，每次跑都打一条假警报。
#    硬性约定 8：机器专属值不进脚本。没配置时明确说"未配置"，**不**打印一片 OK 假装检查过。
$verifyPaths = @()
if ($script:Cfg -and $script:Cfg.VerifyPaths) { $verifyPaths = @($script:Cfg.VerifyPaths) }
if ($verifyPaths.Count -eq 0) {
    Write-Output ''
    Write-Output '本机验收清单：未配置。'
    Write-Output '  （要逐条核对"我修过的程序还在不在"，把绝对路径填进'
    Write-Output '   local\repair-migrated-apps.local.psd1 的 VerifyPaths；模板见 config\repair-migrated-apps.local.example.psd1）'
} else {
    Write-Output ''
    Write-Output ("本机验收清单（{0} 条，来自 local 配置）：" -f $verifyPaths.Count)
    $absent = 0
    foreach ($c in $verifyPaths) {
        $ok = Test-Exists $c
        if (-not $ok) { $absent++ }
        Write-Output ("  {0,-6} {1}" -f $(if ($ok) { 'OK' } else { 'ABSENT' }), $c)
    }
    if ($absent -gt 0) {
        Write-Output ("  → {0}/{1} 条不存在：若它们确实已卸载或又搬走了，请更新这份清单；否则先查为什么。" -f $absent, $verifyPaths.Count)
    }
}

if ($Apply) {
    # tell Explorer that file-type/icon registrations changed
    & ie4uinit.exe -show 2>$null | Out-Null
    Write-Output ''
    Write-Output 'Done. If an icon or an "Open with" entry is still stale, sign out and back in,'
    Write-Output 'or run:  taskkill /f /im explorer.exe & start explorer.exe'
} else {
    Write-Output ''
    Write-Output 'Dry run finished. Re-run with -Apply (elevated) to write these changes.'
}
