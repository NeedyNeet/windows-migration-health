# ============================================================================
#  tests/health-fix.gate.tests.ps1 —— 厂商残留删除门禁（Remove-DeadVendorKey）
#
#  背景（这是一个真实事故级的 bug）：health-fix.ps1 的 B1/B2 段曾经对整族 ProgID
#  无条件 Del-Key —— 只凭一句注释"这台机器上它已卸载"。在仍装着 WPS / Acrobat /
#  PotPlayer 的机器上跑 -Apply，会直接把这些软件的文件关联清掉。
#
#  修法：统一走 Remove-DeadVendorKey —— 命令/图标的目标确实不存在（Test-Missing）
#  才删；取不到目标路径一律跳过。
#
#  做法：用 AST 抽出脚本里**真实的那段函数体**，用桩替换它的全部外部依赖
#  （Say / Del-Key / Get-RegValue / Get-ExeFrom / Test-Missing）。
#  **全程不读写真实注册表。**
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo = Get-RepoRoot
$target = Join-Path $repo 'scripts\health-fix.ps1'

# ---- 桩：被测函数体来自脚本，外部依赖全部替换 ----
$script:stat = [ordered]@{ '改路径' = 0; '删键' = 0; '删值' = 0; '跳过' = 0; '引用清理' = 0 }
$script:log = New-Object System.Collections.Generic.List[string]
$script:fake = @{}

function Say($m) { [void]$script:log.Add([string]$m) }
function Del-Key([string]$psPath, [string]$why = '') {
    [void]$script:log.Add(("DELKEY|{0}|{1}" -f $psPath, $why))
    $script:stat['删键']++
}
function Get-RegValue([string]$psPath, [string]$name = '') {
    $k = $psPath + $(if ($name) { '\' + $name } else { '' })
    if ($script:fake.ContainsKey($k)) { return $script:fake[$k] }
    return $null
}
function Get-ExeFrom([string]$s) {
    $m = [regex]::Match([string]$s, '([A-Za-z]:\\[^"|]+?\.(?:exe|dll|ico|sys))', 'IgnoreCase')
    return $m.Groups[1].Value
}
# 约定：路径里含 \dead\ 就算"不存在"
function Test-Missing([string]$p) { return ([string]$p -like '*\dead\*') }

Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Remove-DeadVendorKey')

$base = 'HKCU:\Software\Classes\'
$script:fake[$base + 'WPS.TestDead\shell\open\command']  = '"C:\dead\wps.exe" /automation'
$script:fake[$base + 'WPS.TestAlive\shell\open\command'] = '"C:\Windows\System32\notepad.exe" "%1"'
# WPS.TestNoCmd：既无 command 也无 DefaultIcon

Test-Case '目标不存在的键 -> 删除' {
    Remove-DeadVendorKey ($base + 'WPS.TestDead') 'WPS'
    Assert-Match ($script:log -join "`n") ([regex]::Escape('DELKEY|' + $base + 'WPS.TestDead')) '应当删掉目标不存在的键'
}

Test-Case '目标**仍存在**的键 -> 绝不删除（这就是本轮修掉的 bug）' {
    $script:log.Clear(); $script:stat['删键'] = 0; $script:stat['跳过'] = 0
    Remove-DeadVendorKey ($base + 'WPS.TestAlive') 'WPS'
    Assert-NotMatch ($script:log -join "`n") ([regex]::Escape('DELKEY|' + $base + 'WPS.TestAlive')) '目标存在却被删了'
    Assert-Match ($script:log -join "`n") '目标仍存在' '应当打印"目标仍存在"'
    Assert-Equal $script:stat['跳过'] 1 '跳过计数应为 1'
}

Test-Case '取不到命令/图标路径 -> 跳过（不能证明已卸载）' {
    $script:log.Clear(); $script:stat['删键'] = 0; $script:stat['跳过'] = 0
    Remove-DeadVendorKey ($base + 'WPS.TestNoCmd') 'WPS'
    Assert-NotMatch ($script:log -join "`n") ([regex]::Escape('DELKEY|' + $base + 'WPS.TestNoCmd')) '无法证明已卸载的键被删了'
    Assert-Match ($script:log -join "`n") '无法证明已卸载' '应当打印"无法证明已卸载"'
    Assert-Equal $script:stat['跳过'] 1 '跳过计数应为 1'
}

Test-Case 'B1/B2 段不再出现无条件的 Del-Key 整族删除' {
    $text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    Assert-NotMatch $text "Del-Key \`$k 'WPS 残留" 'B1 仍有无条件删除'
    Assert-NotMatch $text "Del-Key \(\`$r \+ '\\\\' \+ \`$n\) '对应程序已" 'B2 仍有无条件删除'
    Assert-Match $text 'Remove-DeadVendorKey' '找不到门禁函数的调用'
}

Complete-TestRun 'health-fix.gate'
