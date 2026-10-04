# windows-migration-health

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-5391FE)
![Platform](https://img.shields.io/badge/platform-Windows-0078D4)
![License](https://img.shields.io/badge/license-MIT-green)
[![ci](https://github.com/NeedyNeet/windows-migration-health/actions/workflows/ci.yml/badge.svg)](https://github.com/NeedyNeet/windows-migration-health/actions/workflows/ci.yml)

Windows **「程序位置登记」一致性**工具集：核对并修复那些"登记指向的东西已经不在"的地方，附带长期健康体检。

**两种成因，同一个症状** —— "文件还在（或程序还在），但 Windows 认不出来"：双击文件打不开、开始菜单搜不到、`Win+R` 输程序名没反应、"设置 → 应用"里的卸载/修复按钮失效。

| 成因 | 怎么发生的 | 处理方式 |
|---|---|---|
| **① 迁移** | 把应用搬了家、或改过用户目录名：文件到了新位置，而系统里 12 类登记还指着旧路径 | 登记改指新路径（`repair-migrated-apps`）；文件本身别动 |
| **② 卸载残留** | 卸载器删了程序，却把登记留在注册表里、指向已不存在的目录 | 删掉这些记录与引用（`health-fix`，默认试运行） |

两者症状相同、核对与修复逻辑也相同，所以工具不分家：`health-check` 逐项核对"**登记指向的目标是否真的存在**"；`health-fix` 分两段处理（A 段：程序还在、只是搬走了 → 改路径；B 段：确认已卸载 → 删记录）。

本项目最初的起因是一次真实事故（成因①）：把 D 盘的应用搬了家、又改过用户目录名。善后时才发现**迁移还会把部分文件本身弄坏** —— 那些不常用的软件索性卸载，卸完就撞上了成因②。完整过程与证据见[案例报告](docs/case-report-d-apps-migration.md)。

## 效果（本机实测，一台真实笔记本）

| 指标 | 处理前 | 处理后 | 复核方式 |
|---|---|---|---|
| 体检"严重"项 | 12 | **7**（全部为有意保留，见下） | 🔒 作者本机：`local/reports/ps51`、`ps7`、`final` 三份 `findings.csv` —— 该目录**已被 gitignore，不在仓库里** |
| 双引擎一致性 | —— | 同一脚本在 PowerShell **5.1** 与 **7.6** 下结果**逐条相同**（`Compare-Object` 0 差异） | 🔒 作者本机：比对 `local/reports/ps51` 与 `ps7` —— 不在仓库里 |
| 回滚备份 | —— | **545 个 `.reg`**，每条改动前导出 | 🔒 作者本机：`local/rollback/` —— **已被 gitignore，不在仓库里** |
| 失效文件关联 / 卸载记录 / App Paths / 协议 / 服务 / 命名空间图标 | 213 / 22 / 15 / 14 / 10 / 1 | 0（Adobe 半残留 3 项刻意保留） | ⚠️ 见[案例报告](docs/case-report-d-apps-migration.md)的过程记录 |
| 修复规模 | —— | 约 **400 个注册表键** + 约 **290 处引用** + 11 处路径改指 | ⚠️ 同上 |
| 事故**最初**一轮基线 | **282** 项严重 | —— | ❌ 那份报告没有留在仓库里 |

> 这张表刻意标出**能不能复核**，并且要诚实说明：**本案例的可复现产物一律不在仓库里** ——
> 它们是作者本机的注册表数据（`local/` 已被 gitignore：`rollback/` 里的 `.reg` 备份、体检报告、日志）。
>
> - **🔒** 只有作者本机能核对。你可以在自己机器上重跑脚本，得到属于**你自己机器**的同类数字
>   （那才是这些脚本的用途）；但本表的数字来自那一台笔记本，无法在仓库内复现。
> - **⚠️** 是案例报告里的过程记录 —— 是真的，但没有对应产物文件，请当**叙述**读，别当证据。
> - **❌** 那份报告当时就没有留存。
>
> 仓库里**真正可复核**的是方法与脚本本身：`tests/` 覆盖了全部安全不变量（默认试运行、删除门禁、
> 映射顺序、编码与行尾、双引擎语法……），CI 会在干净检出上跑同一套。

**有意保留的 7 项**：Steam 游戏记录 ×3 与 `AntiCheatExpert`（由各自启动器自我维护，删了会被重建）、Adobe `PHSP_24_7`/`UXPW_1_1_0`（其卸载器仍存在，属半残留，宜用 Adobe 官方清理工具或 Geek Uninstaller 处理）。

## 三个脚本

| 脚本 | 作用 | 安全设计 |
|---|---|---|
| [health-check.ps1](scripts/health-check.ps1) | **只读体检**：核对 12 类"程序位置登记"、孤儿安装缓存、旧路径残留、磁盘容量与增长 | 绝不修改任何东西；报告**边跑边写**，运行中即可打开看进度 |
| [health-fix.ps1](scripts/health-fix.ps1) | **按规则清理残留**：能改路径的改路径（程序只是搬走了），确认没了的删记录（含引用清理） | 默认**试运行**，`-Apply` 才写入（需要管理员）；每条改动前 `reg export` 到 `local/rollback/<运行时间戳>/`，**备份失败则该条改动被跳过** |
| [repair-migrated-apps.ps1](scripts/repair-migrated-apps.ps1) | **批量路径迁移修复**：按"旧路径 → 新路径"映射表改写注册表 | 默认试运行（`.cmd` 与 `.ps1` 一致：不带参数即试运行）；写入前检查目标文件是否真的存在（不把死路径改成另一个死路径）；映射表在 `local/repair-migrated-apps.local.psd1` |

三者都用 `.cmd` 启动器包装：**优先 `pwsh`（PowerShell 7.x），找不到才回退 5.1**。

> **执行顺序很重要**：`health-check`（体检）→ `repair-migrated-apps`（把搬走的程序改指回去）
> → 再 `health-check` 复检 → 确认没有可改指的了，最后才 `health-fix`（清理确认为残留的记录）。
> 顺序反了会白干：`health-fix` 会把"目标暂时找不到"的记录直接删掉，而那条记录本来正是
> `repair-migrated-apps` 要改写回来的。

## 快速开始

```bat
rem 1) 体检（只读，不需要管理员）——双击即可
scripts\health-check.cmd
rem    嫌慢可编辑该文件，把 set "SKIP=" 改成 set "SKIP=-SkipOldPathScan"

rem 2) 清理（默认试运行；-Apply 才写入，需要管理员权限——请从已提权的窗口运行）
scripts\health-fix.cmd
scripts\health-fix.cmd -Apply

rem 3) 迁移修复：先把"旧 → 新"映射填进 local\repair-migrated-apps.local.psd1
rem    不带参数 = 试运行（只打印计划，不需要管理员）
scripts\repair-migrated-apps.cmd
rem    确认输出无误后再写入（会弹 UAC）
scripts\repair-migrated-apps.cmd -Apply
```

命令行等价写法：

```powershell
pwsh      -NoProfile -ExecutionPolicy Bypass -File .\scripts\health-check.ps1    # 用 7.x
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\health-check.ps1    # 用 5.1
```

**体检报告**落在 `local/reports/<时间戳>/`：`report.md`（人读）+ `findings.csv`（逐条明细）+ `snapshot.json`（与上次对比磁盘增长）。

体检常用开关：`-SkipOldPathScan`（跳过最慢的全注册表旧路径扫描）、`-SkipAssocScan`、`-SkipClsidScan`、`-SizeScan`（统计 `%LOCALAPPDATA%`/`%APPDATA%` 体积；**没有 WizTree 时的兜底**，有 WizTree 就直接用它）、`-WarnFreePercent 15`。

## 体检覆盖的 12 类"程序位置登记"

迁移的本质不是"移动文件"，而是**移动文件 + 同步这些登记**。少改任何一类，都会表现为"Windows 认不出这个程序"：

**卸载记录** · **App Paths** · **文件关联** · **打开方式动词** · **右键菜单** · **CLSID 外壳扩展** · **命名空间图标** · **协议处理** · **自动播放/默认程序** · **服务与驱动** · **计划任务/启动项/PATH** · **快捷方式**

每一类的**登记位置、失效表现、修复动作**（以及"哪三类不要乱动"）见 **[docs/registry-reference.md](docs/registry-reference.md)**——那是这 12 类的唯一定义处，本文不重复。

## 关键设计（都是踩坑换来的）

| 设计 | 原因 |
|---|---|
| **只读优先**：体检脚本绝不修改系统 | 可以先放心跑，用它代替"出事后再排查" |
| **改前必备份**：`health-fix` 每条改动前 `reg export` 到 `local/rollback/<运行时间戳>/` | 本机累计 **545 个 `.reg`**，覆盖 560+ 处取值改动（一个 `.reg` 备份一个键，键下可能有多处改动），全部可逐条回滚；**备份失败则该条改动被跳过**，且第二次跑不会覆盖第一次的原始备份 |
| **报告不许有假绿**：清单为空/全是占位符、或用了 `-Skip*` 开关时，报告明确写"本节未执行检查"并记入 `findings.csv`；测试框架里"跳过"也要计数并打印 `[SKIP]` | 旧实现只看"命中 0 个键"就打印"✓ 回归检查通过"，于是**没配置清单也会得到一张绿报告**——和第 3 行那条假阴性是同一类 |
| **"读不到" ≠ "不存在"**：权限受限的路径判为 `denied` 并跳过 | 曾经把 `D:\WinRAR`（真实存在）误报成损坏；把权限问题当残留删掉是不可逆事故 |
| **双引擎兼容**（5.1 / 7.x） | PS7 会把 .NET 异常包成 `MethodInvocationException`，按类型 `catch` 会**永远匹配不上** → 所有"缺失"被判成"读不到"，报告变成"一切正常"的假阴性（实测同一脚本 5.1 报 43 项、PS7 只报 1 项）。详见[案例报告 附录 A.4](docs/case-report-d-apps-migration.md) |
| **按目标聚合 + CSV 明细** | 一个组件的残留能刷出几百行（如 Photoshop 的 89 条关联），聚合后才看得见真问题 |
| **保守删除规则** | Steam/ACE 交给启动器；Adobe 半残留保留；只有"安装目录与卸载器都不存在"才删 |
| **每段打印计数** | 曾因脚本漏定义一个函数导致**整段静默跳过**而没被发现 |
| **脚本零依赖**（刻意不调用 WizTree / Everything / Beyond Compare） | 发布物要能在任意 Windows 上独立运行；这些工具用于**探索与交叉验证**，脚本负责**执行与留痕** |

## 目录结构

| 路径 | 内容 |
|---|---|
| [scripts/](scripts/) | 现行脚本（3 个 `.ps1` + 3 个 `.cmd` 启动器） |
| [scripts/dev/fix-encoding.ps1](scripts/dev/fix-encoding.ps1) | **开发工具**：补 BOM、统一 `.cmd` 行尾（默认试运行） |
| [docs/](docs/README.md) | **文档索引**：四篇文档该看哪篇 |
| [docs/disk-health.md](docs/disk-health.md) | **磁盘长期健康管理**：各盘放什么、体检阈值、安全清理清单、备份 3-2-1、例行节奏 |
| [docs/migration-checklist.md](docs/migration-checklist.md) | **大批量迁移避坑清单**：阶段 0~3（该不该迁 → 基线快照 → robocopy → 复检登记与验收）+ 台账模板 |
| [docs/registry-reference.md](docs/registry-reference.md) | **12 类登记参考**：每类的位置/失效表现/修复动作、统一检查方法、脚本对应关系、三类别乱动 |
| [docs/case-report-d-apps-migration.md](docs/case-report-d-apps-migration.md) | **完整案例报告**：本次 D 盘应用迁移的逐项排查、修复与验证记录 |
| [versions/README.md](versions/README.md) | 版本档案：`v1-ps5.1`（旧）/ `v2-ps7.6`（当前）+ 双引擎验收证据 |
| [config/](config/) | 配置模板：`health-check.needles.example.txt`（旧路径清单，复制到 `scripts\health-check.needles.txt`）、`*.local.example.psd1`（机器专属映射，复制到 `local/` 后填真值） |
| [tests/](tests/) | **零依赖测试套件**：语法、编码卫生、删除门禁、映射顺序；`tests\run-tests.cmd` 会在 5.1 与 7.x 下各跑一遍 |
| [.githooks/](.githooks/) | **pre-commit 钩子**：提交前跑编码/行尾检查；用 `scripts\dev\install-hooks.ps1` 启用 |
| `local/` | **个人产物，已 gitignore**：机器专属配置（`*.local.psd1`）、注册表备份、体检报告、日志（见 [local/README.md](local/README.md)） |

## 隐私与个人数据（重要）

- `local/` 目录存放**本机个人产物**（545 个注册表备份、体检报告、日志），已由 [.gitignore](.gitignore) 排除，不会进仓库。
- `docs/` 里的案例报告经**脱敏**后保留本机真实场景（软件名、注册表键路径、磁盘布局），个人标识已替换为 `<user>` / `<旧用户名>` / `<PC>` / `<工作区>` 等占位符——详见下节「脱敏说明」。
- 脚本本身**不含任何机器专属信息**（旧路径映射表需要你按自己环境填写）。

## 本机实测环境

Windows 11 x64 · **PowerShell 7.6.6 (Core)** + Windows PowerShell 5.1.26100 双引擎验证 ·
磁盘 C: 237 GB / D: 238 GB / E: 954 GB ·
配套工具：[Everything](https://www.voidtools.com/)（检索）、[WizTree](https://diskanalyzer.com/)（占用分析）、Geek Uninstaller（孤儿记录）、Registry Finder / RegScanner（注册表搜索对比）、Beyond Compare（备份校验）。这些工具用于**探索与交叉验证**，脚本本身刻意不依赖它们。

## 相关项目

本仓库的 `AGENTS.md` 由本机的新项目起步模板生成：它的**上半部分是本机私有**的约定（这台机器上
装了 Everything / WizTree / Beyond Compare / 浏览器自动化，供 AI 代理做探索与交叉验证），
下半部分才是本仓库的项目约定。只想用脚本的话，上半部分可以完全忽略。

## 开发与提交约定

```powershell
.\tests\run-tests.cmd                          # 全部测试（双引擎）；慢速集成测试默认跳过
$env:SLOW_TESTS=1; .\tests\run-tests.cmd   # 连"真跑一次体检"的集成测试一起跑
.\scripts\dev\fix-encoding.ps1                 # 试运行：看哪些文件的编码/行尾不合规
.\scripts\dev\fix-encoding.ps1 -Apply          # 补 BOM、统一 .cmd 行尾
.\scripts\dev\install-hooks.ps1                # 启用 pre-commit 钩子（每个 clone 各做一次）
```

三条硬约定（都来自真踩过的坑，`tests\` 与 CI 会拦）：

1. **`.ps1` / `.psd1` 必须 UTF-8 带 BOM**。Windows PowerShell 5.1 读无 BOM 的文件会按 ANSI 解码 →
   中文注释全乱码 → 报出上百个**假**语法错误；而 pwsh 7 完全正常，所以这个坑**只在 5.1 暴露**。
   麻烦在于：多数文本工具（编辑器、批量替换、AI 编辑工具）写回时都会把 BOM 丢掉。改完跑一次
   `fix-encoding.ps1 -Apply` 即可。
2. **`.cmd` 必须纯 ASCII**（`cmd.exe` 按代码页读批处理，中文注释会变成 `?`），且行尾为 CRLF。
3. **`.githooks/pre-commit` 必须是 LF**（它由 `sh` 执行；CRLF 会让 shebang 变成 `#!/bin/sh\r`，
   报 bad interpreter —— 而且钩子连报错的机会都没有，因为它自己就是那个执行不了的文件）。

pre-commit 钩子只是**便利层**：它不会随 clone 自动安装。真正的保证层是 `tests\`（随时可跑）
和 CI（在干净检出上跑同一套）。临时跳过钩子：`git commit --no-verify`。

### 只装了 Microsoft Store 版 pwsh 时会看到什么（不是仓库的问题）

`tests\run-tests.ps1` 在启动每个引擎之前会先自检"能不能被本进程启动并捕获输出"。如果 `pwsh` 只有
**Microsoft Store（MSIX）版**，而运行器正跑在 **Windows PowerShell 5.1** 下，自检会失败，于是它明确跳过：

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

1. 用 `pwsh` 跑运行器（推荐）——`tests\run-tests.cmd` 本来就会**优先 `pwsh`**，找不到才回退 5.1；
2. 装 MSI / zip 版 PowerShell 7（装在 `C:\Program Files\PowerShell\7\`，不受此限制）；
3. 明确只要 5.1：`.\tests\run-tests.ps1 -Engine powershell`。

## 许可

[MIT](LICENSE) © 2026 NeedyNeet

## 脱敏说明

本仓库整理自一次真实的迁移事故复盘，发布前已对**个人标识**做脱敏：

| 原值 | 仓库中的写法 |
|---|---|
| Windows 账户名 / 用户目录 | `C:\Users\<user>` |
| 改名前的旧用户目录 | `C:\Users\<旧用户名>` |
| 计算机名 | `<PC>` |
| 会话工作区路径 | `<工作区>` |

- **保留**了软件名、注册表键路径、GUID、磁盘布局等——它们是本案例的实质内容，且不含任何凭据。
- `local/`（注册表备份、体检报告、日志）**从未纳入仓库**：那里是真实的机器数据。
- 脚本里的机器专属示例值（旧用户目录名、迁移路径映射表）在仓库版中是占位符；要在自己机器上运行，替换为真实值即可。
