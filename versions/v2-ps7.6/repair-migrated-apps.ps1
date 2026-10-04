# repair-migrated-apps.ps1
# Repairs Windows registrations for applications whose files were moved into D:\Apps.
#
# Symptom it fixes: the app files live in D:\Apps\..., but Windows still points at the
# ORIGINAL install paths (C:\Program Files (x86)\..., C:\Users\<old-name>\..., D:\JetBrains\...).
# Windows therefore cannot find the app: search does not find it, double-clicking a
# associated file fails, and Settings > Apps shows a dead entry.
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
    [string]$BackupDir = "$env:USERPROFILE\Desktop\apps-repair-backup"
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- path mapping
# Old (registered) path prefix -> real current path. Longest prefix wins.
$pathMap = [ordered]@{
    # specific entries first: the first matching prefix rewrites the text, so a longer,
    # more precise prefix must win over a shorter one (quark keeps its resources inside
    # a versioned app-<version> folder, so its icon/asset paths need this entry)
    'C:\Program Files (x86)\quark-cloud-drive\resources' = 'D:\Apps\Installed\quark-cloud-drive\app-3.19.0\resources'
    'C:\Users\<旧用户名>\AppData\Local\Programs\Notion' = 'D:\Apps\Installed\Notion'
    'C:\Users\<旧用户名>\AppData\Local\Programs\Xmind'  = 'D:\Apps\Installed\Xmind'
    'C:\Program Files (x86)\NetEase\CloudMusic'     = 'D:\Apps\Installed\NetEase\CloudMusic'
    'C:\Program Files (x86)\quark-cloud-drive'      = 'D:\Apps\Installed\quark-cloud-drive'
    'D:\BCompare-zh-5.0.1.29877'                    = 'D:\Apps\Portable\BCompare-zh-5.0.1.29877'
    'D:\IntelliJ IDEA 2024.2.2'                     = 'D:\Apps\JetBrains\IntelliJ IDEA 2024.2.2'
    'D:\JetBrains\'                                 = 'D:\Apps\JetBrains\'
    'D:\mpv-lazy'                                   = 'D:\Apps\Portable\mpv-lazy'
}

# The Windows profile folder was renamed too (C:\Users\<旧用户名> -> C:\Users\<user>).
# Only applied inside HKCU\Software\Classes (URL handlers etc.), never to uninstall
# records: rewriting a dead install path to another dead profile path helps nobody.
$profileMap = [ordered]@{
    'C:\Users\<旧用户名>\' = "$env:USERPROFILE\"
    'C:\Users\<旧用户名>'  = $env:USERPROFILE
}

