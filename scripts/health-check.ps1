# ============================================================================
#  health-check.ps1 -- 季度健康体检（只读，不做任何修改）
#
#  它做什么：
#    1) 引用体检：把系统里"登记了某个程序位置"的地方逐项核对目标是否存在
#       - 卸载记录（设置→应用）: InstallLocation / DisplayIcon / UninstallString / ModifyPath
#       - App Paths（Win+R / ShellExecute 用）
#       - 文件关联：每个扩展名的生效 ProgID 及其 shell\open\command / DefaultIcon
#       - Applications\<exe>（"打开方式"动词）
#       - 协议处理程序（xxx://）
#       - CLSID 的 InprocServer32 / LocalServer32（右键菜单、缩略图/预览处理器、shell 扩展）
#       - "此电脑/桌面"命名空间项（提供者 DLL 是否存在）
#       - 服务/驱动 ImagePath、启动项、快捷方式、PATH 目录
#    2) 孤儿缓存：%LOCALAPPDATA%\Package Cache 里不再被任何已安装产品引用的目录（可释放空间）
#    3) 旧路径残留：按 health-check.needles.txt 里的路径清单全注册表搜索
#    4) 空间报告：各盘容量 + 与上次体检的对比（增长/减少多少）+ %LOCALAPPDATA%/%APPDATA% 大户排行
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File .\health-check.ps1
#    常用开关：
#      -OutDir <目录>          报告输出根目录（默认：脚本同目录\健康体检；.cmd 启动器会传 local\reports）
#      -SkipOldPathScan         跳过"旧路径残留"（该步最慢，视清单条数约 3~6 分钟）
#      -SkipClsidScan           跳过 CLSID 全量扫描
#      -SkipAssocScan           跳过"文件关联核对"（逐扩展名核对，默认开启；嫌慢可用它）
#      -SizeScan                额外统计 %LOCALAPPDATA%/%APPDATA% 各子目录体积（较慢，默认关）
#      -ScanConfigFiles         额外扫描 D:\Apps 下文本配置里的旧路径（需 -SkipOldPathScan 未开）
#      -WarnFreePercent 15      C 盘可用低于该百分比时告警（默认 15）
#      -NoHistory               本次不写入 snapshot.json（不参与增长对比）
#
#  运行时间参考：默认（含 CLSID 扫描、不含旧路径扫描）约 2~4 分钟；开 -SizeScan 再 +5~15 分钟。
#  报告是逐行写入的，运行中即可打开 report.md 查看进度。
#
#  安全：本脚本只读。所有"状态=不存在"的项都只是报告，不会自动修改。
#  退出码：0 = 无"严重"项；1 = 有"严重"项（便于 CI / 批处理判定）。
# ============================================================================
[CmdletBinding()]
param(
    [string]$OutDir,
    [switch]$SkipOldPathScan,
    [switch]$SkipClsidScan,
    [switch]$SkipAssocScan,
    [switch]$SizeScan,
    [switch]$ScanConfigFiles,
    [int]$WarnFreePercent = 15,
    [switch]$NoHistory
)

$ErrorActionPreference = 'Continue'
# ---- 引擎适配（同一份脚本同时支持 Windows PowerShell 5.1 与 PowerShell 7.x）----
$script:PSMajor = $PSVersionTable.PSVersion.Major
$script:PSName  = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
# 报告/日志按 UTF-8 写：PS7 需显式 utf8BOM 才与 5.1 行为一致（5.1 的 UTF8 本身带 BOM）
$script:Enc = if ($script:PSMajor -ge 7) { 'utf8BOM' } else { 'UTF8' }
# 脚本所在目录（param 默认值里 $PSScriptRoot 可能为空，所以在这里解析）
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { try { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path $scriptDir '健康体检' }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmm'
$runDir  = Join-Path $OutDir $stamp
$histDir = Join-Path $OutDir 'history'
$needles = Join-Path $scriptDir 'health-check.needles.txt'
$report  = Join-Path $runDir 'report.md'
if (-not (Test-Path $runDir))  { New-Item -ItemType Directory -Path $runDir  -Force | Out-Null }
if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }

# ---- 输出工具（边跑边写报告，分批写盘提速；运行中可随时打开 report.md 看进度）----
Set-Content -LiteralPath $report -Value '' -Encoding $script:Enc
$script:buf = New-Object System.Collections.Generic.List[string]
function Flush-Buf { if ($script:buf.Count -gt 0) { Add-Content -LiteralPath $report -Value $script:buf -Encoding $script:Enc; $script:buf.Clear() } }
function W([string]$s = '') {
    Write-Host $s
    $script:buf.Add($s)
    if ($script:buf.Count -ge 25) { Flush-Buf }
}
function Section([string]$t) { Flush-Buf; W ''; W ("## " + $t); W ''; Flush-Buf }
$findings = New-Object System.Collections.Generic.List[object]
function AddFinding([string]$sev, [string]$cat, [string]$loc, [string]$target, [string]$status, [string]$hint = '') {
    # 目标落在安装包缓存（Package Cache）里时降级为"警告"：
    # 这类失效的根因是缓存被清理过（不是程序本身缺失），卸载/修复会失败但不影响日常使用，
    # 而且数量往往很大（VC++/.NET 运行库等系统组件），降级可避免报告被刷屏。
    if ($sev -eq '严重' -and $target -match '\\Package Cache\\') {
        $sev = '警告'
        $pcHint = '安装包缓存已被清理（不是程序缺失）：设置→应用里的卸载/修复会失败，需用官方安装包重新安装后再卸载，或直接删除该记录。'
        $hint = if ($hint) { $pcHint + ' ' + $hint } else { $pcHint }
    }
    $findings.Add([pscustomobject]@{ Severity=$sev; Category=$cat; Location=$loc; Target=$target; Status=$status; Hint=$hint })
}
# 快速目录体积（.NET 枚举，比 Get-ChildItem -Recurse 快数倍）。
# 逐层自己走栈，而不用 EnumerateFiles(AllDirectories)：后者一旦碰到**一个**读不到的子目录
# 就整棵树抛异常，被 catch 吞掉后**整个顶层目录的体积会变成 0** —— 那是严重的少报。
# 现在只跳过读不到的那一层，其余照常累计，并记下跳过了多少。
$script:dirBytesSkipped = 0
function Get-DirBytes([string]$path) {
    $sum = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $cur = [string]$stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($cur)
            foreach ($f in $di.EnumerateFiles()) {
                try { $sum += $f.Length } catch { $script:dirBytesSkipped++ }
            }
            foreach ($d in $di.EnumerateDirectories()) { $stack.Push($d.FullName) }
        } catch { $script:dirBytesSkipped++ }
    }
    return $sum
}

