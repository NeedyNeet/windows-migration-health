<#
  scripts\dev\fix-encoding.ps1 —— 编码 / 行尾的规范化工具（L1 层）

  为什么需要它：任何"把文件当文本读进来、再用无 BOM 的 UTF-8 写回去"的工具都会丢 BOM
  （编辑器、批量替换脚本、AI 编辑工具都会）。而 .ps1 丢了 BOM 之后，Windows PowerShell 5.1
  会按 ANSI 解码，中文注释全乱码、报出上百个假语法错误——而 pwsh 7 完全正常，所以很容易漏。
  实测：一次文本编辑之后就复现过 55 个假语法错误。

  分工（这条很关键）：
      **能机械判定的就自动修** —— .ps1/.psd1 的 BOM 与行尾；.cmd 的行尾与误带的 BOM
      **需要人判断的只报告** —— .cmd 里的中文（得人来重写注释）、裸 CR / BEL
                                （说明文本被某处做了 C 风格转义求值，改法取决于原意）
  这样它不会偷偷改坏东西。

  约定与其它脚本一致：**默认试运行，-Apply 才写入**。

  用法：
    .\scripts\dev\fix-encoding.ps1                 # 试运行：只报告会改什么
    .\scripts\dev\fix-encoding.ps1 -Apply          # 实际写入
    .\scripts\dev\fix-encoding.ps1 -Apply -IncludeVersions   # 连 versions\ 冻结归档一起（一般不需要）

  退出码：0 = 没有遗留问题；1 = 仍有需要人工处理的问题；2 = 参数问题。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$IncludeVersions
)

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)   # scripts\dev\ -> scripts\ -> 仓库根
if (-not (Test-Path (Join-Path $RepoRoot 'scripts'))) { $RepoRoot = $ScriptDir }

$utf8Bom    = New-Object Text.UTF8Encoding($true)
$utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$utf8Plain  = New-Object Text.UTF8Encoding($false)

$manual = New-Object System.Collections.Generic.List[string]
$fixedCount = 0

function Write-Out([string]$s) { Write-Output $s }

function Test-HasBom([byte[]]$b) {
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

# 返回不含 BOM 的正文。必须剥掉 BOM：否则 U+FEFF 会混进文本，
# 再以"带 BOM"写回就变成两个 BOM（写这个工具时差点踩中）。
function Get-Body([byte[]]$b) {
    if (Test-HasBom $b) {
        if ($b.Length -le 3) { return @() }
        return $b[3..($b.Length - 1)]
    }
    return $b
}

function ConvertTo-Crlf([string]$s) { return (($s -replace "`r`n", "`n") -replace "`n", "`r`n") }

function Get-Files([string]$Filter) {
    $items = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }
    if (-not $IncludeVersions) { $items = $items | Where-Object { $_.FullName -notmatch '\\versions\\' } }
    return @($items)
}

Write-Out ('仓库根：{0}' -f $RepoRoot)
Write-Out ('模式  ：{0}' -f $(if ($Apply) { '写入（-Apply）' } else { '试运行：不会修改任何文件' }))
if (-not $IncludeVersions) { Write-Out '范围  ：已跳过 versions\（冻结归档）；需要时加 -IncludeVersions' }
Write-Out ''

