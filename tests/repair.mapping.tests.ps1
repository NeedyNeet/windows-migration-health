# ============================================================================
#  tests/repair.mapping.tests.ps1 —— 迁移映射表的行为与顺序不变量
#
#  顺序敏感是真实踩过的坑：quark 的资源放在带版本号的 app-<version> 子目录里，
#  通用的 quark-cloud-drive 那条若排在前面，就会把路径改成一个**不存在**的位置
#  （好在该脚本写入前会校验目标存在，于是退化为"报出来但修不了"，而不是写坏）。
#
#  去分叉时把这个映射表搬进 local\*.local.psd1，而 psd1 不允许 [ordered]，
#  所以改成「数组 + Old/New」来保住顺序。这个套件就是那次设计的回归网。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo = Get-RepoRoot
$target = Join-Path $repo 'scripts\repair-migrated-apps.ps1'

Test-Case '内置映射表里，quark 的具体条目排在通用条目之前' {
    $text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    $i1 = $text.IndexOf('(x86)\quark-cloud-drive\resources')
    $i2 = $text.IndexOf("(x86)\quark-cloud-drive';")
    Assert-True ($i1 -ge 0) '找不到 quark 具体条目'
    Assert-True ($i2 -ge 0) '找不到 quark 通用条目'
    Assert-True ($i1 -lt $i2) ("具体条目必须排在前面（位置 {0} vs {1}）" -f $i1, $i2)
}

Test-Case '映射用数组表达（psd1 不允许 [ordered]，数组才保得住顺序）' {
    $text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    Assert-Match $text '\$pathMapBase = @\(' 'pathMapBase 应当是数组'
    Assert-NotMatch $text '\$pathMapBase = \[ordered\]' 'pathMapBase 不应用 [ordered]'
}

# ---- 抽出真实的 Convert-MappedPath 来测行为 ----
Invoke-Expression (Get-ScriptFunctionText -Path $target -Name 'Convert-MappedPath')

$pathMap = [ordered]@{
    'C:\App\resources' = 'D:\New\app-3.19.0\resources'
    'C:\App'           = 'D:\New'
}
$profileMap = [ordered]@{
    'C:\Users\old\' = 'C:\Users\new\'
    'C:\Users\old'  = 'C:\Users\new'
}

Test-Case '具体前缀优先命中，保住带版本号的子路径' {
    $r = Convert-MappedPath -Text 'C:\App\resources\icon.ico'
    Assert-Equal $r 'D:\New\app-3.19.0\resources\icon.ico' '具体前缀应优先于通用前缀'
}

Test-Case '无匹配时返回 $null（调用方据此判断"不用改"）' {
    $r = Convert-MappedPath -Text 'C:\Nothing\here.txt'
    Assert-True ($null -eq $r) '无匹配必须返回 $null'
}

Test-Case '用户目录映射只在显式开启 WithProfileMap 时生效' {
    $off = Convert-MappedPath -Text 'C:\Users\old\AppData\x.txt'
    Assert-True ($null -eq $off) '未开启时不该改写用户目录'
    $on = Convert-MappedPath -Text 'C:\Users\old\AppData\x.txt' -WithProfileMap
    Assert-Equal $on 'C:\Users\new\AppData\x.txt' '开启后应改写用户目录'
}

Test-Case '用户目录两条映射里，带尾反斜杠的那条先命中' {
    $on = Convert-MappedPath -Text 'C:\Users\old\' -WithProfileMap
    Assert-Equal $on 'C:\Users\new\' '应匹配带尾反斜杠的那条'
}

Test-Case '大小写不敏感匹配（注册表里路径大小写很乱）' {
    $r = Convert-MappedPath -Text 'c:\APP\resources\x.ico'
    Assert-Equal $r 'D:\New\app-3.19.0\resources\x.ico' '应当忽略大小写'
}

Complete-TestRun 'repair.mapping'