# ---- 路径判定 --------------------------------------------------------------
$clsRoots = @('HKCU:\Software\Classes','HKLM:\Software\Classes','HKLM:\Software\Classes\WOW6432Node')

# PS 路径（HKCU:\Software\... / HKLM:\Software\...）→ .NET RegistryKey。
# 热点循环里用原生 API 代替 Test-Path / Get-Item，快一个数量级。
function Open-RegKey([string]$psPath, [bool]$writable = $false) {
    $base = [Microsoft.Win32.Registry]::CurrentUser
    if ($psPath -like 'HKLM*') { $base = [Microsoft.Win32.Registry]::LocalMachine }
    $sub = $psPath -replace '^HK[A-Z]+:\\',''
    try { return $base.OpenSubKey($sub, $writable) } catch { return $null }
}
function Get-RegValue([string]$psPath, [string]$name = '') {
    $rk = Open-RegKey $psPath
    if (-not $rk) { return $null }
    $v = $rk.GetValue($name); $rk.Close(); return $v
}

# ProgID 索引：一次性枚举三个 Classes 根的子键名（3 次调用），
# 之后所有"某个 ProgID 是否存在"的判断都走内存查询，避免成千上万次注册表访问。
$script:progIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:clsids  = New-Object System.Collections.Generic.List[string]     # Classes\CLSID 下的 CLSID
$script:protos  = New-Object System.Collections.Generic.List[string]     # 带 URL Protocol 的协议处理程序
foreach ($r in $clsRoots) {
    $base = [Microsoft.Win32.Registry]::CurrentUser
    if ($r -like 'HKLM*') { $base = [Microsoft.Win32.Registry]::LocalMachine }
    $sub = ($r -replace '^HK[A-Z]+:\\','')
    $rk = $base.OpenSubKey($sub)
    if (-not $rk) { continue }
    foreach ($n in $rk.GetSubKeyNames()) {
        [void]$script:progIds.Add($n)
        if ($n.StartsWith('{')) { $script:clsids.Add($r + '\' + $n) }
        if ($n -match '^[a-z][a-z0-9\.\-\+]{1,40}$') {          # 协议名基本都长这样
            $ck = $rk.OpenSubKey($n)
            if ($ck) {
                if ($null -ne $ck.GetValue('URL Protocol')) { $script:protos.Add($r + '\' + $n) }
                $ck.Close()
            }
        }
    }
    $rk.Close()
}
# 每个 ProgID 的命令/图标只检查一次（多个扩展名常共用同一个 ProgID）
$script:progCheck = @{}
function Test-ProgIdTargets([string]$progId) {
    if ($script:progCheck.ContainsKey($progId)) { return $script:progCheck[$progId] }
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($sub in 'shell\open\command','DefaultIcon') {
        foreach ($r in $clsRoots) {
            $pk = $r + '\' + $progId + '\' + $sub
            $rk = Open-RegKey $pk
            if (-not $rk) { continue }
            $path = Get-FirstPath ([string]$rk.GetValue(''))
            $rk.Close()
            if ($path -and (Get-Status $path) -eq 'missing') {
                $missing.Add([pscustomobject]@{ Sub=$sub; Location=$pk; Target=$path })
            }
            break
        }
    }
    $res = [pscustomobject]@{ Missing = $missing }
    $script:progCheck[$progId] = $res
    return $res
}
function Get-FirstPath([string]$s) {
    if (-not $s) { return '' }
    try { $s = [Environment]::ExpandEnvironmentVariables($s) } catch {}
    $m = [regex]::Match($s, '([A-Za-z]:\\[^";|]+)')
    if (-not $m.Success) { return '' }
    $p = $m.Groups[1].Value.Trim()
    # 去掉图标索引：形如 "path,0" 或 "path,-730"（负号很常见，别漏）
    $p = $p -replace ',\s*-?\d+\s*$',''
    $ci = $p.LastIndexOf(',')
    if ($ci -gt 1 -and $p.Substring($ci) -notmatch '\\') { $p = $p.Substring(0, $ci) }   # 兜底：末尾逗号后没有反斜杠就视为索引
    $p = ($p -split '\s{2,}')[0].Trim()
    # 注意 IgnoreCase：注册表里大量是大写扩展名（NOTEPAD.EXE、IMEPADSV.EXE），
    # 不加忽略大小写就剥不掉后面的参数，会把存在的文件误判为"不存在"
    $m2 = [regex]::Match($p, '^(.+?\.(?:exe|dll|ico|msc|cpl|sys|bat|cmd|com|scr|ps1|jar|py|vbs))(\s|$)', 'IgnoreCase')
    if ($m2.Success) { $p = $m2.Groups[1].Value }
    # 形如 "C:\WINDOWS\system32\perfmon /sys /load \"%1\""：无扩展名且带参数 → 取第一个 token
    if ($p -match '\s') {
        $head = ($p -split '\s+')[0]
        if ([System.IO.Path]::GetExtension($head) -or (Test-Path -LiteralPath $head) -or (Test-Path -LiteralPath ($head + '.exe'))) { $p = $head }
    }
    return $p.Trim().TrimEnd('\')
}
# 执行一段 .NET 调用，成功返回 $null，失败返回"最内层异常的类型名"。
# 必须解包 InnerException：PS7(.NET Core) 把 .NET 异常包成 MethodInvocationException /
# RuntimeException，所以 `catch [System.IO.FileNotFoundException]` 在 PS7 里永远匹配不上
# （本次踩过：PS7 下所有"缺失"都被误判成"读不到"，报告成了"一切正常"的假阴性）。
function Get-ExceptionClass([scriptblock]$sb) {
    try { & $sb; return $null }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        return $ex.GetType().Name
    }
}
function Get-Status([string]$path) {
    if (-not $path) { return 'n/a' }
    # 这两处对普通用户 ACL 受限，文件存在性无法可靠判断 → 一律不当问题（避免假阳性）：
    #   \WindowsApps\ （Store 应用）      \DriverStore\ （驱动仓库，TrustedInstaller 所有）
    if ($path -match '\\WindowsApps\\' -or $path -match '\\DriverStore\\') { return 'denied' }
    $cls = Get-ExceptionClass { [void][System.IO.File]::GetAttributes($path) }
    if (-not $cls) { return 'ok' }
    if ($cls -in 'UnauthorizedAccessException','SecurityException') { return 'denied' }
    # 无扩展名 → 先试 .exe（注册表里有 "…\system32\perfmon /sys /load" 这类写法）
    if ([System.IO.Path]::GetExtension($path) -eq '' -and (Test-Path -LiteralPath ($path + '.exe') -ErrorAction SilentlyContinue)) { return 'ok' }
    if ($cls -in 'FileNotFoundException','DirectoryNotFoundException') { return 'missing' }
    # 其它异常 → 用 Test-Path 兜底
    if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) { return 'ok' }
    $cls2 = Get-ExceptionClass { [void][System.IO.Directory]::GetAttributes($path) }
    if (-not $cls2) { return 'ok' }
    if ($cls2 -in 'FileNotFoundException','DirectoryNotFoundException','IOException','ArgumentException','NotSupportedException') { return 'missing' }
    return 'denied'
}
function Test-ProgIdExists([string]$name) {
    if (-not $name) { return $false }
    return $script:progIds.Contains($name)
}
function Get-EffectiveProgId([string]$ext) {
    foreach ($r in $clsRoots) {
        $rk = Open-RegKey ($r + '\' + $ext)
        if ($rk) {
            $v = [string]$rk.GetValue('')
            $rk.Close()
            if ($v) { return @{ ProgId = $v; From = $r } }
        }
    }
    return $null
}

# 旧路径清单是否"可用"：
#   empty       = 没有条目（模板里全是注释）—— 这一步实际上没做，绝不能报绿
#   placeholder = 条目全是占位符（含 <> 或"旧用户名"之类）—— 同样不能当成检查通过
#   ok          = 至少有一条像真实路径
# 历史教训：旧实现只看 $hits.Count -eq 0 就打印"✓ 回归检查通过"，
# 于是"没配置清单"会得到一张绿色报告 —— 和 PS7 把"缺失"误判成"读不到"是同一类假阴性。
function Get-NeedlesState([string[]]$List) {
    if (-not $List -or @($List).Count -eq 0) { return 'empty' }
    $real = @($List | Where-Object { $_ -and $_ -notmatch '[<>]' -and $_ -notmatch '旧用户名|旧名|old-name|oldname|OLDPROFILE' })
    if ($real.Count -eq 0) { return 'placeholder' }
    return 'ok'
}

W ("# 健康体检报告  {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ''
W ("- 计算机：{0}    用户：{1}" -f $env:COMPUTERNAME, $env:USERNAME)
W ("- 引擎：{0}" -f $script:PSName)
W ("- 报告目录：{0}" -f $runDir)

# ============================================================================
Section '1. 系统与磁盘概览'
# ============================================================================
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
    W ("- 上次启动：{0}（已运行 {1:N1} 小时）" -f $os.LastBootUpTime, ((Get-Date) - $os.LastBootUpTime).TotalHours)
}
$pend = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
W ("- 待重启操作（PendingFileRenameOperations）：{0} 条" -f @($pend).Count)
if (@($pend).Count -gt 0) { AddFinding '提示' '系统' 'Session Manager' ("{0} 条待重启删除/改名" -f @($pend).Count) '重启后生效' '重启一次即可' }

$drives = @()
foreach ($d in 'C','D','E') {
    try {
        $dr = New-Object System.IO.DriveInfo($d)
        if ($dr.IsReady) {
            $drives += [pscustomobject]@{
                Drive = $d
                TotalGB = [math]::Round($dr.TotalSize/1GB,1)
                FreeGB  = [math]::Round($dr.AvailableFreeSpace/1GB,1)
                FreePct = [math]::Round(100*$dr.AvailableFreeSpace/$dr.TotalSize,1)
            }
        }
    } catch {}
}
W ''
W '| 盘 | 共 (GB) | 可用 (GB) | 可用 % |'
W '|---|---|---|---|'
foreach ($d in $drives) { W ("| {0}: | {1} | {2} | {3}% |" -f $d.Drive, $d.TotalGB, $d.FreeGB, $d.FreePct) }

# ---- 与上次体检对比（增长报告）--------------------------------------------
$prev = Get-ChildItem $histDir -Filter 'snapshot.json' -ErrorAction SilentlyContinue  # lint-ok: history 目录是平的，只看当层是对的 | Select-Object -First 1
$prevObj = $null
if ($prev) { try { $prevObj = Get-Content -LiteralPath $prev.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
if ($prevObj) {
    $days = [math]::Round(((Get-Date) - [datetime]$prevObj.timestamp).TotalDays, 1)
    W ''
    W ("与上次体检（{0}，{1} 天前）对比：" -f $prevObj.timestamp, $days)
    W ''
    W '| 盘 | 上次可用 (GB) | 本次可用 (GB) | 变化 (GB) | 日均 (MB) |'
    W '|---|---|---|---|---|'
    foreach ($d in $drives) {
        $pv = $null
        if ($prevObj.drives) {
            $prop = $prevObj.drives.PSObject.Properties[$d.Drive]
            if ($prop) { $pv = $prop.Value }
        }
        if ($pv) {
            $delta = [math]::Round($d.FreeGB - [double]$pv.FreeGB, 1)
            $perDay = if ($days -gt 0) { [math]::Round($delta * 1024 / $days, 1) } else { 0 }
            W ("| {0}: | {1} | {2} | {3} | {4} |" -f $d.Drive, $pv.FreeGB, $d.FreeGB, $delta, $perDay)
            if ($delta -lt -10) {
                AddFinding '警告' '容量' ("{0}:" -f $d.Drive) ("{0} 天内减少 {1} GB（日均 {2} MB）" -f $days, [math]::Abs($delta), [math]::Abs($perDay)) '增长偏快' '用 WizTree 扫该盘找大户；看下面第 13 节的目录排行'
            }
        }
    }
} else {
    W ''
    # 只有真的会写盘时才说"已保存"（-NoHistory 下不能假报，否则读者会以为已有基线可比）
    if ($NoHistory) { W '（本次用了 -NoHistory：**未保存**基线快照，下次体检仍无法对比增长）' }
    else            { W '（首次运行：已保存基线快照，下次体检将显示增长对比）' }
}
foreach ($d in $drives) {
    if ($d.FreePct -lt $WarnFreePercent) {
        AddFinding '警告' '容量' ("{0}:" -f $d.Drive) ("可用 {0} GB（{1}%）" -f $d.FreeGB, $d.FreePct) '低于阈值' ("建议保持 ≥{0}%；见体检报告的清理建议" -f $WarnFreePercent)
    }
}

# ============================================================================
Section '2. 卸载记录（设置 → 应用）目标核对'
# ============================================================================
$unRoots = @(
    @{ PS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';          Reg='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ PS='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Reg='HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ PS='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';          Reg='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
)
$unBad = 0; $unTotal = 0
W '| 状态 | 应用 | 字段 | 指向 |'
W '|---|---|---|---|'
foreach ($root in $unRoots) {
    foreach ($k in (Get-ChildItem -LiteralPath $root.PS -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p.DisplayName) { continue }
        $unTotal++
        foreach ($f in 'InstallLocation','DisplayIcon','UninstallString','QuietUninstallString','ModifyPath','Inno Setup: App Path') {
            $raw = [string]$p.$f
            if (-not $raw) { continue }
            if ($raw -match '^\s*(MsiExec|msiexec|rundll32|cmd\.exe|powershell)') { continue }
            $path = Get-FirstPath $raw
            if (-not $path) { continue }
            $st = Get-Status $path
            if ($st -eq 'missing') {
                $unBad++
                W ("| ✗ 不存在 | {0} | {1} | {2} |" -f $p.DisplayName, $f, $path)
                AddFinding '严重' '卸载记录' ($root.Reg + '\' + $k.PSChildName) $path ("{0} 的 {1} 指向不存在的文件" -f $p.DisplayName, $f) '设置→应用里图标/卸载/修复会失效；改指新路径，或（新位置确实没有对应文件时）删除该记录'
            }
        }
    }
}
if ($unBad -eq 0) { W ("| ✓ | 共 {0} 条卸载记录 | — | 全部指向存在的文件 |" -f $unTotal) }

# ============================================================================
Section '3. App Paths 目标核对（Win+R / ShellExecute）'
# ============================================================================
$apRoots = @(
    @{ PS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';          Reg='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths' },
    @{ PS='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths'; Reg='HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths' },
    @{ PS='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';          Reg='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths' }
)
$apBad = 0
W '| 状态 | 名称 | 指向 |'
W '|---|---|---|'
foreach ($root in $apRoots) {
    foreach ($k in (Get-ChildItem -LiteralPath $root.PS -ErrorAction SilentlyContinue)) {
        $v = [string](Get-Item -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).GetValue('')
        $path = Get-FirstPath $v
        if (-not $path) { continue }
        $st = Get-Status $path
        if ($st -eq 'missing') {
            $apBad++
            W ("| ✗ 不存在 | {0} | {1} |" -f $k.PSChildName, $path)
            AddFinding '严重' 'App Paths' ($root.Reg + '\' + $k.PSChildName) $path '目标不存在 → Win+R 输入这个名字会失败' '改指新路径；程序已卸载则删除该键'
        }
    }
}
if ($apBad -eq 0) { W '| ✓ | 全部 App Paths | 目标均存在 |' }

# ============================================================================
Section '4. 文件关联目标核对（双击文件能不能打开）'
# ============================================================================
if ($SkipAssocScan) {
    W '（本次已用 -SkipAssocScan 跳过；这一步逐扩展名核对，是最耗时的一节）'
    AddFinding '提示' '体检范围' '-SkipAssocScan' '文件关联核对被跳过' '未执行检查' '报告里不体现失效的文件关联；需要时去掉该开关重跑'
} else {
$extBad = 0; $extTotal = 0
W '说明：只列出"生效 ProgID 或其命令/图标指向不存在的文件"的扩展名。'
W ''
W '| 状态 | 扩展名 | 生效 ProgID | 问题 |'
W '|---|---|---|---|'
$extKeys = @()
foreach ($r in $clsRoots) {
    $rk = Open-RegKey $r
    if (-not $rk) { continue }
    foreach ($n in $rk.GetSubKeyNames()) { if ($n -like '.*') { $extKeys += $n } }
    $rk.Close()
}
$extKeys = $extKeys | Sort-Object -Unique
$extSeen = @{}
foreach ($ext in $extKeys) {
    $extTotal++
    $eff = Get-EffectiveProgId $ext
    if (-not $eff) { continue }
    if (-not (Test-ProgIdExists $eff.ProgId)) {
        $key = $ext + '|' + $eff.ProgId
        if ($extSeen.ContainsKey($key)) { continue }
        $extSeen[$key] = $true
        $extBad++
        W ("| ✗ ProgID 不存在 | {0} | {1} | 来自 {2} |" -f $ext, $eff.ProgId, ($eff.From -replace '^HK[A-Z]+:\\Software\\Classes',''))
        AddFinding '严重' '文件关联' ($eff.From + '\' + $ext) $eff.ProgId ("{0} 的默认程序 {1} 已不存在 → 双击该类文件会打不开" -f $ext, $eff.ProgId) '删除该覆盖值（回落系统默认），或重新指定一个存在的 ProgID'
        continue
    }
    # ProgID 存在 → 查一次它的命令/图标（结果按 ProgID 缓存，多个扩展名共用时不重复查）
    $chk = Test-ProgIdTargets $eff.ProgId
    if ($chk.Missing.Count -gt 0) {
        $key = $ext + '|' + $eff.ProgId
        if (-not $extSeen.ContainsKey($key)) {
            $extSeen[$key] = $true
            $extBad++
            $subs = (($chk.Missing | ForEach-Object { $_.Sub }) -join '+')
            $tgt  = $chk.Missing[0].Target
            W ("| ✗ 命令/图标不存在 | {0} | {1} | {2} → {3} |" -f $ext, $eff.ProgId, $subs, $tgt)
            AddFinding '严重' '文件关联' $chk.Missing[0].Location $tgt ("{0} 的 {1}（{2}）指向不存在的文件" -f $eff.ProgId, $subs, $ext) '重新指向存在的程序，或卸载残留后清理该项'
        }
    }
    # OpenWithProgids 里指向不存在 ProgID 的条目
    foreach ($r in $clsRoots) {
        $ow = $r + '\' + $ext + '\OpenWithProgids'
        $ok = Open-RegKey $ow
        if (-not $ok) { continue }
        foreach ($n in $ok.GetValueNames()) {
            $v = [string]$ok.GetValue($n)
            $cand = if ($v) { $v } else { $n }
            if ($cand -and -not (Test-ProgIdExists $cand) -and $cand -notmatch '^AppX') {
                W ("| ✗ 打开方式残留 | {0} | {1} | OpenWithProgids |" -f $ext, $cand)
                AddFinding '警告' '打开方式' ($ow) $cand ("{0} 的「打开方式」里 {1} 已不存在" -f $ext, $cand) '删除该值（否则「打开方式」里会留一个点了没反应的项）'
            } elseif ($cand -and $cand -notmatch '^AppX' -and (Test-ProgIdExists $cand)) {
                # ProgID 还在，但它指向的程序可能已经没了（例如 PotPlayer 卸载后残留的 PotPlayerMini64.*）
                $pc = Test-ProgIdTargets $cand
                if ($pc.Missing.Count -gt 0) {
                    W ("| ✗ 打开方式目标缺失 | {0} | {1} | → {2} |" -f $ext, $cand, $pc.Missing[0].Target)
                    AddFinding '警告' '打开方式' ($ow) $pc.Missing[0].Target ("{0} 的「打开方式」里 {1} 指向不存在的文件" -f $ext, $cand) '删除该值，或重新注册该程序'
                }
            }
        }
        $ok.Close()
    }
}
if ($extBad -eq 0) { W ("| ✓ | 共检查 {0} 个扩展名 | — | 关联目标均正常 |" -f $extTotal) }
}

# ============================================================================
Section '5. 打开方式动词（Classes\Applications\<exe>）'
# ============================================================================
$appBad = 0
W '| 状态 | 应用 | 指向 |'
W '|---|---|---|'
foreach ($r in @('HKCU:\Software\Classes\Applications','HKLM:\Software\Classes\Applications','HKLM:\Software\Classes\WOW6432Node\Applications')) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    foreach ($k in (Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
        foreach ($sub in 'shell\open\command','shell\play\command') {
            $pk = $k.PSPath + '\' + $sub
            if (-not (Test-Path -LiteralPath $pk)) { continue }
            $raw = [string](Get-Item -LiteralPath $pk -ErrorAction SilentlyContinue).GetValue('')
            $path = Get-FirstPath $raw
            if (-not $path) { continue }
            if ((Get-Status $path) -eq 'missing') {
                $appBad++
                W ("| ✗ 不存在 | {0} | {1} |" -f $k.PSChildName, $path)
                AddFinding '严重' '打开方式' $pk $path ('{0} 的"{1}"动词指向不存在的文件' -f $k.PSChildName, $sub) '改指新路径或删除该键'
            }
        }
    }
}
if ($appBad -eq 0) { W '| ✓ | 全部打开方式动词 | 目标均存在 |' }

# ============================================================================
Section '6. 协议处理程序（xxx://）'
# ============================================================================
$protoBad = 0
W '| 状态 | 协议 | 指向 |'
W '|---|---|---|'
foreach ($pr in $script:protos) {
    $pk = $pr + '\shell\open\command'
    $item = Get-Item -LiteralPath $pk -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    $raw = [string]$item.GetValue('')
    $path = Get-FirstPath $raw
    if (-not $path) { continue }
    if ((Get-Status $path) -eq 'missing') {
        $protoBad++
        $pname = Split-Path $pr -Leaf
        W ("| ✗ 不存在 | {0} | {1} |" -f $pname, $path)
        AddFinding '严重' '协议处理' $pk $path ("{0}:// 指向不存在的程序" -f $pname) '改指新路径或删除该协议注册'
    }
}
if ($protoBad -eq 0) { W '| ✓ | 全部协议处理程序 | 目标均存在 |' }

# ============================================================================
if (-not $SkipClsidScan) {
Section '7. CLSID 扩展（右键菜单 / 缩略图 / 预览 / shell 扩展）'
# ============================================================================
    $clsidBad = 0; $clsidTotal = 0
    W '| 状态 | CLSID | 名称 | 指向 |'
    W '|---|---|---|---|'
    foreach ($ck in $script:clsids) {
        $item = Get-Item -LiteralPath $ck -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        $subs = @($item.GetSubKeyNames())
        foreach ($sub in 'InprocServer32','InprocServer','LocalServer32') {
            if ($subs -notcontains $sub) { continue }
            $pk = $ck + '\' + $sub
            $clsidTotal++
            $raw = [string](Get-Item -LiteralPath $pk -ErrorAction SilentlyContinue).GetValue('')
            $path = Get-FirstPath $raw
            if (-not $path) { continue }
            if ((Get-Status $path) -eq 'missing') {
                $clsidBad++
                $name = [string]$item.GetValue('')
                W ("| ✗ 不存在 | {0} | {1} | {2} |" -f (Split-Path $ck -Leaf), $name, $path)
                AddFinding '严重' 'CLSID 扩展' $pk $path ("{0} 的 {1} 指向不存在的文件" -f $(if ($name) { $name } else { Split-Path $ck -Leaf }), $sub) '相关右键菜单/缩略图/预览会失效；卸载残留则删除该 CLSID 键'
            }
        }
    }
    if ($clsidBad -eq 0) { W ("| ✓ | 共 {0} 个 CLSID | — | 目标均存在 |" -f $clsidTotal) }
} else {
    Section '7. CLSID 扩展（右键菜单 / 缩略图 / 预览 / shell 扩展）—— 已跳过'
    W '（本次已用 -SkipClsidScan 跳过 —— **本节没有做任何检查**。）'
    AddFinding '提示' '体检范围' '-SkipClsidScan' 'CLSID 外壳扩展核对被跳过' '未执行检查' '报告里不体现失效的右键菜单/缩略图/预览；需要时去掉该开关重跑'
}

# ============================================================================
Section '8. "此电脑/桌面"命名空间项（例如已卸载软件留下的死图标）'
# ============================================================================
$nsBad = 0
W '| 状态 | 位置 | 名称 | 提供者 |'
W '|---|---|---|---|'
foreach ($pair in @(@('HKCU','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace','MyComputer'),
                    @('HKCU','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace','Desktop'),
                    @('HKLM','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace','MyComputer'),
                    @('HKLM','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace','Desktop'))) {
    if (-not (Test-Path -LiteralPath $pair[1])) { continue }
    foreach ($k in (Get-ChildItem -LiteralPath $pair[1] -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -notmatch '^\{') { continue }
        $name = [string](Get-Item -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).GetValue('')
        if ($name -match '^CLSID_ThisPC') { continue }      # 系统自带项
        $dll = ''
        $hasInproc = $false
        foreach ($cr in $clsRoots) {
            $ik = $cr + '\CLSID\' + $k.PSChildName + '\InprocServer32'
            if (Test-Path -LiteralPath $ik) {
                $hasInproc = $true
                $dll = Get-FirstPath ([string](Get-Item -LiteralPath $ik).GetValue('')); break
            }
        }
        # 没有 InprocServer32 的命名空间项不是"DLL 型"（系统自带或由别的方式实现），跳过不判
        if (-not $hasInproc) { continue }
        $st = if ($dll) { Get-Status $dll } else { 'missing' }
        if ($st -eq 'missing') {
            $nsBad++
            W ("| ✗ 提供者不存在 | {0} | {1} | {2} |" -f $pair[2], $name, $(if ($dll) { $dll } else { '(InprocServer32 为空)' }))
            AddFinding '严重' '命名空间图标' ($pair[1] + '\' + $k.PSChildName) $(if ($dll) { $dll } else { '(无)' }) ("{0} 里「{1}」的提供者已不存在（会显示成一个打不开的图标）" -f $pair[2], $name) '删除该命名空间键（注意该键可能被加保护，需要先夺取所有权）'
        }
    }
}
if ($nsBad -eq 0) { W '| ✓ | 全部命名空间项 | 提供者均存在 |' }

# ============================================================================
Section '9. 服务 / 驱动 ImagePath'
# ============================================================================
$svcBad = 0
W '| 状态 | 服务 | 指向 |'
W '|---|---|---|'
foreach ($k in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    $img = [string]$p.ImagePath
    if (-not $img) { continue }
    $t = $img.Trim().Trim('"') -replace '^\\\?\?\\',''
    $path = Get-FirstPath $t
    if (-not $path) {
        # 相对/特殊写法（驱动很常见），必须逐种解析，否则会把存在的驱动判成"不存在"：
        #   \SystemRoot\System32\DriverStore\...   System32\DriverStore\...   system32\drivers\wd\x.sys   纯文件名.sys
        if     ($t -match '^\\?SystemRoot\\(.+)$')      { $path = Join-Path $env:SystemRoot $matches[1] }
        elseif ($t -match '^[Ss]ystem32\\(.+)$')        { $path = Join-Path "$env:SystemRoot\System32" $matches[1] }
        elseif ($t -match '^([A-Za-z0-9_\.\-]+\.sys)$') { $path = Join-Path "$env:SystemRoot\System32\drivers" $matches[1] }
        elseif ($t -match '^\\SystemRoot\\')            { $path = $t -replace '^\\SystemRoot\\', "$env:SystemRoot\" }
    }
    if (-not $path) { continue }
    if ((Get-Status $path) -eq 'missing') {
        $svcBad++
        W ("| ✗ 不存在 | {0} | {1} |" -f $k.PSChildName, $path)
        AddFinding '严重' '服务/驱动' ($k.PSPath -replace '.*Registry::','') $path ("服务 {0} 的程序已不存在（卸载残留）" -f $k.PSChildName) '确认服务已停用后删除该服务键'
    }
}
if ($svcBad -eq 0) { W '| ✓ | 全部服务 | ImagePath 均存在 |' }

# ============================================================================
Section '10. 启动项 / 快捷方式 / PATH'
# ============================================================================
$startBad = 0
W '**启动项**'
W ''
W '| 状态 | 位置 | 名称 | 指向 |'
W '|---|---|---|---|'
foreach ($r in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $item = Get-Item -LiteralPath $r
    foreach ($n in $item.GetValueNames()) {
        $raw = [string]$item.GetValue($n)
        $path = Get-FirstPath $raw
        if (-not $path) { continue }
        if ((Get-Status $path) -eq 'missing') {
            $startBad++
            W ("| ✗ 不存在 | {0} | {1} | {2} |" -f ($r -replace '.*CurrentVersion\\',''), $n, $path)
            AddFinding '警告' '启动项' ($r + ' :: ' + $n) $path '自启指向不存在的程序' '删除该启动项'
        }
    }
}
$sp = New-Object -ComObject WScript.Shell
$lnkBad = 0
W ''
W '**快捷方式**（开始菜单 / 桌面 / 发送到 / 任务栏）'
W ''
W '| 状态 | 位置 | 指向 |'
W '|---|---|---|---|'
$lnkRoots = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'),
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\SendTo'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
)
foreach ($r in $lnkRoots) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $r -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
        $t = ''
        try { $t = $sp.CreateShortcut($f.FullName).TargetPath } catch {}
        if (-not $t) { continue }
        if ((Get-Status $t) -eq 'missing') {
            $lnkBad++
            W ("| ✗ 不存在 | {0} | {1} |" -f $f.FullName.Replace($env:USERPROFILE,'~'), $t)
            AddFinding '警告' '快捷方式' $f.FullName $t '快捷方式指向不存在的目标' '删除或重新指向（若程序已迁移，改指新路径）'
        }
    }
}
if ($startBad -eq 0 -and $lnkBad -eq 0) { W ''; W '- ✓ 启动项与快捷方式目标均存在' }
$pathBad = 0
W ''
W '**PATH 环境变量里的目录**'
W ''
$envPath = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$parts = $envPath -split ';' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()) } | Sort-Object -Unique
foreach ($p in $parts) {
    if ((Get-Status $p) -eq 'missing') {
        $pathBad++
        W ("- ✗ {0}" -f $p)
        AddFinding '提示' 'PATH' 'PATH' $p '该目录不存在（多为卸载残留）' '可从 PATH 中移除'
    }
}
if ($pathBad -eq 0) { W '- ✓ PATH 中目录均存在' }

# ============================================================================
Section '11. 孤儿安装缓存（%LOCALAPPDATA%\Package Cache）'
# ============================================================================
$cacheRoot = Join-Path $env:LOCALAPPDATA 'Package Cache'
$installedGuids = @{}
foreach ($root in $unRoots) {
    foreach ($k in (Get-ChildItem -LiteralPath $root.PS -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -match '\{[0-9A-Fa-f\-]{36}\}') { $installedGuids[$matches[0].ToUpper()] = $true }
    }
}
$orphanBytes = 0; $orphanCount = 0
W ("对比 {0} 个已安装产品的 GUID 与缓存目录名：" -f $installedGuids.Count)
W ''
W '| 状态 | 缓存目录 | 大小 (MB) |'
W '|---|---|---|'
if (Test-Path -LiteralPath $cacheRoot) {
    foreach ($d in (Get-ChildItem -LiteralPath $cacheRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $guids = [regex]::Matches($d.Name, '\{[0-9A-Fa-f\-]{36}\}') | ForEach-Object { $_.Value.ToUpper() }
        $referenced = $false
        foreach ($g in $guids) { if ($installedGuids.ContainsKey($g)) { $referenced = $true } }
        if (-not $referenced -and $guids.Count -gt 0) {
            $sz = (Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $orphanBytes += $sz; $orphanCount++
            W ("| ⚠ 无产品引用 | {0} | {1:N1} |" -f $d.Name, ($sz/1MB))
            AddFinding '提示' '安装缓存' $d.FullName ("{0:N1} MB" -f ($sz/1MB)) '该缓存不再被任何已安装产品引用' '可安全删除以释放空间（当前产品的缓存请勿删除）'
        }
    }
}
if ($orphanCount -eq 0) { W '| ✓ | 无孤儿缓存 | — |' }
else { W ''; W ("**可释放合计约 {0:N1} MB**" -f ($orphanBytes/1MB)) }

# ============================================================================
Section '12. 旧路径残留扫描'
# ============================================================================
if ($SkipOldPathScan) {
    W '（本次已用 -SkipOldPathScan 跳过 —— **本节没有做任何检查**，不代表没有残留。）'
    AddFinding '提示' '体检范围' '-SkipOldPathScan' '旧路径残留扫描被跳过' '未执行检查' '报告里不体现旧路径残留；需要时去掉该开关重跑'
} else {
    if (-not (Test-Path -LiteralPath $needles)) {
        # 首次运行播种一份"清单模板"：**只含注释**，不含任何机器专属路径。
        # 注意：正因为只有注释，下面会判定为 empty 并明确报告"未执行有效检查"——这是刻意的。
        $defaultNeedles = @(
            '# 一行一个"旧路径"。体检时会全注册表搜索这些字符串，报告所有仍引用它们的键。',
            '# 首次运行自动生成。请把本机真实的历史路径填在下面（去掉行首的 # 才生效）。',
            '#',
            '# 例：改名前的用户目录 —— 最典型的失效根源，强烈建议填',
            '# C:\Users\<旧用户名>',
            '#',
            '# 例：迁移前程序所在的旧目录',
            '# D:\OldAppFolder',
            '# D:\Apps\Portable\<搬走前的旧名字>'
        )
        $defaultNeedles | Set-Content -LiteralPath $needles -Encoding $script:Enc
        W ("已生成清单文件：{0}" -f $needles)
    }
    $list  = @(Get-Content -LiteralPath $needles -Encoding UTF8 | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    $state = Get-NeedlesState $list
    if ($state -ne 'ok') {
        # 关键：清单为空或全是占位符时，旧实现会打印"✓ 回归检查通过"——那是最危险的假阴性，
        # 和 PS7 把"缺失"误判成"读不到"是同一类：报告说一切正常，其实根本没查。
        W ("⚠ **本节未执行有效检查**：清单{0}。" -f $(if ($state -eq 'empty') { '为空（文件里全是注释）' } else { '里全是占位符' }))
        W ''
        W ("清单文件：{0}" -f $needles)
        if ($list.Count -gt 0) {
            W ''
            W '当前清单内容（看起来都不是真实路径）：'
            foreach ($n in $list) { W ("- {0}" -f $n) }
        }
        W ''
        W '请按"一行一个"填入本机真实的历史路径，并去掉行首的 # ，然后重跑体检。'
        AddFinding '警告' '旧路径残留' $needles $(if ($state -eq 'empty') { '(清单为空)' } else { '(清单全是占位符)' }) '未执行有效检查' '填好清单后重跑；**不要**把本节当成"已确认无残留"'
    } else {
        $searchRoots = @(
            'HKCU\Software\Classes','HKLM\Software\Classes','HKLM\Software\WOW6432Node\Classes',
            'HKCU\Software\Microsoft\Windows\CurrentVersion','HKLM\Software\Microsoft\Windows\CurrentVersion'
        )
        W ("清单 {0} 条 × 根键 {1} 个；该步较慢（约 3~6 分钟），请耐心等待。" -f $list.Count, $searchRoots.Count)
        W ''
        W '本次搜索的路径：'
        foreach ($n in $list) { W ("- {0}" -f $n) }
        W ''
        $hits = @{}
        $i = 0
        foreach ($n in $list) {
            $i++
            Write-Host ("  [{0}/{1}] 搜索 {2} ..." -f $i, $list.Count, $n) -ForegroundColor DarkGray
            foreach ($root in $searchRoots) {
                $cur = ''
                foreach ($line in (& reg.exe query $root /f $n /s 2>$null)) {
                    if ($line -match '^(HKEY_[A-Z_]+)\\(.+)$') {
                        $cur = $matches[1] + '\' + $matches[2]
                        if ($line -match [regex]::Escape($n)) { $hits[$cur] = $n }
                    } elseif ($line -match [regex]::Escape($n) -and $cur) { $hits[$cur] = $n }
                }
            }
        }
        W ("命中 {0} 个键：" -f $hits.Count)
        W ''
        if ($hits.Count -eq 0) {
            W '✓ 注册表中已无这些旧路径的引用（回归检查通过）'
        } else {
            W '| 旧路径 | 仍引用的键 |'
            W '|---|---|'
            foreach ($k in ($hits.Keys | Sort-Object)) {
                W ("| {0} | {1} |" -f $hits[$k], ($k -replace '^HKEY_LOCAL_MACHINE','HKLM' -replace '^HKEY_CURRENT_USER','HKCU'))
                AddFinding '警告' '旧路径残留' $k $hits[$k] '注册表仍引用这个旧路径' '按"旧→新"映射改写；新位置不存在则删除该记录'
            }
        }
        # 文本配置扫描只在"清单可用"时有意义：清单为空时它会遍历 0 个关键词并打印
        # "- ✓ 未发现" —— 那是第二个假绿，所以放进这个分支里。
        if ($ScanConfigFiles) {
            W ''
            W '**文本配置里的旧路径**（扫描 D:\Apps 下的 conf/ini/json/properties/txt 等）'
            W ''
            $cfgRoot = 'D:\Apps'
            if (Test-Path -LiteralPath $cfgRoot) {
                $cand = Get-ChildItem -LiteralPath $cfgRoot -Recurse -File -ErrorAction SilentlyContinue -Include *.conf,*.ini,*.json,*.properties,*.cfg,*.yaml,*.yml,*.txt,*.bat,*.cmd,*.ps1 |
                        Where-Object { $_.Length -lt 1MB -and $_.FullName -notmatch '\\node_modules\\|\\\.git\\|\\cache\\|\\Cache\\' } |
                        Select-Object -First 3000
                $cfgHits = 0
                foreach ($f in $cand) {
                    foreach ($n in $list) {
                        if (Select-String -LiteralPath $f.FullName -SimpleMatch -Pattern $n -Quiet -ErrorAction SilentlyContinue) {
                            W ("- {0}  ← 含旧路径 {1}" -f $f.FullName, $n)
                            AddFinding '提示' '配置文件旧路径' $f.FullName $n '配置文件里写死了旧路径' '按需改成新路径（迁移后常被忽略）'
                            $cfgHits++
                        }
                    }
                }
                if ($cfgHits -eq 0) { W '- ✓ 未发现' }
            }
        }
    }
}

# ============================================================================
Section '13. 目录体积大户（%LOCALAPPDATA% / %APPDATA% 一级子目录）'
# ============================================================================
$topDirs = @{}
if (-not $SizeScan) {
    W '（默认跳过：这一步要递归统计几十万个文件，较慢。需要时加 `-SizeScan` 参数，或直接用你已有的 WizTree 看占用。）'
    W ''
    W '这两个目录常藏着"看不见的大户"（程序缓存/数据常常不跟程序走）：`%LOCALAPPDATA%`、`%APPDATA%`。'
} else {
    W '这两个目录常藏着"看不见的大户"（程序缓存/数据常常不跟程序走）。'
    W ''
    foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA)) {
        $rows = @()
        foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)) {
            Write-Host ("  统计 {0} ..." -f $d.FullName) -ForegroundColor DarkGray
            $sz = Get-DirBytes $d.FullName
            $rows += [pscustomobject]@{ Name=$d.Name; MB=[math]::Round($sz/1MB,1) }
        }
        $top = $rows | Sort-Object MB -Descending | Select-Object -First 15
        W ("**{0}**（合计 {1:N1} GB）" -f $base, (($rows | Measure-Object MB -Sum).Sum/1024))
        W ''
        W '| 子目录 | 大小 (MB) |'
        W '|---|---|'
        foreach ($t in $top) { W ("| {0} | {1} |" -f $t.Name, $t.MB) }
        W ''
        $topDirs[$base] = $top
    }
    if ($script:dirBytesSkipped -gt 0) {
        W ''
        W ("⚠ 有 {0} 个目录/文件读不到（权限或占用），其体积**未计入** —— 上面的合计偏低，不要当成准确值。" -f $script:dirBytesSkipped)
        AddFinding '提示' '目录体积' '(SizeScan)' ("{0} 个目录读不到" -f $script:dirBytesSkipped) '统计偏低' '需要准确数字时用 WizTree（它读 MFT，不受 ACL 影响）'
    }
}

# ============================================================================
Section '14. 结论与建议'
# ============================================================================
$critical = @($findings | Where-Object { $_.Severity -eq '严重' })
$warnings = @($findings | Where-Object { $_.Severity -eq '警告' })
$infos    = @($findings | Where-Object { $_.Severity -eq '提示' })
W ("- 严重（会影响功能，建议尽快处理）：**{0}** 项" -f $critical.Count)
W ("- 警告（不影响使用，值得清理）：**{0}** 项" -f $warnings.Count)
W ("- 提示（可选优化）：**{0}** 项" -f $infos.Count)
W ''
# 明细导出（全部条目，供逐条处理）
$csv = Join-Path $runDir 'findings.csv'
if ($findings.Count -gt 0) { $findings | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding $script:Enc }
if ($findings.Count -gt 0) {
    W '### 14.1 按"不存在的目标"聚合（同一目标的多个条目合并成一行）'
    W ''
    W '| 级别 | 类别 | 不存在的目标 | 影响项数 | 触发的登记位置（示例） | 说明 | 建议 |'
    W '|---|---|---|---|---|---|---|'
    $groups = $findings | Group-Object { "$($_.Severity)|$($_.Category)|$($_.Target)" } | Sort-Object `
        @{E={ switch (($_.Group[0].Severity)) { '严重' {0} '警告' {1} default {2} } }}, `
        @{E={ $_.Count }; Descending=$true}
    foreach ($g in $groups) {
        $f0 = $g.Group[0]
        $sample = ($g.Group | Select-Object -First 3 -ExpandProperty Location) -join ' ; '
        W ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $f0.Severity, $f0.Category, $f0.Target, $g.Count, $sample, $f0.Status, $f0.Hint)
    }
    W ''
    W ("完整逐条明细（{0} 条）：{1}" -f $findings.Count, $csv)
    W ''
    W '### 14.2 严重项逐条明细（最多 60 条，其余见 CSV）'
    W ''
    W '| 类别 | 位置 | 目标 | 说明 |'
    W '|---|---|---|---|'
    $n = 0
    foreach ($f in ($critical | Select-Object -First 60)) {
        W ("| {0} | {1} | {2} | {3} |" -f $f.Category, $f.Location, $f.Target, $f.Status)
        $n++
    }
    if ($critical.Count -gt $n) { W ("| … | 另有 {0} 条严重项 | 见 findings.csv | — |" -f ($critical.Count - $n)) }
} else {
    W '✓ 未发现任何问题。'
}
W ''
W '---'
W ''
W '**下一步怎么做**：'
W ''
W '1. 先处理"严重"项——它们直接影响"双击文件能不能打开、Win+R 能不能用、设置里能不能卸载"。'
W '2. 路径搬迁类的修复：把"旧路径 → 新路径"填进 `local\repair-migrated-apps.local.psd1`（模板见 `config\repair-migrated-apps.local.example.psd1`）。先试运行——`scripts\repair-migrated-apps.cmd` 不带参数就是试运行——确认输出无误后再加 `-Apply`。'
W '3. 注册表键"无法写入/拒绝访问"时的正确顺序：**夺取所有权 → 重建权限项 → 恢复完全控制 → 再修改**（不要用 `icacls /reset` 硬刷整棵树）。'
W '4. 文件被占用删不掉：用"重启时删除"队列，不要杀进程。'
W '5. 孤儿安装缓存确认后可删，当前版本的缓存请保留（卸载/修复要用）。'

# 收尾必须显式 flush：W() 只在缓冲区凑满 25 行时才落盘，章节边界由 Section() 负责。
# 少了这一句，报告最后一批内容（14.2 的明细表 + 上面这整段"下一步怎么做"）就**只出现在屏幕上、
# 永远不进 report.md** —— 而 report.md 才是用户会保存、转发、回头再读的那份文件。
# 实测（修复前）：report.md 停在 "### 14.2 严重项逐条明细" 那一行，屏幕上却看着是完整的。
Flush-Buf

# ---- 落盘（报告正文在运行过程中已逐行写入）--------------------------------
# 说明：W() 每写一行就 append 到 report.md，所以运行中可随时打开查看进度。

if (-not $NoHistory) {
    $driveMap = @{}
    foreach ($d in $drives) { $driveMap[$d.Drive] = @{ FreeGB=$d.FreeGB; TotalGB=$d.TotalGB; FreePct=$d.FreePct } }
    $snapshot = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        drives    = $driveMap
        findings  = @{ critical=$critical.Count; warning=$warnings.Count; info=$infos.Count }
        topDirs   = $topDirs
    }
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $histDir 'snapshot.json') -Encoding $script:Enc
    Copy-Item -LiteralPath (Join-Path $histDir 'snapshot.json') -Destination (Join-Path $runDir 'snapshot.json') -Force
}

Write-Host ''
Write-Host '================ 体检完成 ================' -ForegroundColor Green
Write-Host ("报告：{0}" -f $report)
Write-Host ("严重 {0} / 警告 {1} / 提示 {2}" -f $critical.Count, $warnings.Count, $infos.Count)
if ($critical.Count -gt 0) { exit 1 } else { exit 0 }
