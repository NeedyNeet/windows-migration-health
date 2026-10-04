# ============================================================================
#  tests/encoding.tests.ps1 —— 编码与文本卫生不变量
#
#  每一条都对应本项目真实踩过的坑：
#    1. .ps1 无 BOM      -> 5.1 按 ANSI 解码 -> 中文乱码 -> 报出上百个**假**语法错误
#                           （实测：一个 400 行脚本能报出 55 个假错，而 pwsh 完全正常）
#    2. .cmd 含中文      -> cmd.exe 按代码页读 -> 注释变 ?（AGENTS.md 硬性约定 2）
#    3. .cmd 只有 LF     -> 批处理在 goto/标签上的行为不可靠
#    4. 裸 CR / BEL      -> 文本被某处做了 C 风格转义求值（\r -> CR、\a -> BEL），
#                           会把路径里的字符吃掉（local/README.md 的历史事故）
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo = Get-RepoRoot

# versions/ 是冻结归档（AGENTS.md：只增不改），其历史不合规项不在检查范围；
# scripts/ 与 tests/ 必须合规。
function Test-IsFrozen([string]$full) { return ($full -match '\\versions\\') }

$scriptFiles = @(Get-ChildItem -Path $repo -Recurse -File -Include *.ps1,*.psd1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\' })
$cmdFiles = @(Get-ChildItem -Path $repo -Recurse -File -Include *.cmd -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and -not (Test-IsFrozen $_.FullName) })

function Test-HasBom([string]$p) {
    $b = [IO.File]::ReadAllBytes($p)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}
function Test-IsBinaryOrUtf16([string]$p) {
    $b = [IO.File]::ReadAllBytes($p)
    if ($b.Length -ge 2 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF))) { return $true }
    return ($b -contains 0)
}
function Get-BareCrCount([string]$p) {
    $b = [IO.File]::ReadAllBytes($p); $n = 0
    for ($i = 0; $i -lt $b.Length; $i++) {
        if ($b[$i] -eq 13 -and ($i + 1 -ge $b.Length -or $b[$i + 1] -ne 10)) { $n++ }
    }
    return $n
}

Test-Case '.ps1 / .psd1 全部带 UTF-8 BOM（否则 5.1 会按 ANSI 解码）' {
    $bad = @($scriptFiles | Where-Object { -not (Test-HasBom $_.FullName) } |
        ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
    Assert-True ($bad.Count -eq 0) ("缺 BOM：{0}" -f ($bad -join ' ; '))
}

Test-Case '.cmd 全部为纯 ASCII（cmd.exe 按代码页读，中文会变 ?）' {
    $bad = @()
    foreach ($f in $cmdFiles) {
        if ([IO.File]::ReadAllText($f.FullName) -match '[^\x00-\x7F]') { $bad += $f.FullName.Substring($repo.Length + 1) }
    }
    Assert-True ($bad.Count -eq 0) ("含非 ASCII：{0}" -f ($bad -join ' ; '))
}

Test-Case '.cmd 不得带 BOM（cmd.exe 会把 BOM 当成命令的一部分）' {
    $bad = @()
    foreach ($f in $cmdFiles) {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bad += $f.FullName.Substring($repo.Length + 1) }
    }
    Assert-True ($bad.Count -eq 0) ("含 BOM：{0}" -f ($bad -join ' ; '))
}

Test-Case '.cmd 行尾全部为 CRLF（LF-only 批处理在 goto/标签上不可靠）' {
    $bad = @()
    foreach ($f in $cmdFiles) {
        $bare = ([regex]::Matches([IO.File]::ReadAllText($f.FullName), "(?<!`r)`n")).Count
        if ($bare -gt 0) { $bad += ("{0}({1} 处裸 LF)" -f $f.Name, $bare) }
    }
    Assert-True ($bad.Count -eq 0) ("存在裸 LF：{0}" -f ($bad -join ' ; '))
}

Test-Case '文本文件中没有裸 CR（转义求值吃掉字符的痕迹）' {
    $texts = @(Get-ChildItem -Path $repo -Recurse -File -Include *.ps1,*.psd1,*.cmd,*.md,*.txt,*.json,*.yml,*.yaml -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' })
    $bad = @()
    foreach ($f in $texts) {
        if (Test-IsBinaryOrUtf16 $f.FullName) { continue }
        $n = Get-BareCrCount $f.FullName
        if ($n -gt 0) { $bad += ("{0}({1})" -f $f.Name, $n) }
    }
    Assert-True ($bad.Count -eq 0) ("含裸 CR：{0}" -f ($bad -join ' ; '))
}

Test-Case '文本文件中没有 BEL(0x07) 等转义求值残留的控制字符' {
    $texts = @(Get-ChildItem -Path $repo -Recurse -File -Include *.ps1,*.psd1,*.cmd,*.md,*.txt -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' })
    $bad = @()
    foreach ($f in $texts) {
        if (Test-IsBinaryOrUtf16 $f.FullName) { continue }
        $b = [IO.File]::ReadAllBytes($f.FullName)
        foreach ($c in 7, 11, 12) { if ($b -contains $c) { $bad += ("{0}(0x{1:X2})" -f $f.Name, $c); break } }
    }
    Assert-True ($bad.Count -eq 0) ("含控制字符：{0}" -f ($bad -join ' ; '))
}

Complete-TestRun 'encoding'