# ---- 1) .ps1 / .psd1：补 BOM（**刻意不改行尾**）----
# 为什么不管行尾：这两个后缀在 .gitattributes 里声明 eol=crlf，而工作区里是 LF ——
# git 会把 CRLF 归一化成 LF，所以两者在仓库里完全等价（实测 blob hash 相同）。
# 而任何文本编辑工具写回的都是 LF：这里若强制转 CRLF，每编辑一次就"需要修"一次，纯属空转。
# 真正必须在乎 CRLF 的是 .cmd（见第 2 步），因为批处理解析器在乎。
Write-Out '--- .ps1 / .psd1：UTF-8 BOM ---'
$targets = @(Get-Files '*.ps1') + @(Get-Files '*.psd1')
$n = 0
foreach ($f in $targets) {
    $rel = $f.FullName.Substring($RepoRoot.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = Test-HasBom $bytes
    $text = $null
    try { $text = $utf8Strict.GetString((Get-Body $bytes)) }
    catch {
        Write-Out ('  [需人工] {0}：不是合法 UTF-8（可能是 ANSI 写的），不自动转换' -f $rel)
        $manual.Add($rel); continue
    }
    if ($hasBom) { continue }
    if ($Apply) {
        [IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
        Write-Out ('  [已补 BOM] {0}' -f $rel)
    } else {
        Write-Out ('  [将补 BOM] {0}' -f $rel)
    }
    $n++
}
if ($n -eq 0) { Write-Out '  ✓ 全部已带 BOM' }
$fixedCount += $n

# ---- 2) .cmd：无 BOM + CRLF；非 ASCII 只报告 ----
Write-Out ''
Write-Out '--- .cmd：BOM 与行尾 ---'
$n = 0
foreach ($f in (Get-Files '*.cmd')) {
    $rel = $f.FullName.Substring($RepoRoot.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = Test-HasBom $bytes
    $text = $utf8Plain.GetString((Get-Body $bytes))
    if ($text -match '[^\x00-\x7F]') {
        Write-Out ('  [需人工] {0}：含非 ASCII —— cmd.exe 按代码页读，中文注释会变 ?，请改写成英文' -f $rel)
        $manual.Add($rel)
    }
    $newText = ConvertTo-Crlf $text
    if (-not $hasBom -and $newText -eq $text) { continue }
    $what = @()
    if ($hasBom) { $what += '去BOM' }
    if ($newText -ne $text) { $what += 'CRLF' }
    if ($Apply) {
        [IO.File]::WriteAllText($f.FullName, $newText, $utf8Plain)
        Write-Out ('  [已修 {0}] {1}' -f ($what -join '+'), $rel)
    } else {
        Write-Out ('  [将修 {0}] {1}' -f ($what -join '+'), $rel)
    }
    $n++
}
if ($n -eq 0) { Write-Out '  ✓ BOM 与行尾均已符合策略' }
$fixedCount += $n

# ---- 3) 裸 CR / 控制字符：只报告，不自动改 ----
Write-Out ''
Write-Out '--- 裸 CR / 控制字符（只报告）---'
$textExts = '.ps1', '.psd1', '.cmd', '.md', '.txt', '.json', '.yml', '.yaml'
$texts = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $textExts -contains $_.Extension.ToLower() -and $_.FullName -notmatch '\\\.git\\' })
if (-not $IncludeVersions) { $texts = @($texts | Where-Object { $_.FullName -notmatch '\\versions\\' }) }
$ctrlBad = 0
foreach ($f in $texts) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    # 含 NUL 的一律跳过：.reg 备份是 UTF-16LE，换行是 0D 00 0A 00，
    # 按"裸 CR"判断会全部误报（第一次写这个检查时就踩了）。
    if ($bytes -contains 0) { continue }
    $bareCr = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 13 -and ($i + 1 -ge $bytes.Length -or $bytes[$i + 1] -ne 10)) { $bareCr++ }
    }
    $ctrl = @()
    foreach ($c in 7, 11, 12) { if ($bytes -contains $c) { $ctrl += ('0x{0:X2}' -f $c) } }
    if ($bareCr -gt 0 -or $ctrl.Count -gt 0) {
        $rel = $f.FullName.Substring($RepoRoot.Length + 1)
        Write-Out ('  [需人工] {0}：裸 CR {1} 处；控制字符 {2}' -f $rel, $bareCr, $(if ($ctrl.Count) { $ctrl -join ',' } else { '无' }))
        $manual.Add($rel)
        $ctrlBad++
    }
}
if ($ctrlBad -eq 0) { Write-Out '  ✓ 未发现异常控制字符' }

# ---- 4) .githooks 下的钩子：行尾必须 LF（由 sh 执行）----
# CRLF 会让 shebang 变成 "#!/bin/sh\r" -> git 报 bad interpreter。这个坑特别难自己爬出来：
# **钩子就是那个执行不了的文件**，它连打印错误的机会都没有，用户只能靠 --no-verify 脱身。
# 所以这里必须能自动修。
Write-Out ''
Write-Out '--- .githooks：行尾必须 LF ---'
$n = 0
$hookDir = Join-Path $RepoRoot '.githooks'
if (Test-Path -LiteralPath $hookDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $hookDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -ne '.ps1' })) {
        $rel = $f.FullName.Substring($RepoRoot.Length + 1)
        $text = $utf8Plain.GetString([IO.File]::ReadAllBytes($f.FullName))
        if ($text -notmatch "`r") { continue }
        if ($Apply) {
            [IO.File]::WriteAllText($f.FullName, ($text -replace "`r`n", "`n"), $utf8Plain)
            Write-Out ('  [已转 LF] {0}' -f $rel)
        } else {
            Write-Out ('  [将转 LF] {0}' -f $rel)
        }
        $n++
    }
}
if ($n -eq 0) { Write-Out '  ✓ 行尾均已是 LF' }
$fixedCount += $n

# ---- 汇总 ----
Write-Out ''
Write-Out '================ 汇总 ================'
Write-Out ('  自动处理：{0} 个文件{1}' -f $fixedCount, $(if ($Apply) { '（已写入）' } else { '（试运行，未写入）' }))
Write-Out ('  需人工处理：{0} 处' -f $manual.Count)
if ($manual.Count -gt 0) { $manual | Sort-Object -Unique | ForEach-Object { Write-Out ('    - ' + $_) } }
if ($manual.Count -gt 0) { exit 1 }
exit 0
