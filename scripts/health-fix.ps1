# health-fix.ps1 -- 以提升权限运行，处理体检报告里的"严重/警告"项。
#   分工：能改路径的改路径（程序搬走了）；确认没了的删记录（含引用清理）。
#   每条改动前 reg export 到 <repo>\local\rollback\<运行时间戳>\；备份失败即放弃该条改动（绝不裸改）。
#   受保护键按"夺取所有权 → 清拒绝项 → 授权 → 再改"。默认试运行；-Apply 才写入（需要管理员）。
#   机器专属值（旧用户目录名、路径改指表）不写死在本文件里，改由 local\health-fix.local.psd1 提供。
#   结尾打印每段计数（防止"整段静默跳过"这种事故）。
[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Continue'

# -Apply 要写 HKLM/HKCU：没有管理员权限就明确报错退出，而不是逐条失败刷屏
if ($Apply) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Output 'ERROR: -Apply 需要管理员权限。请用 health-fix.cmd -Apply，或从已提权的窗口运行。'; exit 2 }
}

# ---- engine adaption (works on 5.1 and 7.x) ----
$script:PSName = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$script:Enc = if ($PSVersionTable.PSVersion.Major -ge 7) { 'utf8BOM' } else { 'UTF8' }

# ============================================================================
#  机器专属配置不写死在本文件里
#  真值放在 <repo>\local\health-fix.local.psd1（该目录已被 .gitignore 排除，永不进仓库）。
#  文件不存在时用空默认值——脚本仍可运行，只是本机专属规则（旧用户目录名、路径改指表）不生效。
#  键名与写法见 config\health-fix.local.example.psd1。
# ============================================================================
# 备份与日志的输出位置：默认放在"仓库根/local/"下（该目录已被 .gitignore 排除）
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
if (-not (Test-Path (Join-Path $RepoRoot 'scripts'))) { $RepoRoot = $ScriptDir }   # 单独放置时退化为脚本目录
$OutBase   = Join-Path $RepoRoot 'local'

$script:CfgPath = Join-Path $OutBase 'health-fix.local.psd1'
$script:Cfg = $null
if (Test-Path -LiteralPath $script:CfgPath) {
    # Import-PowerShellDataFile 只读数据、不执行代码，5.1 与 7.x 都可用
    $script:Cfg = Import-PowerShellDataFile -LiteralPath $script:CfgPath
} else {
    Write-Output ("提示：未找到 {0} —— 本机专属规则将不生效（正常：该文件属于本机，不进仓库）。" -f $script:CfgPath)
}

# 改名前的用户目录名（没改过用户目录名就留空）。
# 相关规则：把指向这个旧目录的死记录/服务路径改成当前用户的路径或直接清理。
$OldProfileName = if ($script:Cfg -and $script:Cfg.OldProfileName) { [string]$script:Cfg.OldProfileName } else { '' }
# ============================================================================

$oldProfPrefix = if ($OldProfileName) { "C:\Users\$OldProfileName" } else { '' }
$root     = $OutBase
$rollback = Join-Path $root 'rollback'
$log      = Join-Path $root 'health-fix-log.txt'
if (-not (Test-Path $rollback)) { New-Item -ItemType Directory -Path $rollback -Force | Out-Null }
Set-Content -LiteralPath $log -Value ("=== health-fix round2 {0}  mode={1}  engine={2} ===" -f (Get-Date), $(if ($Apply) { 'APPLY' } else { 'DRY RUN' }), $script:PSName) -Encoding $script:Enc
function Say($m) { Write-Output $m; Add-Content -LiteralPath $log -Value $m -Encoding $script:Enc }
$script:stat = [ordered]@{ '改路径'=0; '删键'=0; '删值'=0; '跳过'=0; '引用清理'=0 }

$me = New-Object System.Security.Principal.NTAccount($env:USERNAME)
$clsRoots = @('HKCU:\Software\Classes','HKLM:\Software\Classes','HKLM:\Software\Classes\WOW6432Node')

