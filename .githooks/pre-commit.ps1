<#
  .githooks\pre-commit.ps1 —— pre-commit 钩子的实际逻辑（L2 层）

  它做什么：跑 tests\encoding.tests.ps1（编码 / 行尾 / 控制字符的不变量），不过就拦下提交。
  为什么用测试而不是自己写一套检查：那套规则已经有唯一实现，重复一份必然漂移。

  设计取舍：
    * **只拦不改**。钩子不替你改文件 —— 提交时被工具偷偷改写工作区太意外了。
      它只告诉你去跑哪条命令；那条命令默认还是试运行。
    * 检查的是**工作区**而不是暂存区。两者在"先 git add 再改坏文件"这种少见情况下可能不一致；
      用一次额外进程换取简单可靠，值。真正的保证层是 CI（在干净检出上跑同一套测试）。
    * 钩子**不会随 clone 自动安装**（git 的固有限制），所以它只是便利层：
      L1(fix-encoding) + L3(测试) + L4(CI) 才是保证层。

  跳过：git commit --no-verify
#>
$ErrorActionPreference = 'Continue'

$RepoRoot = Split-Path -Parent $PSScriptRoot          # .githooks\ -> 仓库根
$test = Join-Path $RepoRoot 'tests\encoding.tests.ps1'

if (-not (Test-Path -LiteralPath $test)) {
    Write-Output 'pre-commit: 找不到 tests\encoding.tests.ps1，跳过检查。'
    exit 0
}

$engine = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh' } else { 'powershell' }
if (-not (Get-Command $engine -ErrorAction SilentlyContinue)) {
    # 失败关闭：检查跑不起来时宁可拦住提交，也不要放过去一个可能是坏的文件。
    Write-Output ("pre-commit: 找不到 {0}，无法执行编码检查 —— 为安全起见拦下提交（绕过：git commit --no-verify）。" -f $engine)
    exit 1
}
# 判据必须和 tests\run-tests.ps1 一致：**退出码为 0 且看到 ##RESULT: PASS**。
# 只看退出码会漏掉一种致命的假绿：如果 tests\lib\TestKit.ps1 自己丢了 BOM（那恰恰是本套件
# 要检查的东西之一），框架加载失败 -> Test-Case / Complete-TestRun 都不存在 -> 脚本
# "静默跑完"而且退出码是 0 -> 钩子打印"检查通过"并放行。
# 实测踩过：这个失败模式真的把坏文件提交进去了（后来用 git reset 撤掉）。
$out = (& $engine -NoProfile -ExecutionPolicy Bypass -File $test 2>&1 | Out-String)
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()

if ($out -notmatch '##RESULT: (PASS|FAIL)') {
    Write-Output ''
    Write-Output 'pre-commit: 套件没有输出 ##RESULT 标记 —— 它没有正常跑完（最可能是测试框架自己加载失败）。'
    Write-Output '           这种情况一律按失败处理。'
}

if ($code -ne 0 -or $out -notmatch '##RESULT: PASS') {
    Write-Output ''
    Write-Output '================ pre-commit 拦下了这次提交 ================'
    Write-Output '上面的失败项说明暂存内容违反了编码 / 行尾约定（多数工具写文件时会丢 BOM）。'
    Write-Output '修复（默认试运行，-Apply 才写入）：'
    Write-Output '    .\scripts\dev\fix-encoding.ps1            # 先看它要改什么'
    Write-Output '    .\scripts\dev\fix-encoding.ps1 -Apply     # 补 BOM / 统一 .cmd 行尾'
    Write-Output '改完重新 git add，再提交。确需绕过：git commit --no-verify'
    exit 1
}

Write-Output 'pre-commit: 编码 / 行尾检查通过。'
exit 0
