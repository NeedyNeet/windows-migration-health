<#
  scripts\dev\install-hooks.ps1 —— 启用本仓库的 git 钩子（幂等）

  为什么需要它：git 的钩子不会随 clone 自动安装（`core.hooksPath` 不在仓库里分发）。
  与其让人记一条 git config，不如给一条命令。

  用法：
    .\scripts\dev\install-hooks.ps1            # 启用（设置 core.hooksPath = .githooks）
    .\scripts\dev\install-hooks.ps1 -Status    # 只看当前状态
    .\scripts\dev\install-hooks.ps1 -Remove    # 关掉（清空 core.hooksPath）
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Remove
)

$ErrorActionPreference = 'Continue'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # scripts\dev\ -> scripts\ -> 仓库根
if (-not (Test-Path (Join-Path $RepoRoot 'scripts'))) { $RepoRoot = $PSScriptRoot }

Push-Location $RepoRoot
try {
    $cur = (git config --get core.hooksPath) 2>$null
    if ($Status) {
        Write-Output ('core.hooksPath = {0}' -f $(if ($cur) { $cur } else { '(未设置 —— 钩子未启用)' }))
        exit 0
    }

    if ($Remove) {
        git config --unset core.hooksPath 2>$null
        Write-Output '已清空 core.hooksPath（钩子不再生效）。'
        exit 0
    }

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.githooks\pre-commit'))) {
        Write-Output '找不到 .githooks\pre-commit —— 这个仓库里没有钩子可装。'
        exit 2
    }

    git config core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) { Write-Output 'git config 失败。'; exit 2 }
    Write-Output ('已启用钩子：core.hooksPath = {0}' -f (git config --get core.hooksPath))
    Write-Output '提交时会先跑 tests\encoding.tests.ps1；临时跳过用 git commit --no-verify'
} finally {
    Pop-Location
}
exit 0
