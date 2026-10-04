# health-fix.ps1 -- 以提升权限运行，处理体检报告里的"严重/警告"项。
#   分工：能改路径的改路径（程序搬走了）；确认没了的删记录（含引用清理）。
#   每条改动前 reg export 到 rollback\；受保护键按"夺取所有权 → 清拒绝项 → 授权 → 再改"。
#   默认试运行；-Apply 才写入。结尾打印每段计数（防止"整段静默跳过"这种事故）。
[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Continue'
$root     = '<工作区>'
$rollback = Join-Path $root 'rollback'
$log      = Join-Path $root 'health-fix-log.txt'
if (-not (Test-Path $rollback)) { New-Item -ItemType Directory -Path $rollback -Force | Out-Null }
Set-Content -LiteralPath $log -Value ("=== health-fix round2 {0}  mode={1} ===" -f (Get-Date), $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })) -Encoding UTF8
function Say($m) { Write-Output $m; Add-Content -LiteralPath $log -Value $m -Encoding UTF8 }
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
function Backup-Key([string]$psPath) {
    $reg = ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::','') -replace '^HKLM:','HKLM' -replace '^HKCU:','HKCU'
    $f = Join-Path $rollback (($reg -replace '[\\:*?"<>|]','_') + '.reg')
    if ($Apply) { & reg.exe export $reg $f /y | Out-Null }
    return $f
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
    Backup-Key $psPath | Out-Null
    if ($Apply) {
        Remove-Item -LiteralPath $psPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $psPath) { Fix-Acl $psPath; Remove-Item -LiteralPath $psPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $script:stat['删键']++
    Say ("  [删键] {0}  ({1}){2}" -f ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::',''), $why, $(if ($Apply -and (Test-Path -LiteralPath $psPath)) { '  !! 仍存在' } else { '' }))
}
function Del-Value([string]$psPath, [string]$valueName, [string]$why = '') {
    $rk = Open-RegKey $psPath $true
    if (-not $rk) { return }
    Backup-Key $psPath | Out-Null
    if ($Apply) { try { $rk.DeleteValue($valueName) } catch { Fix-Acl $psPath; $r2 = Open-RegKey $psPath $true; if ($r2) { try { $r2.DeleteValue($valueName) } catch {}; $r2.Close() } } }
    $rk.Close()
    $script:stat['删值']++
    Say ("  [删值] {0} [{1}]  ({2})" -f ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::',''), $(if ($valueName) { $valueName } else { '(default)' }), $why)
}
function Set-Text([string]$psPath, [string]$valueName, [string]$old, [string]$new, [string]$why = '') {
    $cur = [string](Get-RegValue $psPath $valueName)
    if (-not $cur -or $cur -notlike "*$old*") { return }
    $fixed = $cur.Replace($old, $new)
    Backup-Key $psPath | Out-Null
    if ($Apply) { $w = Open-RegKey $psPath $true; if ($w) { $w.SetValue($valueName, $fixed); $w.Close() } }
    $script:stat['改路径']++
    Say ("  [改路径] {0} [{1}]`n           {2}`n        -> {3}   ({4})" -f ($psPath -replace 'Microsoft\.PowerShell\.Core\\Registry::',''), $(if ($valueName) { $valueName } else { '(default)' }), $cur, $fixed, $why)
}
function Get-ExeFrom([string]$s) { return ([regex]::Match([string]$s, '([A-Za-z]:\\[^"]+?\.(?:exe|dll|ico|sys))', 'IgnoreCase')).Groups[1].Value }
function Test-Missing([string]$p) {
    if (-not $p) { return $false }
    if (Test-Path -LiteralPath $p) { return $false }
    try { [void][System.IO.File]::GetAttributes($p); return $false } catch {}
    try { [void][System.IO.Directory]::GetAttributes($p); return $false }
    catch [System.IO.DirectoryNotFoundException] { return $true }
    catch [System.IO.FileNotFoundException] { return $true }
    catch { return $false }
}

Say '########## A. 改路径 ##########'
$repoint = @(
    @{ P='HKCU:\Software\Classes\Applications\blender.exe\shell\open\command';  O='D:\download\blender-3.5.0-windows-x64';  N='D:\Apps\Portable\blender-3.5.0-windows-x64';          W='blender 便携版已搬走' },
    @{ P='HKCU:\Software\Classes\Applications\blender.exe\DefaultIcon';         O='D:\download\blender-3.5.0-windows-x64';  N='D:\Apps\Portable\blender-3.5.0-windows-x64';          W='blender 图标' },
    @{ P='HKCU:\Software\Classes\Applications\EmEditor.exe\shell\open\command'; O='D:\emed64_25.0.1_portable\EmEditor.exe'; N='D:\Apps\Portable\emed64_25.0.1_portable\EmEditor.exe'; W='EmEditor 已搬走' },
    @{ P='HKCU:\Software\Classes\Applications\EmEditor.exe\DefaultIcon';        O='D:\emed64_25.0.1_portable\EmEditor.exe'; N='D:\Apps\Portable\emed64_25.0.1_portable\EmEditor.exe'; W='EmEditor 图标' },
    @{ P='HKCU:\Software\Classes\Applications\winhex.exe\shell\open\command';   O='D:\winhex\winhex.exe';                   N='D:\Apps\Portable\winhex\winhex.exe';                  W='WinHex 已搬走' },
    @{ P='HKCU:\Software\Classes\Applications\winhex.exe\DefaultIcon';          O='D:\winhex\winhex.exe';                   N='D:\Apps\Portable\winhex\winhex.exe';                  W='WinHex 图标' },
    @{ P='HKLM:\Software\Classes\AHub\shell\open\command';                      O='C:\Program Files\A HUB\A Hub.exe';       N='D:\Apps\Installed\A HUB\A HUB.exe';                   W='A HUB 已搬走' },
    @{ P='HKLM:\Software\Classes\AHub\DefaultIcon';                             O='C:\Program Files\A HUB\A Hub.exe';       N='D:\Apps\Installed\A HUB\A HUB.exe';                   W='A HUB 图标' }
)
foreach ($x in $repoint) { Set-Text $x.P '' $x.O $x.N $x.W }
Set-Text 'HKLM:\SYSTEM\CurrentControlSet\Services\Everything' 'ImagePath' 'D:\Everything-1.4.1.1026.x64\everything.exe' 'D:\Apps\Portable\Everything-1.4.1.1026.x64\everything.exe' 'Everything 服务（程序已搬到 D:\Apps\Portable）'
Set-Text 'HKLM:\SYSTEM\CurrentControlSet\Services\BaiduNetdiskUtility' 'ImagePath' 'C:\Users\<旧用户名>\AppData\Roaming\baidu' "$env:APPDATA\baidu" '百度网盘服务：旧用户目录 -> 当前'
foreach ($e in '.dic','.exc','.gitattributes') {
    $k = "HKLM:\Software\Classes\$e"
    if ((Get-RegValue $k '') -eq 'txtfile' -and (Test-Path 'HKLM:\Software\Classes\txtfilelegacy')) {
        Backup-Key $k | Out-Null
        if ($Apply) { $w = Open-RegKey $k $true; if ($w) { $w.SetValue('', 'txtfilelegacy'); $w.Close() } }
        $script:stat['改路径']++; Say ("  [改路径] {0}: txtfile（本机不存在）-> txtfilelegacy" -f $e)
    }
}
foreach ($k in 'HKCU:\Software\Classes\.pdf','HKLM:\Software\Classes\.pdf') {
    $cur = [string](Get-RegValue $k '')
    if ($cur -like 'Acrobat*' -or -not $cur) {
        Backup-Key $k | Out-Null
        if ($Apply) { $w = Open-RegKey $k $true; if ($w) { $w.SetValue('', 'MSEdgePDF'); $w.Close() } }
        $script:stat['改路径']++; Say ("  [改路径] {0}: {1} -> MSEdgePDF（Acrobat 已卸载）" -f $k, $(if ($cur) { $cur } else { '(空)' }))
    }
}

Say ''
Say '########## B. 删除残留 ##########'
# B1 WPS 全家（含上轮漏掉的 KET/KSO 前缀）+ Word/Excel 图标覆盖
$wpsPat = '^(WPS|ET|WPP|KWPS|KWPP|KET|KSO)(\.|$)'
foreach ($r in $clsRoots) {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames() | Where-Object { $_ -match $wpsPat -or $_ -match '^(Word|Excel|PowerPoint)\.' })
    $b.Close()
    foreach ($n in $names) {
        $k = $r + '\' + $n
        if ($n -match $wpsPat) { Del-Key $k 'WPS 残留（WPS 已卸载）'; continue }
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
    foreach ($n in $names) { Del-Key ($r + '\' + $n) '对应程序已卸载' }
}
foreach ($r in 'HKCU:\Software\Classes\Applications','HKLM:\Software\Classes\Applications','HKLM:\Software\Classes\WOW6432Node\Applications') {
    $b = Open-RegKey $r; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames() | Where-Object { $_ -match '^(Photoshop|Acrobat|photolaunch|PotPlayer|BCUT)' })
    $b.Close()
    foreach ($n in $names) { Del-Key ($r + '\' + $n) '对应程序已不存在' }
}
# B3 协议
$protos = 'lmstudio','smartdrive','game','unityhub','tuanjiehub','com.unity3d.kharma','mongodb','mongodb+srv','qsdis','vega','videocut'
foreach ($r in 'HKCU:\Software\Classes','HKLM:\Software\Classes','HKLM:\Software\Classes\WOW6432Node') {
    foreach ($p in $protos) {
        $k = $r + '\' + $p
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $exe = Get-ExeFrom ([string](Get-RegValue ($k + '\shell\open\command')))
        if (Test-Missing $exe) { Del-Key $k ("协议目标不存在：{0}" -f $exe) } else { $script:stat['跳过']++ }
    }
}
# B4 App Paths
foreach ($ap in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths') {
    $b = Open-RegKey $ap; if (-not $b) { continue }
    $names = @($b.GetSubKeyNames()); $b.Close()
    foreach ($n in $names) {
        $k = $ap + '\' + $n
        $exe = Get-ExeFrom ([string](Get-RegValue $k ''))
        if (Test-Missing $exe) { Del-Key $k ("目标不存在：{0}" -f $exe) } else { $script:stat['跳过']++ }
    }
}
# B5 死服务（服务键受保护，必须用 Get-ItemProperty 读）
foreach ($s in 'Clash Core Service','FlashCenterSvc','SysCleanProService') {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (-not (Test-Path -LiteralPath $k)) { continue }
    $img = [string](Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).ImagePath
    if (-not $img) { $script:stat['跳过']++; Say ("  [跳过] {0}：读不到 ImagePath" -f $s); continue }
    $exe = Get-ExeFrom $img
    if (Test-Missing $exe) { Del-Key $k ("服务程序不存在：{0}" -f $exe) } else { $script:stat['跳过']++ }
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
        if ($dn -match 'JetBrains Toolbox|IntelliJ IDEA' -and $all -like '*C:\Users\<旧用户名>*') { Del-Key $k ("旧用户目录的 JetBrains 记录：{0}" -f $dn); continue }
        # 通用规则：记录引用的路径落在"已不存在的旧用户目录"下 → 死记录（覆盖 360se6 / JetBrains 等剩余项）
        $oldProf = ([regex]::Match($all, '(C:\\Users\\<旧用户名>\\[^|"]+)')).Groups[1].Value
        if ($oldProf -and (Test-Missing $oldProf)) { Del-Key $k ("引用已不存在的旧用户目录：{0}" -f $dn); continue }
        if ($dn -match 'REDlauncher' -or $dn -match 'STEAMBIG') {
            if (Test-Missing (Get-ExeFrom $all)) { Del-Key $k ("已卸载且卸载器不存在：{0}" -f $dn) }
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
                if ($v -and $deadProgIds.Contains($v)) { if ($Apply) { try { $rk.DeleteValue($vn) } catch {} }; Say ("  [引用] {0} [{1}] = {2}" -f $ext, $(if ($vn) { $vn } else { 'default' }), $v); $refFixed++ }
            }
            $ico = [string]$rk.GetValue('DefaultIcon')
            $icoFile = Get-ExeFrom $ico
            if ($icoFile -and (Test-Missing $icoFile)) { if ($Apply) { try { $rk.DeleteValue('DefaultIcon') } catch {} }; Say ("  [图标] {0}\DefaultIcon = {1}（文件不存在）" -f $ext, $ico); $refFixed++ }
            $rk.Close()
        }
        foreach ($sub in 'OpenWithProgids','OpenWithList') {
            $sk = Open-RegKey ($k + '\' + $sub) $true
            if (-not $sk) { continue }
            foreach ($vn in @($sk.GetValueNames())) {
                $v = [string]$sk.GetValue($vn)
                $cand = if ($v) { $v } else { $vn }
                if ($cand -and $deadProgIds.Contains($cand)) { if ($Apply) { try { $sk.DeleteValue($vn) } catch {} }; Say ("  [引用] {0}\{1} [{2}] = {3}" -f $ext, $sub, $vn, $v); $refFixed++ }
            }
            $sk.Close()
        }
    }
}
$script:stat['引用清理'] = $refFixed

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
            if ($dv -and -not $allProg.Contains($dv) -and $dv -notmatch '^(AppX|Microsoft|Windows)') {
                if ($dv -eq 'txtfile') {                      # 本机 txtfile 缺失，指到 txtfilelegacy 更合适
                    if ($Apply) { $rk.SetValue('', 'txtfilelegacy') }
                    Say ("  [改路径] {0}: txtfile -> txtfilelegacy" -f $ext)
                } else {
                    if ($Apply) { try { $rk.DeleteValue('') } catch {} }
                    Say ("  [悬空默认值] {0} = {1}" -f $ext, $dv)
                }
                $dFixed++
            }
            $rk.Close()
        }
        $sk = Open-RegKey ($k + '\OpenWithProgids') $true
        if ($sk) {
            foreach ($vn in @($sk.GetValueNames())) {
                $v = [string]$sk.GetValue($vn)
                $cand = if ($v) { $v } else { $vn }
                if ($cand -and -not $allProg.Contains($cand) -and $cand -notmatch '^AppX') {
                    if ($Apply) { try { $sk.DeleteValue($vn) } catch {} }
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