function Open-RegKey([string]$psPath, [bool]$writable = $false) {
    $base = [Microsoft.Win32.Registry]::CurrentUser
    if ($psPath -like 'HK*' -and $psPath -notlike 'HKCU*') { $base = [Microsoft.Win32.Registry]::LocalMachine }
    $sub = $psPath -replace '^HK[A-Z]+:\\',''
    try { return $base.OpenSubKey($sub, $writable) } catch { return $null }
}
# 关键：这个函数上一轮忘了定义，导致用到它的整段逻辑静默跳过
function Get-RegValue([string]$psPath, [string]$name = '') {
    $rk = Open-RegKey $psPath
    if (-not $rk) { return $null }
    try { return $rk.GetValue($name) } finally { $rk.Close() }
}
# 某个 ProgID 是否在任何一处 Classes 根下注册（用于"目标 ProgID 是否真的存在"的前置判断）
function Test-ProgIdRegistered([string]$progId) {
    if (-not $progId) { return $false }
    foreach ($r in $clsRoots) { if (Test-Path -LiteralPath ($r + '\' + $progId)) { return $true } }
    return $false
}
# 每次运行一个子目录：第二次跑 -Apply 时，绝不会用"已改过的状态"覆盖第一次的原始备份。
$script:RunStamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:backupTried = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:backupOk    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# 返回 $true = 可以安全改动（试运行恒为 $true）；$false = 备份失败，调用方必须放弃这次改动。
# 同一个键重复调用只导出一次（结果被记住），所以调用方可以在每次写入前无条件调用它。
function Backup-Key([string]$psPath) {
    $reg = ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::','') -replace '^HKLM:','HKLM' -replace '^HKCU:','HKCU'
    if (-not $Apply) { return $true }
    if ($script:backupTried.Contains($reg)) { return $script:backupOk.Contains($reg) }
    [void]$script:backupTried.Add($reg)
    $dir = Join-Path $rollback $script:RunStamp
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $f = Join-Path $dir (($reg -replace '[\\:*?"<>|]','_') + '.reg')
    & reg.exe export $reg $f /y | Out-Null
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -lt 64) {
        # ⚠ 必须用 $null = 接住 Say：Say 走的是 **success stream**，不接住就会混进本函数的返回值，
        # 变成 @('<日志文本>', $false)。而调用方写的是 if (-not (Backup-Key ...)) ——
        # 对**非空数组**求值为真，于是"备份失败"被判成"备份成功"，改动照做而且没有备份。
        # 这不是理论风险：曾经就是这个写法，`Del-Value` 在备份失败时照样把值删了。
        $null = Say ("  !! 备份失败（reg export 退出码 {0}），该键不做任何改动：{1}" -f $code, $reg)
        return $false
    }
    [void]$script:backupOk.Add($reg)
    return $true
}
function Fix-Acl([string]$psPath) {
    $base = [Microsoft.Win32.Registry]::CurrentUser
    if ($psPath -like 'HK*' -and $psPath -notlike 'HKCU*') { $base = [Microsoft.Win32.Registry]::LocalMachine }
    $sub = $psPath -replace '^HK[A-Z]+:\\',''
    try {
        $k = $base.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($k) { $acl = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access); $acl.SetOwner($me); $k.SetAccessControl($acl); $k.Close() }
        $k2 = $base.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($k2) {
            $a = $k2.GetAccessControl('Access')
            foreach ($d in @($a.Access | Where-Object { $_.AccessControlType -eq 'Deny' })) { [void]$a.RemoveAccessRule($d) }
            $a.SetAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($me, [System.Security.AccessControl.RegistryRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
            $k2.SetAccessControl($a); $k2.Close()
        }
    } catch { Say ("    (权限修复异常: {0})" -f $_.Exception.Message) }
}
function Del-Key([string]$psPath, [string]$why = '') {
    if (-not (Test-Path -LiteralPath $psPath)) { return }
    if (-not (Backup-Key $psPath)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未删除：{0}" -f $psPath); return }
    if ($Apply) {
        Remove-Item -LiteralPath $psPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $psPath) { Fix-Acl $psPath; Remove-Item -LiteralPath $psPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $script:stat['删键']++
    Say ("  [删键] {0}  ({1}){2}" -f ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::',''), $why, $(if ($Apply -and (Test-Path -LiteralPath $psPath)) { '  !! 仍存在' } else { '' }))
}
function Del-Value([string]$psPath, [string]$valueName, [string]$why = '') {
    if (-not (Backup-Key $psPath)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未删除：{0}" -f $psPath); return }
    $rk = Open-RegKey $psPath $true
    if (-not $rk) { return }
    if ($Apply) {
        try { $rk.DeleteValue($valueName) }
        catch {
            # 多半是权限：修一次 ACL 再试；仍然失败就放弃 —— 但下面会回读校验，不会谎报删掉了
            Fix-Acl $psPath
            $r2 = Open-RegKey $psPath $true
            if ($r2) { try { $r2.DeleteValue($valueName) } catch {}; $r2.Close() }  # 第二次仍失败就放弃；下面的回读校验会如实报告（不谎报删掉了）
        }
    }
    $rk.Close()
    # 回读校验：值还在就如实写出来。读不到也按"还在"算 —— 读不到时没有资格声称删掉了
    # （Del-Key 早就是这么做的，Del-Value 之前只报"尝试过"）。
    $still = $null
    if ($Apply) { $still = Get-RegValue $psPath $valueName }
    $script:stat['删值']++
    Say ("  [删值] {0} [{1}]  ({2}){3}" -f ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::',''), $(if ($valueName) { $valueName } else { '(default)' }), $why, $(if ($Apply -and $null -ne $still) { '  !! 值仍在（未删掉）' } else { '' }))
}
function Set-Text([string]$psPath, [string]$valueName, [string]$old, [string]$new, [string]$why = '') {
    $cur = [string](Get-RegValue $psPath $valueName)
    if (-not $cur -or $cur -notlike "*$old*") { return }
    $fixed = $cur.Replace($old, $new)
    if (-not (Backup-Key $psPath)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未改写：{0}" -f $psPath); return }
    if ($Apply) { $w = Open-RegKey $psPath $true; if ($w) { $w.SetValue($valueName, $fixed); $w.Close() } }
    $script:stat['改路径']++
    Say ("  [改路径] {0} [{1}]`n           {2}`n        -> {3}   ({4})" -f ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::',''), $(if ($valueName) { $valueName } else { '(default)' }), $cur, $fixed, $why)
}
function Get-ExeFrom([string]$s) { return ([regex]::Match([string]$s, '([A-Za-z]:\\[^"|]+?\.(?:exe|dll|ico|sys))', 'IgnoreCase')).Groups[1].Value }
# 执行 .NET 调用：成功返回 $null，失败返回最内层异常类型名。
# 必须解包 InnerException —— PS7(.NET Core) 把 .NET 异常包成 MethodInvocationException /
# RuntimeException，`catch [System.IO.FileNotFoundException]` 在 PS7 里永远匹配不上。
function Get-ExceptionClass([scriptblock]$sb) {
    try { & $sb; return $null }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        return $ex.GetType().Name
    }
}
function Test-Missing([string]$p) {
    if (-not $p) { return $false }
    if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $false }
    $cls = Get-ExceptionClass { [void][System.IO.File]::GetAttributes($p) }
    if (-not $cls) { return $false }
    # 读不到 ≠ 不存在：此时绝不能删（避免把权限问题当残留清掉）
    if ($cls -in 'UnauthorizedAccessException','SecurityException') { return $false }
    if ([System.IO.Path]::GetExtension($p) -eq '' -and (Test-Path -LiteralPath ($p + '.exe') -ErrorAction SilentlyContinue)) { return $false }
    if ($cls -in 'FileNotFoundException','DirectoryNotFoundException') { return $true }
    $cls2 = Get-ExceptionClass { [void][System.IO.Directory]::GetAttributes($p) }
    if (-not $cls2) { return $false }
    if ($cls2 -in 'FileNotFoundException','DirectoryNotFoundException','IOException','ArgumentException','NotSupportedException') { return $true }
    return $false
}

# ============================================================================
#  A~D 各段的分工：
#    A 段 = "旧路径 -> 新路径"的改指（程序还在，只是搬走了）——数据来自 local\health-fix.local.psd1
#    B 段 = 确认已卸载的软件留下的记录/服务/协议
#    C/D 段 = 通用清理（目标已不存在的 ProgID、悬空引用），一般不用改
#  规则判据统一是：目标文件"确实不存在"（Test-Missing）才动手；"读不到"一律跳过。
#  历史教训：B1/B2 曾经无条件删除整族 ProgID（只凭"这台机器上它已卸载"这句注释），
#  在仍装着该软件的机器上会直接清掉文件关联 —— 现在一律走 Remove-DeadVendorKey 门禁。
# ============================================================================
Say '########## A. 改路径 ##########'
# 改指表来自 local\health-fix.local.psd1 的 Repoint 数组（机器专属，不进仓库）。
# 每条：Path（注册表键的 PowerShell 路径）、ValueName（'' = 默认值）、Old、New、Why。
$repoint = if ($script:Cfg -and $script:Cfg.Repoint) { @($script:Cfg.Repoint) } else { @() }
foreach ($x in $repoint) {
    Set-Text ([string]$x.Path) ([string]$x.ValueName) ([string]$x.Old) ([string]$x.New) ([string]$x.Why)
}
if (@($repoint).Count -eq 0) { Say '  （本地配置未提供 Repoint，跳过本段）' }
# 只有当 txtfile 真的不存在（本机那种情况）且 txtfilelegacy 存在时才改指。
# 原实现只检查 txtfilelegacy 存在，从不检查 txtfile —— 正常机器上 txtfile 是好的，会被无谓改坏。
foreach ($e in '.dic','.exc','.gitattributes') {
    $k = "HKLM:\Software\Classes\$e"
    if ((Get-RegValue $k '') -ne 'txtfile') { continue }
    if (Test-ProgIdRegistered 'txtfile') { $script:stat['跳过']++; Say ("  [跳过] {0}: txtfile 存在，无需改指" -f $e); continue }
    if (-not (Test-ProgIdRegistered 'txtfilelegacy')) { $script:stat['跳过']++; Say ("  [跳过] {0}: txtfile 缺失，但 txtfilelegacy 也不存在" -f $e); continue }
    if (-not (Backup-Key $k)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败：{0}" -f $k); continue }
    if ($Apply) { $w = Open-RegKey $k $true; if ($w) { $w.SetValue('', 'txtfilelegacy'); $w.Close() } }
    $script:stat['改路径']++; Say ("  [改路径] {0}: txtfile（不存在）-> txtfilelegacy" -f $e)
}
# 只在"Acrobat 的处理程序确实已死"且"目标 ProgID 真的存在"时才改指。
# 原实现无任何前置判断：默认值只要是 Acrobat* 就改成 MSEdgePDF，会把仍装着 Acrobat 的机器 PDF 关联抢给 Edge。
foreach ($k in 'HKCU:\Software\Classes\.pdf','HKLM:\Software\Classes\.pdf') {
    $cur = [string](Get-RegValue $k '')
    if (-not $cur) { continue }
    if ($cur -notlike 'Acrobat*') { continue }
    $acrExe = ''
    foreach ($cr in $clsRoots) {
        $acrExe = Get-ExeFrom ([string](Get-RegValue ($cr + '\' + $cur + '\shell\open\command')))
        if ($acrExe) { break }
    }
    if ($acrExe -and -not (Test-Missing $acrExe)) { $script:stat['跳过']++; Say ("  [跳过] {0}: {1} 仍指向存在的程序（{2}）" -f $k, $cur, $acrExe); continue }
    if (-not (Test-ProgIdRegistered 'MSEdgePDF')) { $script:stat['跳过']++; Say ("  [跳过] {0}: {1} 已失效，但 MSEdgePDF 不存在，不写入另一个死值" -f $k, $cur); continue }
    if (-not (Backup-Key $k)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败：{0}" -f $k); continue }
    if ($Apply) { $w = Open-RegKey $k $true; if ($w) { $w.SetValue('', 'MSEdgePDF'); $w.Close() } }
    $script:stat['改路径']++; Say ("  [改路径] {0}: {1} -> MSEdgePDF（Acrobat 目标已不存在）" -f $k, $cur)
}

Say ''
Say '########## B. 删除残留 ##########'
# 厂商残留的统一判据：命令/图标的目标"确实不存在"（Test-Missing）才删。
# 取不到目标路径 = 不能证明它死了 = 跳过（宁可留下，也不误删仍装着该软件的机器上的关联）。
function Remove-DeadVendorKey([string]$psPath, [string]$vendor) {
    $tgt = Get-ExeFrom ([string](Get-RegValue ($psPath + '\shell\open\command')))
    if (-not $tgt) { $tgt = Get-ExeFrom ([string](Get-RegValue ($psPath + '\DefaultIcon'))) }
    if (-not $tgt) { $script:stat['跳过']++; Say ("  [跳过] {0}：{1} —— 无命令/图标路径，无法证明已卸载" -f $psPath, $vendor); return }
    if (Test-Missing $tgt) { Del-Key $psPath ("{0} 残留（目标不存在：{1}）" -f $vendor, $tgt) }
    else { $script:stat['跳过']++; Say ("  [跳过] {0}：目标仍存在（{1}）" -f $psPath, $tgt) }
}
# B1 WPS 全家（含上轮漏掉的 KET/KSO 前缀）+ Word/Excel 图标覆盖
$wpsPat = '^(WPS|ET|WPP|KWPS|KWPP|KET|KSO)(\.|$)'
foreach ($r in $clsRoots) {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames() | Where-Object { $_ -match $wpsPat -or $_ -match '^(Word|Excel|PowerPoint)\.' })
    $b.Close()
    foreach ($n in $names) {
        $k = $r + '\' + $n
        if ($n -match $wpsPat) { Remove-DeadVendorKey $k 'WPS'; continue }
        $cmd = [string](Get-RegValue ($k + '\shell\open\command'))
        $ico = [string](Get-RegValue ($k + '\DefaultIcon'))
        if ($cmd -match 'Kingsoft|wps\.exe') { Del-Key $k '该 ProgID 的打开命令指向已删除的 WPS' }
        elseif ($ico -match 'Kingsoft') { Del-Value ($k + '\DefaultIcon') '' '图标被 WPS 覆盖（其 DLL 已删除）' }
    }
}
# B2 Adobe / PotPlayer 等确认已卸载的厂商 ProgID
foreach ($r in $clsRoots) {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames() | Where-Object { $_ -match '^(Photoshop|Acrobat|FormsCentral|PotPlayer)' })
    $b.Close()
    foreach ($n in $names) { Remove-DeadVendorKey ($r + '\' + $n) 'Adobe/PotPlayer' }
}
foreach ($r in 'HKCU:\Software\Classes\Applications','HKLM:\Software\Classes\Applications','HKLM:\Software\Classes\WOW6432Node\Applications') {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames() | Where-Object { $_ -match '^(Photoshop|Acrobat|photolaunch|PotPlayer|BCUT)' })
    $b.Close()
    foreach ($n in $names) { Remove-DeadVendorKey ($r + '\' + $n) 'Adobe/PotPlayer(Applications)' }
}
# B3 协议
$protos = 'lmstudio','smartdrive','game','unityhub','tuanjiehub','com.unity3d.kharma','mongodb','mongodb+srv','qsdis','vega','videocut'
foreach ($r in 'HKCU:\Software\Classes','HKLM:\Software\Classes','HKLM:\Software\Classes\WOW6432Node') {
    foreach ($p in $protos) {
        $k = $r + '\' + $p
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $exe = Get-ExeFrom ([string](Get-RegValue ($k + '\shell\open\command')))
        if (Test-Missing $exe) { Del-Key $k ("协议目标不存在：{0}" -f $exe) } else { $script:stat['跳过']++; Say ("  [跳过] {0}：协议目标仍存在（{1}）" -f $k, $exe) }
    }
}
# B4 App Paths
foreach ($ap in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths') {
    $b = Open-RegKey $ap; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames()); $b.Close()
    foreach ($n in $names) {
        $k = $ap + '\' + $n
        $exe = Get-ExeFrom ([string](Get-RegValue $k ''))
        if (Test-Missing $exe) { Del-Key $k ("目标不存在：{0}" -f $exe) } else { $script:stat['跳过']++; Say ("  [跳过] {0}：目标仍存在（{1}）" -f $k, $exe) }
    }
}
# B5 死服务（服务键受保护，必须用 Get-ItemProperty 读）
foreach ($s in 'Clash Core Service','FlashCenterSvc','SysCleanProService','XtuService') {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (-not (Test-Path -LiteralPath $k)) { continue }
    $img = [string](Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).ImagePath
    if (-not $img) { $script:stat['跳过']++; Say ("  [跳过] {0}：读不到 ImagePath" -f $s); continue }
    $exe = Get-ExeFrom $img
    if (Test-Missing $exe) { Del-Key $k ("服务程序不存在：{0}" -f $exe) } else { $script:stat['跳过']++; Say ("  [跳过] {0}：服务程序仍存在（{1}）" -f $k, $exe) }
}
# B6 失效卸载记录
$unRoots = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
foreach ($un in $unRoots) {
    $b = Open-RegKey $un; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames()); $b.Close()
    foreach ($n in $names) {
        $k = $un + '\' + $n
        $rk = Open-RegKey $k; if (-not $rk) { continue }
        $dn  = [string]$rk.GetValue('DisplayName')
        $all = (@('InstallLocation','DisplayIcon','UninstallString','QuietUninstallString','ModifyPath','Inno Setup: App Path') | ForEach-Object { [string]$rk.GetValue($_) }) -join '|'
        $rk.Close()
        if ($oldProfPrefix -and $dn -match 'JetBrains Toolbox|IntelliJ IDEA' -and $all -like "*$oldProfPrefix*") { Del-Key $k ("旧用户目录的 JetBrains 记录：{0}" -f $dn); continue }
        # 通用规则：记录引用的路径落在"已不存在的旧用户目录"下 → 死记录（覆盖 360se6 / JetBrains 等剩余项）
        if ($oldProfPrefix) {
            $oldProf = ([regex]::Match($all, "($([regex]::Escape($oldProfPrefix))\\[^|`"]+)")).Groups[1].Value
            if ($oldProf -and (Test-Missing $oldProf)) { Del-Key $k ("引用已不存在的旧用户目录：{0}" -f $dn); continue }
        }
        if ($dn -match 'REDlauncher' -or $dn -match 'STEAMBIG') {
            if (Test-Missing (Get-ExeFrom $all)) { Del-Key $k ("已卸载且卸载器不存在：{0}" -f $dn) }
        }
        # 明确已卸载的软件留下的记录（程序本体已不存在）→ 删除记录。
        # 注意：Steam / ACE(游戏反作弊) 这类由各自启动器自我维护，**不动**（删了会被重建，且可能影响游戏）
        if ($n -match '^Steam App' -or $dn -match 'AntiCheat|Steam') { $script:stat['跳过']++; Say ("  [跳过] {0}：Steam / 反作弊由启动器自我维护，不动" -f $k); continue }
        if ($dn -match 'Photoshop|Adobe') {
            # Adobe 的记录要用两个条件同时成立才算"死"：安装目录没了 且 卸载器也没了
            $instLoc = [string](Get-RegValue $k 'InstallLocation')
            $unExe   = Get-ExeFrom ([string](Get-RegValue $k 'UninstallString'))
            if ((Test-Missing $instLoc) -and (Test-Missing $unExe)) { Del-Key $k ("Adobe 组件已卸载：{0}" -f $dn) }
            else { $script:stat['跳过']++; Say ("  [跳过] {0}：Adobe 组件半残留，保守保留" -f $k) }
            continue
        }
        if ($dn -match 'Java\(TM\) SE|Java SE Development Kit|Free Download Manager') {
            if (Test-Missing (Get-ExeFrom $all)) { Del-Key $k ("程序已卸载，记录失效：{0}" -f $dn) }
        }
    }
}

Say ''
Say '########## C. 通用清理：目标已不存在的 ProgID + 失效引用 ##########'
$neverTouch = '^(Microsoft|Windows|System|Application\.|AppX|ms-|CLSID|Directory|Drive|Folder|AllFilesystemObjects|lnkfile|txtfile|htmlfile|MSEdge|http|https|ftp|mailto|shell|Word\.|Excel\.|PowerPoint\.|Diagnostic\.|InternetShortcut|piffile|batfile|cmdfile|exefile|regfile|scrfile|Unknown|\*$)'
$deadProgIds = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
foreach ($r in $clsRoots) {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames() | Where-Object { $_ -notlike '.*' -and $_ -notmatch $neverTouch })
    $b.Close()
    foreach ($n in $names) {
        $k = $r + '\' + $n
        $exe = Get-ExeFrom ([string](Get-RegValue ($k + '\shell\open\command')))
        if (-not $exe) { $exe = Get-ExeFrom ([string](Get-RegValue ($k + '\DefaultIcon'))) }
        if ($exe -and (Test-Missing $exe)) {
            Del-Key $k ("ProgID 指向已不存在的程序：{0}" -f $exe)
            [void]$deadProgIds.Add($n)
        }
    }
}
Say ("  已处理 ProgID {0} 个，开始清理引用…" -f $deadProgIds.Count)
$refFixed = 0
foreach ($r in $clsRoots) {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $exts = @($b.GetSubKeyNames() | Where-Object { $_ -like '.*' }); $b.Close()
    foreach ($ext in $exts) {
        $k = $r + '\' + $ext
        $rk = Open-RegKey $k $true
        if ($rk) {
            foreach ($vn in @($rk.GetValueNames())) {
                $v = [string]$rk.GetValue($vn)
                if ($v -and $deadProgIds.Contains($v)) {
                    if (-not (Backup-Key $k)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未清引用：{0}" -f $k); continue }
                    if ($Apply) { try { $rk.DeleteValue($vn) } catch {} }  # 删不掉不中断；这里**不校验**结果 —— $refFixed 记的是"尝试过"（要修它，先把这个内联块抽成可测函数）
                    Say ("  [引用] {0} [{1}] = {2}" -f $ext, $(if ($vn) { $vn } else { 'default' }), $v); $refFixed++
                }
            }
            $ico = [string]$rk.GetValue('DefaultIcon')
            $icoFile = Get-ExeFrom $ico
            if ($icoFile -and (Test-Missing $icoFile)) {
                if (-not (Backup-Key $k)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未清图标：{0}" -f $k) }
                else { if ($Apply) { try { $rk.DeleteValue('DefaultIcon') } catch {} }; Say ("  [图标] {0}\DefaultIcon = {1}（文件不存在）" -f $ext, $ico); $refFixed++ }  # 同上：DefaultIcon 删不掉也照报 [图标]
            }
            $rk.Close()
        }
        foreach ($sub in 'OpenWithProgids','OpenWithList') {
            $sk = Open-RegKey ($k + '\' + $sub) $true
            if (-not $sk) { continue }
            foreach ($vn in @($sk.GetValueNames())) {
                $v = [string]$sk.GetValue($vn)
                $cand = if ($v) { $v } else { $vn }
                if ($cand -and $deadProgIds.Contains($cand)) {
                    if (-not (Backup-Key $k)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未清引用：{0}\{1}" -f $ext, $sub); continue }
                    if ($Apply) { try { $sk.DeleteValue($vn) } catch {} }  # 删不掉不中断；这里不校验结果 —— $refFixed 记的是"尝试过"
                    Say ("  [引用] {0}\{1} [{2}] = {3}" -f $ext, $sub, $vn, $v); $refFixed++
                }
            }
            $sk.Close()
        }
    }
}
$script:stat['引用清理'] = $refFixed

Say ''
Say '########## C2. 非扩展名的"类型键"图标覆盖（如 htmlfile 被 360 改成自己的 exe）##########'
# 360 当年把 htmlfile 的 DefaultIcon 指到自己的 360se.exe；卸载后图标就坏了 → 删掉覆盖值，回落系统图标
foreach ($tk in 'htmlfile','MSEdgeHTM','MSEdgePDF') {
    foreach ($r in $clsRoots) {
        $k = $r + '\' + $tk
        $ico = [string](Get-RegValue ($k + '\DefaultIcon'))
        if (-not $ico) { continue }
        $icoFile = Get-ExeFrom $ico
        if ($icoFile -and (Test-Missing $icoFile)) {
            Del-Value ($k + '\DefaultIcon') '' ("{0} 的图标被已卸载程序覆盖：{1}" -f $tk, $icoFile)
        }
    }
}

Say ''
Say '########## D. 清理指向"根本不存在的 ProgID"的引用 ##########'
# 有些扩展名的默认值指向一个从未注册（或已被删）的 ProgID，例如 .snk -> VisualStudio.snk.ad31884e。
# 这类既不在现存 ProgID 集合、也不在"刚删掉的"集合里，前面几段抓不到。
$allProg = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($r in $clsRoots) { $b = Open-RegKey $r; if (-not $b) { continue }; foreach ($n in $b.GetSubKeyNames()) { [void]$allProg.Add($n) }; $b.Close() }
Say ("  现存 ProgID 索引：{0} 个" -f $allProg.Count)
$dFixed = 0
foreach ($r in $clsRoots) {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $exts = @($b.GetSubKeyNames() | Where-Object { $_ -like '.*' }); $b.Close()
    foreach ($ext in $exts) {
        $k = $r + '\' + $ext
        $rk = Open-RegKey $k $true
        if ($rk) {
            $dv = [string]$rk.GetValue('')
            # 括号是必需的：-and 比 -or 结合得紧，原来靠优先级侥幸成立
            if ($dv -and (((-not $allProg.Contains($dv)) -and ($dv -notmatch '^(AppX|Microsoft|Windows)')) -or ($dv -eq 'Microsoft Email Message'))) {
                if (-not (Backup-Key $k)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未改默认值：{0}" -f $k) }
                else {
                    if ($dv -eq 'txtfile' -and (Test-ProgIdRegistered 'txtfilelegacy')) {   # 本机 txtfile 缺失，指到 txtfilelegacy 更合适
                        if ($Apply) { $rk.SetValue('', 'txtfilelegacy') }
                        Say ("  [改路径] {0}: txtfile -> txtfilelegacy" -f $ext)
                    } else {
                        if ($Apply) { try { $rk.DeleteValue('') } catch {} }  # 删不掉不中断；不校验结果 —— $dFixed 记的是"尝试过"
                        Say ("  [悬空默认值] {0} = {1}" -f $ext, $dv)
                    }
                    $dFixed++
                }
            }
            $rk.Close()
        }
        $sk = Open-RegKey ($k + '\OpenWithProgids') $true
        if ($sk) {
            foreach ($vn in @($sk.GetValueNames())) {
                $v = [string]$sk.GetValue($vn)
                $cand = if ($v) { $v } else { $vn }
                if ($cand -and -not $allProg.Contains($cand) -and $cand -notmatch '^AppX') {
                    if (-not (Backup-Key $k)) { $script:stat['跳过']++; Say ("  [跳过] 备份失败，未清悬空引用：{0}" -f $k); continue }
                    if ($Apply) { try { $sk.DeleteValue($vn) } catch {} }  # 同上：悬空引用删不掉也照报 [悬空打开方式]
                    Say ("  [悬空打开方式] {0}\OpenWithProgids [{1}]" -f $ext, $cand)
                    $dFixed++
                }
            }
            $sk.Close()
        }
    }
}
$script:stat['悬空引用'] = $dFixed

Say ''
Say '########## 统计 ##########'
foreach ($kv in $script:stat.GetEnumerator()) { Say ("  {0,-8}: {1}" -f $kv.Key, $kv.Value) }
Say ("模式: {0}   日志: {1}" -f $(if ($Apply) { '已写入' } else { '试运行（未修改）' }), $log)
