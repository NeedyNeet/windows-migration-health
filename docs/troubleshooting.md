# 排错：先看这里

**给谁看**：跑脚本或测试时觉得"结果不对劲"的人。
**什么时候看**：报告写着"未执行有效检查"、测试说某个引擎被跳过、`.cmd` 重定向拿不到输出、或结果与预期相反时。
**看完能得到什么**：分清**真问题 / 本机环境问题 / 设计如此**这三类，并知道各自怎么处理。

## 1. 报告里写着"未执行有效检查" —— 这通常是设计，不是故障

本项目最刻意的设计：**"没查"绝不能长成"没事"**。所以下面这些情况会明确报出来（并记入 `findings.csv`），
而不是打一个绿勾：

| 你看到的 | 含义 | 怎么办 |
|---|---|---|
| `⚠ 未执行有效检查：没有任何"旧路径 -> 新路径"映射可用` + **退出码 3** | `local\repair-migrated-apps.local.psd1` 没配或为空 | 用 `repair-migrated-apps.cmd -DiscoverTargets` 生成候选草稿，核对后填进该文件 |
| `本机映射未配置或为空` / `配置读不到（ACL）` / `配置语法坏了` + **退出码 3** | 三种失败模式被分开报出（约定 10：读不到 ≠ 不存在） | 按提示修文件权限或语法；缺文件则属于正常未配置 |
| 某一节写着"本节未执行有效检查" | 该节**枚举到 0 项**（例如 CLSID 子树为空）或你用了对应的 `-Skip*` 开关 | 去掉开关重跑；或确认那一类登记在本机确实为空 |
| `-ScanConfigFiles` 不给 `-AppsRoot` | 扫描根不写死（换机器就失效），必须显式指定 | 加 `-AppsRoot <目录>`；根不存在/根下 0 个可扫文件也会分别报出 |
| 报告里出现 `denied` 条目 | 目标**读不到**（权限），不是"不存在" | 需要覆盖就提权重跑；**不要**据此判断为残留 |

## 2. Microsoft Store（MSIX）版 pwsh 的两处影响

### 2.1 测试运行器会跳过不可用的引擎（这是对的）

`tests\run-tests.ps1` 在启动每个引擎之前先自检"能不能被本进程启动并捕获输出"。若 `pwsh` 只有
**Microsoft Store（MSIX）版**、而运行器正跑在 **Windows PowerShell 5.1** 下，自检会失败，于是它明确跳过：

```text
  [跳过] 引擎 pwsh：无法被本进程启动并捕获输出。
         常见原因：pwsh 只有 Microsoft Store（MSIX）版，而本运行器正跑在 5.1 下。
         MSIX 应用是被"激活"的、不是子进程 —— 拿不到 stdout 和退出码。
         解决：用 pwsh 运行本运行器，或安装 MSI/zip 版 PowerShell 7。
```

原因：从 5.1 启动 MSIX 应用是一次「**应用激活**」，不是创建子进程 —— 父进程既拿不到 stdout
（重定向得到 **0 字节**文件）也拿不到退出码。**在加上这道自检之前**，这个现象会被报成"8 个套件全部失败"：
那 8 个套件其实全过，是运行器看不见它们的输出。现在它跳过不可用的引擎，用剩下的跑完并给出结论。

三种解法任选：

1. 用 `pwsh` 跑运行器（推荐）—— `tests\run-tests.cmd` 本来就会**优先 `pwsh`**，找不到才回退 5.1；
2. 装 MSI / zip 版 PowerShell 7（装在 `C:\Program Files\PowerShell\7\`，不受此限制）；
3. 明确只要 5.1：`.\tests\run-tests.ps1 -Engine powershell`。

### 2.2 三个 `.cmd` 启动器的输出重定向会失效（影响面小得多）

MSIX 版 pwsh 在**父进程不是 PowerShell 7** 时不会把 stdout 交给父进程，而三个 `.cmd` 启动器正是由
`cmd.exe` 拉起 pwsh 的。本机（商店版 pwsh）实测：

| 你怎么用 | 结果 |
|---|---|
| **双击**（真实控制台） | 输出正常可见 ✓ |
| **重定向 / 管道 / 捕获**，例如 `scripts\repair-migrated-apps.cmd > plan.txt` | 子进程输出**不进文件**（**退出码仍然正确** ✓，只有 stdout 丢） |
| 直接用 `powershell`(5.1) 跑 `scripts\*.ps1` | 正常 ✓ |
| 装了 MSI / zip 版 PowerShell 7 | 正常 ✓ |

**所以：不要把 `.cmd` 的输出重定向来做留痕。** 想看计划就直接看屏幕，或直接调
`pwsh -File scripts\repair-migrated-apps.ps1`（它的输出正常），或用 `-Engine powershell` 那类写法。

> 为什么不在启动器里加"检测到商店版就报警"：交互使用完全正常，**退出码也正常** ——
> 为一个只影响重定向的场景，给三个会写系统的启动器加判断分支，得不偿失。写清楚比改代码划算。

## 3. 结果与预期相反时，先怀疑"检查器自己坏了"

真实发生过的两次，都属于这一类：

- **假绿**：测试套件中途崩掉，却照样打印 `共 0 项检查，0 项失败，0 项跳过` + `##RESULT: PASS`。
  现在 `tests\lib\TestKit.ps1` 把「**0 项检查 且 0 项跳过**」直接判为失败，
  `tests\harness.canary.tests.ps1` 用一个**合成空套件**钉住了这条判据。
- **假红**：`.ps1` 丢了 UTF-8 BOM → 5.1 按 ANSI 解码 → 报出上百个**假**语法错误（pwsh 7 下完全正常，
  所以这个坑只在 5.1 暴露）。改完文件跑一次 `scripts\dev\fix-encoding.ps1 -Apply` 即可。

## 下一步看哪篇

想了解"为什么要有这些设计" → [design-notes.md](design-notes.md)；想核对某一类登记 → [registry-reference.md](registry-reference.md)；想看完整事故过程 → [case-report-d-apps-migration.md](case-report-d-apps-migration.md)。
