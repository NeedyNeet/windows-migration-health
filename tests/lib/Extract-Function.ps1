# ============================================================================
#  tests/lib/Extract-Function.ps1 —— 用 AST 从被测脚本里抽出函数的定义原文
#
#  为什么要这么绕：脚本刻意保持"单个 .ps1 拷到哪都能独立跑"（项目卖点之一），
#  不为测试而重构成模块。所以测试反过来把要测的函数体从文件里抽出来，
#  用桩替换它的外部依赖后调用——测的是**脚本里真实的那段代码**，不是复制品。
#
#  ⚠ 只抽**一个**函数：不会自动带上它调用的其它函数。被测函数若有依赖，必须一并抽出来，
#     否则运行时报"术语 xxx 不是 cmdlet、函数、脚本文件或可执行程序的名称"。
#     （加 Replace-PathLiteral 时就因为这个原因一次性挂了 6 条断言。）
# ============================================================================

function Get-ScriptFunctionText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw ("找不到脚本：{0}" -f $Path) }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and @($errors).Count -gt 0) {
        throw ("脚本存在语法错误，无法抽取函数：{0}" -f $errors[0].Message)
    }

    $found = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true))

    if ($found.Count -eq 0) { throw ("在 {0} 中找不到函数 {1}" -f (Split-Path $Path -Leaf), $Name) }
    return $found[0].Extent.Text
}