function Convert-MappedPath {
    param([string]$Text, [switch]$WithProfileMap)
    $result = $Text
    $hit = $false
    foreach ($old in $pathMap.Keys) {
        if ($result.IndexOf($old, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $result = [regex]::Replace($result, [regex]::Escape($old), $pathMap[$old], 'IgnoreCase')
            $hit = $true
        }
    }
    if ($WithProfileMap) {
        foreach ($old in $profileMap.Keys) {
            if ($result.IndexOf($old, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $result = [regex]::Replace($result, [regex]::Escape($old), $profileMap[$old], 'IgnoreCase')
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
            $fileRef = [regex]::Match($new, '([A-Za-z]:\\[^"]*?\.(?:exe|dll|ico|com|bat|cpl|msc|sys))')
            if ($fileRef.Success -and -not (Test-Path -LiteralPath $fileRef.Groups[1].Value)) {
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

function Backup-Key {
    param([string]$Key)
    if ($script:backedUp -contains $Key) { return }
    $script:backedUp += $Key
    if (-not $Apply) { return }
    $regPath = $Key -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
    $safe = ($regPath -replace '[\\:*?"<>|]', '_')
    $file = Join-Path $BackupDir ("$safe.reg")
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    & reg.exe export $regPath $file /y | Out-Null
}

$targets = @(
    @{ Root = 'HKCU:\Software\Classes\notion';                     Profile = $true  }
    @{ Root = 'HKCU:\Software\Classes\xmind';                      Profile = $true  }
    @{ Root = 'HKCU:\Software\Classes\xmind-zen';                  Profile = $true  }
    @{ Root = 'HKCU:\Software\Classes\Xmind Workbook';             Profile = $true  }
    @{ Root = 'HKCU:\Software\Classes\QuarkCloudDrive.torrent';    Profile = $true  }
    # NOTE: HKCU\Software\Classes\jetbrains (URL handler) is deliberately NOT rewritten:
    # it points at the JetBrains Toolbox daemon, which no longer exists in the renamed
    # profile. Reinstall JetBrains Toolbox (or delete that key) instead.
    @{ Root = 'HKLM:\Software\Classes\BeyondCompare.SettingsPackage'; Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\BeyondCompare.Snapshot';      Profile = $false }
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\BCompare.exe';   Profile = $false }
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\cloudmusic.exe'; Profile = $false }
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe';        Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\BCompare.exe';   Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\cloudmusic.exe'; Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe';        Profile = $false }
    @{ Root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe';        Profile = $false }
    # every cloudmusic.<ext> ProgID
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.mp3';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.flac'; Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.m4a';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.wav';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.ape';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.ogg';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.aac';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.wma';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.cda';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.cue';  Profile = $false }
    @{ Root = 'HKLM:\Software\Classes\cloudmusic.ncm';  Profile = $false }
    # JetBrains Toolbox registrations (one subkey per IDE)
    @{ Root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Profile = $false }
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Profile = $false }
    # "Open with" registrations: Applications\<exe> holds the verbs Windows shows in the
    # Open-with dialog and on the taskbar jump list (mpv-lazy registers mpv.exe there)
    @{ Root = 'HKLM:\Software\Classes\Applications'; Profile = $false }
    @{ Root = 'HKLM:\Software\WOW6432Node\Classes\Applications'; Profile = $false }
    @{ Root = 'HKCU:\Software\Classes\Applications'; Profile = $false }
    # AutoPlay handlers (mpv registers DVD / Blu-ray handlers) and its Default Programs entry
    @{ Root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; Profile = $false }
    @{ Root = 'HKLM:\Software\Clients\Media\mpv'; Profile = $false }
)

# Any HKCU\Software\Classes\Toolbox.* key (IDE file-open handlers written by Toolbox)
foreach ($k in (Get-ChildItem 'HKCU:\Software\Classes' -ErrorAction SilentlyContinue)) {
    if ($k.PSChildName -like 'Toolbox.*') {
        $targets += @{ Root = ('HKCU:\Software\Classes\' + $k.PSChildName); Profile = $true }
    }
}

# mpv-lazy registers one ProgID per media type (io.mpv.<type>) straight into HKLM\Software\Classes.
# NOTE: the canonical way to re-point those is to re-run mpv-lazy's own installer from its new
# location ("<new path>\installer\mpv-install.bat" as admin); this loop is the fallback for
# whatever that leaves behind.
foreach ($k in (Get-ChildItem 'HKLM:\Software\Classes' -ErrorAction SilentlyContinue)) {
    if ($k.PSChildName -like 'io.mpv*') {
        $targets += @{ Root = ('HKLM:\Software\Classes\' + $k.PSChildName); Profile = $false }
    }
}

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
# Only the D:\Apps-migration prefixes. The renamed profile folder (C:\Users\<旧用户名>) is a
# DIFFERENT and far wider problem: searching for it drags in every unrelated app that ever
# lived in the old profile (GIMP, 360se, PowerToys, GitHub Desktop, ...) whose paths have no
# valid new target, so it is deliberately kept out of this repair.
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

# the same key can arrive from several places (explicit list, Toolbox/io.mpv loops, discovery):
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
            Backup-Key -Key $e.Key
            if ($e.Name) {
                Set-ItemProperty -LiteralPath $e.Key -Name $e.Name -Value $e.New -ErrorAction Continue
            } else {
                # an empty value name is the key's (Default) value; Set-ItemProperty
                # refuses an empty -Name, so write it through Set-Item instead
                Set-Item -LiteralPath $e.Key -Value $e.New -ErrorAction Continue
            }
            $written = (Get-Item -LiteralPath $e.Key).GetValue($e.Name, $null, 'DoNotExpandEnvironmentNames')
            $state = 'FAILED'
            if ($written -eq $e.New) { $state = 'ok' }
            Write-Output ("    -> write {0}" -f $state)
        }
    }
}

if ($Apply -and $script:backedUp.Count -gt 0) {
    Write-Output ''
    Write-Output ("backups: {0} key(s) exported to {1}" -f $script:backedUp.Count, $BackupDir)
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
        try { $old = $sp.CreateShortcut($f.FullName).TargetPath } catch {}
        if (-not $old) { continue }
        $new = Convert-MappedPath -Text $old
        if ($null -eq $new) { continue }
        if (Test-Path -LiteralPath $old) { continue }   # target is fine, leave it alone
        if (-not (Test-Path -LiteralPath $new)) { continue }
        Set-ShortcutTarget -Lnk $f.FullName -Target $new
    }
}

# 2. create shortcuts that are missing entirely (these apps are invisible to Start search)
$missing = @(
    @{ Name = 'Xmind';   Target = 'D:\Apps\Installed\Xmind\Xmind.exe' }
    @{ Name = '夸克网盘'; Target = 'D:\Apps\Installed\quark-cloud-drive\QuarkCloudDrive.exe' }
)
$userPrograms = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
foreach ($m in $missing) {
    $lnk = Join-Path $userPrograms ("{0}.lnk" -f $m.Name)
    if (Test-Path -LiteralPath $lnk) { continue }
    if (-not (Test-Path -LiteralPath $m.Target)) { continue }
    Set-ShortcutTarget -Lnk $lnk -Target $m.Target
}

# ---------------------------------------------------------------- verification
Write-Output ''
Write-Output '--- verification ---'
$check = @(
    'D:\Apps\Installed\Xmind\Xmind.exe',
    'D:\Apps\Installed\Notion\Notion.exe',
    'D:\Apps\Installed\quark-cloud-drive\QuarkCloudDrive.exe',
    'D:\Apps\Installed\NetEase\CloudMusic\cloudmusic.exe',
    'D:\Apps\Portable\BCompare-zh-5.0.1.29877\Beyond Compare 5\BCompare.exe',
    'D:\Apps\JetBrains\CLion\bin\clion64.exe',
    'D:\Apps\JetBrains\PyCharm\bin\pycharm64.exe',
    'D:\Apps\JetBrains\DataGrip\bin\datagrip64.exe',
    'D:\Apps\JetBrains\IntelliJ IDEA 2024.2.2\bin\idea64.exe',
    'D:\Apps\Portable\mpv-lazy\mpv.exe'
)
foreach ($c in $check) {
    Write-Output ("  {0,-6} {1}" -f $(if (Test-Path -LiteralPath $c) { 'OK' } else { 'ABSENT' }), $c)
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
