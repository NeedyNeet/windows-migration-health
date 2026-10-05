# ============================================================================
#  tests/harness.canary.tests.ps1 —— 证明"检查者自己坏了"时不会静默通过
#
#  这道测试是给测试框架自己做的。实测事故（见 AGENTS.md 硬性约定 12）：
#  tests\lib\TestKit.ps1 一旦丢了 BOM，Windows PowerShell 5.1 会把框架按 ANSI 解码 →
#  加载失败 → Test-Case / Complete-TestRun 都不存在 → 套件"静默跑完"而且**退出码是 0**。
#  当时的 pre-commit 钩子只看退出码，于是打印"检查通过"并把坏文件放进了提交。
#
#  这里把那个场景复现出来，断言它现在会**明确失败**。
#
#  ⚠ 引擎相关性：BOM 问题只在 5.1 暴露（pwsh 7 能读无 BOM 文件）。所以
#    · 在 5.1 下 → 由"金丝雀"直接拦下（框架根本没加载起来）
#    · 在 pwsh 7 下 → 金丝雀不触发，套件继续跑并由 BOM 断言失败而拦下
#    两者都必须满足同一个不变量：**非零退出 + ##RESULT: FAIL + 没有 ##RESULT: PASS**。
#    这就是要钉住的东西。
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"

$repo = Get-RepoRoot

Test-Case '框架自己丢 BOM 时，套件必须明确失败（不能静默通过）' {
    $engine = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh' } else { 'powershell' }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('wmh-canary-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path $root -Force
        # 把整个 tests\ 复制到隔离目录后动手脚，绝不碰仓库里的原件
        Copy-Item -LiteralPath (Join-Path $repo 'tests') -Destination (Join-Path $root 'tests') -Recurse
        $kit = Join-Path $root 'tests\lib\TestKit.ps1'
        $bytes = [IO.File]::ReadAllBytes($kit)
        Assert-True ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
            '前提不成立：仓库里的 TestKit.ps1 本来就没有 BOM'
        [IO.File]::WriteAllBytes($kit, $bytes[3..($bytes.Length - 1)])   # 抽掉 BOM，复现事故

        $out = (& $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\encoding.tests.ps1') 2>&1 | Out-String)
        $code = $LASTEXITCODE

        # 只用 ASCII 断言（##RESULT 与 "UTF-8 BOM"），避免不同代码页下中文被解码坏而误判
        Assert-True ($code -ne 0) '退出码仍是 0 —— 这正是事故里的"静默通过"'
        Assert-Match    $out '##RESULT: FAIL' '没有输出 ##RESULT: FAIL'
        Assert-NotMatch $out '##RESULT: PASS' '居然还输出了 ##RESULT: PASS'
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Assert-Match $out 'UTF-8 BOM' '5.1 下应当由金丝雀直接拦下（框架没加载起来）'
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Test-Case 'run-tests.ps1 的判据包含 ##RESULT 标记（不是只看退出码）' {
    $t = [IO.File]::ReadAllText((Join-Path $repo 'tests\run-tests.ps1'))
    Assert-Match $t '##RESULT: \(PASS\|FAIL\)' 'run-tests.ps1 里看不到对 ##RESULT 标记的检查'
    Assert-Match $t '##RESULT: PASS' 'run-tests.ps1 没有要求出现 ##RESULT: PASS'
}

Test-Case 'pre-commit 钩子的判据与运行器一致' {
    $t = [IO.File]::ReadAllText((Join-Path $repo '.githooks\pre-commit.ps1'))
    Assert-Match $t '##RESULT: \(PASS\|FAIL\)' '钩子里看不到对 ##RESULT 标记的检查'
    Assert-Match $t '##RESULT: PASS' '钩子没有要求出现 ##RESULT: PASS'
}

Test-Case '运行器在启动引擎前会自检"能不能启动并捕获"' {
    # 实测事故：MSIX（Microsoft Store）版 pwsh 被 5.1 启动时是"应用激活"而不是子进程 ——
    # 重定向得到 0 字节、$LASTEXITCODE 为空，于是 8 个全过的套件被报成 8/8 失败。
    # 自检块看着像"多余的一步"，所以钉住它，防止将来被当成冗余删掉。
    $t = [IO.File]::ReadAllText((Join-Path $repo 'tests\run-tests.ps1'))
    Assert-Match $t 'wmh-probe-ok' '看不到"引擎可启动性自检"'
    Assert-Match $t '\[跳过\] 引擎' '自检失败时没有明确的跳过提示（会退回成假红）'
}
Test-Case '套件"一项检查都没做"时，框架必须判失败（0 项通过也是假绿）' {
    # 实测事故（2026-10-05）：新加的双引擎套件在 5.1 宿主下 `& pwsh` 启动失败，
    # 异常没冒出 try/finally，于是它照样打印 "共 0 项检查，0 项失败，0 项跳过" + `##RESULT: PASS`。
    # 这里用一个**什么都不做**的合成套件复现，钉住"0 项检查 + 0 项跳过 = 失败"。
    # 注意：合法的"全跳过"不受影响（跳过会计数），见上一个用例里的 [SKIP] 路径。
    $engine = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh' } else { 'powershell' }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('wmh-empty-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'tests\lib') -Force
        Copy-Item -LiteralPath (Join-Path $repo 'tests\lib\TestKit.ps1') -Destination (Join-Path $root 'tests\lib\TestKit.ps1')
        Set-Content -LiteralPath (Join-Path $root 'tests\empty.tests.ps1') -Encoding UTF8 -Value @(
            '. "$PSScriptRoot\lib\TestKit.ps1"'
            "Complete-TestRun 'empty'"
        )
        $out = (& $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\empty.tests.ps1') 2>&1 | Out-String)
        $code = $LASTEXITCODE
        Assert-True ($code -ne 0) '0 项检查的套件退出码仍是 0 —— 那正是"崩了却报通过"'
        Assert-Match    $out '##RESULT: FAIL' '没有输出 ##RESULT: FAIL'
        Assert-NotMatch $out '##RESULT: PASS' '居然还输出了 ##RESULT: PASS'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Complete-TestRun 'harness.canary'
