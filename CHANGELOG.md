# 变更记录（release notes）

> 这里只记**会影响使用者**的变更；逐条提交历史见 `git log`，每个版本对应一个**附注 tag**。
> 老用户升级前**请先读标题带 ⚠ 的那一节**。

## v2.2 —— 2026-10-05

### ⚠ 破坏性变更：迁移映射表搬出了脚本

`scripts\repair-migrated-apps.ps1` 里原来写死了 8 条"旧位置 → 新位置"映射（含钉版本的
`app-3.19.0`、`IntelliJ IDEA 2024.2.2`）和 2 条"整条缺失的开始菜单快捷方式"。这些是**机器专属值**，
已全部搬进 `local\repair-migrated-apps.local.psd1`（硬性约定 8）；脚本里的 `$pathMapBase` 现在是空数组。

**升级后必须做的**：把你原先"能用"的那几条映射抄进 `local\repair-migrated-apps.local.psd1`
的 `PathMap`（模板见 `config\repair-migrated-apps.local.example.psd1`）。没有它时 `repair` 会
明确报"**未执行有效检查**"并以**退出码 3** 结束 —— 这是刻意的：**"没查"不能长成"没事"**。
要取回旧值可以看历史版本：

```powershell
git show v2.1:scripts/repair-migrated-apps.ps1 | Select-String "Old = '"
```

同一版本里还加进了 `MissingShortcuts`（缺失的整条快捷方式）与 `VerifyPaths`（跑完后的验收清单），
它们同样只在 `local\` 配置里。

### 修复：一批"报告说没事、其实没查"的缺陷

| 位置 | 原来的行为 | 现在 |
|---|---|---|
| `repair`：只有 1 条本机映射时 | 语句输出被拆包成 Hashtable → `$Hashtable + $Object[]` 抛**非终止**错误 → 映射表空着、打印"没有需要改指的登记"并 `exit 0` | 合并逻辑抽成纯函数 `Merge-PathMap`（两侧 `@()`）；0 条映射**显式报错 + `exit 3`** |
| `repair` / `health-fix`：本机配置语法坏了或读不到 | `Import-PowerShellDataFile` 失败是**非终止**错误、裸 `Test-Path` 把"读不到"当"不存在" → 静默降级成"没有本机规则"，报告看起来正常 | 状态分成 `ok / missing / denied / broken`；`denied` 与 `broken` **致命退出**，`missing` 才提示继续 |
| `repair`：读不到的注册表键 | `Test-Path` 快速门 + `-ErrorAction SilentlyContinue` → **既不改也不报** | 用 `Get-KeyProbeState` 分类（判定表按两台引擎实测），读不到的键**记账**并在结尾按位置聚合报出 |
| `health-check -ScanConfigFiles` | 扫描根写死 `D:\Apps`：换台机器整段只剩一个空标题（连"未发现"都不打印） | 改 `-AppsRoot`；**缺根 / 根下 0 个可扫文件 / 读不到 / 真扫了 N 个** 四种状态分别报出 |
| `health-check` / `health-fix` 里的 `[System.IO.Directory]::GetAttributes` | **这个方法根本不存在** → 恒抛 `RuntimeException` → 下游"目标确实不存在"的两个判定分支成了死代码 | 改用对文件与目录都有效的 `[System.IO.File]::GetAttributes`；新增 lint 规则 9 用反射拦这类错误 |

### 性能：`repair` 的发现阶段快 5.3 倍

发现阶段原来用 `reg.exe query <根键> /f <关键词> /s`（**每条关键词各跑一遍**）。改成 .NET 一次性遍历
（`Find-MigratedKeys`，与 `health-check` 第 12 节同一套做法），并加了一个**不改变判定**的预筛
（所有关键词都含 `:` 时，"自身不含 `:` 的值"必然不可能命中）。

本机实测（同一份 13 条映射表 × 3 个根键）：

| | 旧（reg.exe） | 新（.NET） |
|---|---|---|
| 发现阶段 | 321 秒 | **55.1 秒** |
| 整个试运行 | 326.5 秒 | **61.3 秒**（5.3×） |
| 计划改写 | 132 行 | 132 行 → **逐行 0 差异** |

顺带修一处口径：本项目早先文档里出现过"13 条关键词 × 3 个根键 ≈ 30~40 分钟"的估计，
那是**并发污染下的读数**（当时后台还跑着别的注册表任务）；真实值是上表的 5.3 分钟。

### 测试：把几处"只能靠人盯"的约定变成机械判据

- `tests\health-check.dualengine.tests.ps1`（新）：**双引擎结论一致**的自动化执行者 —— 用固定清单
  分别在 5.1 与 7.x 下各跑一次体检（`-NoHistory`、全新 `OutDir`），逐行比对 `findings.csv`
  （排除"容量/目录体积"这类每次都会变的类别，并打印排除条数；两次都必须是**非空**结果，
  否则"0 行对 0 行"也算假绿）。本机实测 23,380 行 / 0 差异。
- `tests\lint.tests.ps1` 规则 8：`scripts\` 下出现机器专属路径字面量即违规（把映射表搬走之后，保证它搬不回来）。
- `tests\lint.tests.ps1` 规则 9：调用了不存在的 .NET 成员即违规（反射确认）。
- `tests\repair.config.tests.ps1`、`tests\repair.discovery.tests.ps1`、`tests\health-fix.config.tests.ps1`、
  `tests\health-check.configscan.tests.ps1`（均新增）：上面那些修复各自的行为测试。
- 新增/扩展的套件都遵守同一条规矩：**跳过要计数、0 项要报"未执行有效检查"**。

### 验收

- `tests\run-tests.cmd`（`SLOW_TESTS=1`）+ CI 矩阵（`pwsh` / `powershell`）全绿；本机实测双引擎共
  **48 项 `##RESULT: PASS` / 0 失败 / 0 跳过**。
- 双引擎 `findings.csv` 零差异（23,380 行）。
- `repair` 试运行：换实现前后**计划改写逐行一致**（132/132 行、命中 66 个键）。

## v2.1 及更早

更早的变更见 `git log`（`v2.1` 及之前的 tag）。值得知道的两条历史教训，都已写进
[12 类登记参考](docs/registry-reference.md) 与 [案例报告](docs/case-report-d-apps-migration.md)：

- `health-check` 的第 12 节原来用 `reg query /f /s`，本机要跑 52~55 分钟；改成 .NET 遍历后约 1 分钟。
- 第 7 节（CLSID 扩展）原来只看 `Classes` 这一层"以 `{` 开头"的键，正常机器上几乎为空，
  于是打出 `✓ 共 0 个 CLSID / 目标均存在` —— 检查了 0 项却通过。现在按 `Classes\CLSID` **子树**枚举，
  枚举到 0 项会明说"本节未执行有效检查"。
