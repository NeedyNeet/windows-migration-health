# ============================================================================
#  tests/health-check.clsid.tests.ps1 —— 第 7 节 CLSID 扫描的"假绿"防护
#
#  背景：第 7 节原来只挑 Classes 这一层里"名字以 { 开头"的子键，而真正的 CLSID 外壳扩展
#  （右键菜单 / 缩略图 / 预览 / shell 扩展）住在 Classes\CLSID 子树里。正常机器上 Classes
#  层几乎没有以 { 开头的子键，于是本节打印"✓ 共 0 个 CLSID | 目标均存在" —— 检查了 0 项
#  却给出绿色结论，与"清单为空却报回归检查通过"是同一类假绿。
#
#  用 AST 抽出脚本里真实的 Get-ClsidExtensionKeys（连同它依赖的 Open-RegKey），在一个
#  **临时根键**上验证"枚举的是 CLSID 子树，而不是 Classes 这一层"。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\health-check.ps1'

Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Open-RegKey')
Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Get-ClsidExtensionKeys')

Test-Case 'CLSID 键来自 Classes\CLSID 子树（不是 Classes 这一层）' {
    $leaf = '_wmh_clsid_probe_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $root = 'HKCU:\Software\' + $leaf
    $g1 = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
    $g2 = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
    try {
        New-Item -Path ($root + '\CLSID\' + $g1 + '\InprocServer32') -Force | Out-Null
        New-Item -Path ($root + '\CLSID\' + $g2 + '\LocalServer32')  -Force | Out-Null
        New-Item -Path ($root + '\SomeProgID') -Force | Out-Null          # 不是 CLSID，不该被收进来
        $keys = @(Get-ClsidExtensionKeys -Roots @($root))
        Assert-Equal $keys.Count 2 ("应当只收到 CLSID 子树下的 2 个键，实际 {0}：{1}" -f $keys.Count, ($keys -join ' | '))
        Assert-True (@($keys | Where-Object { $_ -match [regex]::Escape($g1) }).Count -eq 1) 'CLSID 子树里的 GUID 键没被枚举到'
        Assert-True (@($keys | Where-Object { $_ -match 'SomeProgID' }).Count -eq 0) '非 GUID 子键被误收'
        Assert-True (@($keys | Where-Object { $_ -match '\\CLSID\\' }).Count -eq 2) '键路径里应当带 CLSID 这一层'
    } finally {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(('Software\' + $leaf), $false)
    }
}

Test-Case '没有 CLSID 子树时返回 0 项（第 7 节必须据此报"未执行有效检查"）' {
    $leaf = '_wmh_clsid_empty_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $root = 'HKCU:\Software\' + $leaf
    try {
        New-Item -Path ($root + '\SomeProgID') -Force | Out-Null
        $keys = @(Get-ClsidExtensionKeys -Roots @($root))
        Assert-Equal $keys.Count 0 '空子树应当返回 0 项'
    } finally {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(('Software\' + $leaf), $false)
    }
}

Test-Case '约定层断言：第 7 节保留了"0 项即未执行"的守卫' {
    # 这一条是"约定必须有执行者"：删掉守卫时它会失败（不是语义断言，语义那两条在上面）
    $text = [IO.File]::ReadAllText($target, (New-Object Text.UTF8Encoding($false)))
    Assert-Match $text '本节未执行有效检查' '第 7 节缺少"0 项即未执行"的分支'
    Assert-Match $text 'if \(\$clsidTotal -eq 0\)' '缺少 $clsidTotal -eq 0 的守卫'
}

Complete-TestRun 'health-check.clsid'