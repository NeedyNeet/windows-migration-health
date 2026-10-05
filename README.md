# windows-migration-health

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-5391FE)
![Platform](https://img.shields.io/badge/platform-Windows-0078D4)
![License](https://img.shields.io/badge/license-MIT-green)
[![ci](https://github.com/NeedyNeet/windows-migration-health/actions/workflows/ci.yml/badge.svg)](https://github.com/NeedyNeet/windows-migration-health/actions/workflows/ci.yml)

> 🧭 Windows **「程序位置登记」一致性**工具集：核对并修复那些"**登记指向的东西已经不在**"的地方，附带长期磁盘健康体检。
> 纯 PowerShell，**零第三方依赖**，5.1 与 7.x 双引擎。

## 😣 你遇到的是这个症状吗

**三种成因，同一个症状** —— "文件还在（或程序还在），但 Windows 认不出来"：双击文件打不开、开始菜单搜不到、
`Win+R` 输程序名没反应、"设置 → 应用"里的卸载/修复按钮失效。

| 成因 | 怎么发生的 | 处理方式 |
|---|---|---|
| **① 迁移** 🚚 | 把应用搬了家、或改过用户目录名：文件到了新位置，系统里 12 类登记还指着旧路径 | 登记改指新路径（`repair-migrated-apps`）；**文件本身别动** |
| **② 卸载残留** 🗑️ | 卸载器删了程序，却把登记留在注册表里、指向已不存在的目录 | 删掉这些记录与引用（`health-fix`，默认试运行） |
| **③ 安装器写坏（编码）** 🐛 | 安装器把中文路径写成乱码（UTF-8 字节按 GBK 解释），**登记从第一刻起就没指向过真实路径** | 改指到真实目录（同 ①）；但根因在安装器，**重装可能再写坏一次** |

三种成因症状相同、核对与修复逻辑也相同，所以工具不分家：`health-check` 逐项核对"登记指向的目标是否真的存在"。
本项目起因是一次真实事故（成因①）——完整过程与证据见[案例报告](docs/case-report-d-apps-migration.md)。

## 📌 目录

> 锚点按 GitHub 实测形式写：emoji 会被去掉，其后的空格变成**前导连字符**（`## 🚀 快速开始` → `#-快速开始`）。
> 带变体选择符的 emoji（如 `🛠️`）会在锚点里留下一个**不可见字符**，所以这里刻意只用无变体选择符的 emoji。

- [症状与三种成因](#-你遇到的是这个症状吗) · [快速开始](#-快速开始) · [三个脚本](#-三个脚本)
- [覆盖范围](#-覆盖范围体检的-12-类登记) · [效果与验收](#-效果与验收本机实测) · [目录结构](#-目录结构)
- [隐私](#-隐私与个人数据) · [开发与提交约定](#-开发与提交约定) · [环境与相关](#-环境与相关) · [许可](#-许可)

## 🚀 快速开始

```bat
rem ① 体检（只读，不需要管理员）—— 双击即可；嫌慢可编辑该文件把 set "SKIP=" 改成 set "SKIP=-SkipOldPathScan"
scripts\health-check.cmd

rem ② 迁移修复：先把"旧 → 新"映射填进 local\repair-migrated-apps.local.psd1
rem    不知道旧路径有哪些？先让脚本给一版候选草稿（只读，也不写注册表）
scripts\repair-migrated-apps.cmd -DiscoverTargets
rem    不带参数 = 试运行（只打印计划，不需要管理员）；确认无误后再写入（会弹 UAC）
scripts\repair-migrated-apps.cmd
scripts\repair-migrated-apps.cmd -Apply

rem ③ 清理确认为残留的记录（默认试运行；-Apply 才写入，需要管理员权限）
scripts\health-fix.cmd
scripts\health-fix.cmd -Apply
```

> ⚠️ **执行顺序很重要**：体检 → 改指 → 复检 → 最后才清残留。
> 顺序反了会白干：`health-fix` 会把"目标暂时找不到"的记录直接删掉，而那条记录本来正是 `repair-migrated-apps`
> 要改写回来的。

**体检报告**落在 `local/reports/<时间戳>/`：`report.md`（人读）+ `findings.csv`（逐条明细）+ `snapshot.json`（与上次对比磁盘增长）。
常用开关：`-SkipOldPathScan`（跳过最慢的全注册表旧路径扫描）、`-SkipAssocScan`、`-SkipClsidScan`、
`-SizeScan`、`-WarnFreePercent 15`、`-ScanConfigFiles -AppsRoot <目录>`。三个启动器都是
**优先 `pwsh`（7.x），找不到才回退 5.1**；命令行等价写法：

```powershell
pwsh      -NoProfile -ExecutionPolicy Bypass -File .\scripts\health-check.ps1   # 7.x
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\health-check.ps1   # 5.1
```

## 🧰 三个脚本

| 脚本 | 作用 | 安全设计 |
|---|---|---|
| [health-check.ps1](scripts/health-check.ps1) | **只读体检**：12 类登记、孤儿安装缓存、旧路径残留、磁盘容量与增长 | 绝不修改任何东西；报告**边跑边写**，运行中就能打开看进度 |
| [repair-migrated-apps.ps1](scripts/repair-migrated-apps.ps1) | **批量路径迁移修复**：按"旧 → 新"映射表改写注册表 | 默认试运行；写入前检查目标**是否真的存在**（不把死路径改成另一个死路径）；映射表在 `local\repair-migrated-apps.local.psd1` ——**脚本里一条具体路径都没有**，没配映射时明确报"未执行有效检查"并以**退出码 3** 结束 |
| [health-fix.ps1](scripts/health-fix.ps1) | **按规则清理残留**：能改路径的改路径，确认没了的删记录（含引用清理） | 默认试运行，`-Apply` 才写入（需管理员）；**每条改动前 `reg export`**，备份失败则该条跳过；本机配置**读不到或语法坏了会明确报错并 exit 3**，不许静默降级 |

## 📋 覆盖范围：体检的 12 类登记

迁移的本质不是"移动文件"，而是**移动文件 + 同步这些登记**。少改任何一类，都会表现为"Windows 认不出这个程序"：

**卸载记录** · **App Paths** · **文件关联** · **打开方式动词** · **右键菜单** · **CLSID 外壳扩展** ·
**命名空间图标** · **协议处理** · **自动播放/默认程序** · **服务与驱动** · **计划任务/启动项/PATH** · **快捷方式**

每一类的**登记位置、失效表现、修复动作**（以及"哪三类不要乱动"）见 [docs/registry-reference.md](docs/registry-reference.md) —— 那是这 12 类的唯一定义处，本文不重复。

## 📊 效果与验收（本机实测）

| 指标 | 处理前 | 处理后 | 复核方式 |
|---|---|---|---|
| 体检"严重"项 | 12 | **7**（全部有意保留） | 🔒 作者本机 `local/reports/`（已 gitignore，不在仓库里） |
| 失效文件关联 / 卸载记录 / App Paths / 协议 / 服务 / 命名空间图标 | 213 / 22 / 15 / 14 / 10 / 1 | 0（Adobe 半残留 3 项刻意保留） | ⚠️ 见[案例报告](docs/case-report-d-apps-migration.md)的过程记录 |
| 修复规模 | —— | 约 **400 个注册表键** + 约 **290 处引用** + 11 处路径改指 | ⚠️ 同上 |
| 回滚备份 | —— | **545 个 `.reg`**，每条改动前导出 | 🔒 作者本机 `local/rollback/`（不在仓库里） |
| 双引擎一致性 | —— | 5.1 与 7.6 下 `findings.csv` **逐行 0 差异**（受控输入：清单是套件自己造的临时 ProgID，因此结果**确定**；全类别逐行比对，两次快照之间系统被改动时会自动重跑一次再判） | [tests/health-check.dualengine.tests.ps1](tests/health-check.dualengine.tests.ps1)（`SLOW_TESTS=1`，CI 上跑；这一项约 3 分钟） |

> **诚实说明**：上表 🔒 的数据是作者本机（一台真实笔记本）的注册表数据，**可复现产物一律不在仓库里** ——
> 你可以在自己机器上重跑脚本得到**属于你自己机器**的同类数字，那才是这些脚本的用途；⚠️ 的行请当**叙述**读，
> 别当证据。仓库里**真正可复核**的是方法与脚本本身：`tests/` 覆盖了全部安全不变量，CI 会在干净检出上跑同一套。
>
> 另有两点容易误读：① 表中"严重 7"取自**第 7 节修复前**的体检，那一节当时实际只检查了 0 项；修好后同一台机器
> 的"严重"是 **371** —— 多出来的 364 条全是此前**从未检查过**的 CLSID 登记。② **"严重"≠"要动"**：
> Steam 游戏记录 ×3 与 `AntiCheatExpert` 由启动器自我维护，Adobe `PHSP_24_7`/`UXPW_1_1_0` 属半残留 ——
> 共 7 项刻意保留。判断依据见 [docs/design-notes.md](docs/design-notes.md)。

## 📁 目录结构

| 路径 | 内容 |
|---|---|
| [scripts/](scripts/) | 现行脚本（3 个 `.ps1` + 3 个 `.cmd` 启动器 + `dev/` 开发工具） |
| [docs/](docs/README.md) | **文档索引**：六篇文档该看哪篇 —— 12 类登记参考、迁移清单、磁盘健康、案例报告、设计取舍、排错 |
| [config/](config/) | 配置模板：旧路径清单、`*.local.example.psd1`（机器专属映射，复制到 `local/` 后填真值） |
| [tests/](tests/) | **零依赖测试套件**：语法、编码卫生、删除门禁、映射顺序；`tests\run-tests.cmd` 在 5.1 与 7.x 下各跑一遍 |
| [CHANGELOG.md](CHANGELOG.md) | **变更记录**：升级前先看标题带 ⚠ 的那一节（v2.2 把迁移映射表搬出了脚本） |
| [.githooks/](.githooks/) | **pre-commit 钩子**（编码/行尾检查）；用 `scripts\dev\install-hooks.ps1` 启用 |
| [versions/](versions/README.md) | 版本档案：`v1-ps5.1`（旧）/ `v2-ps7.6`（冻结档案；现行版本在 [scripts/](scripts/)）+ 双引擎验收证据 |
| `local/` | **个人产物，已 gitignore**：机器专属配置、注册表备份、体检报告、日志（见 [local/README.md](local/README.md)） |

## 🔒 隐私与个人数据

- `local/` 存放**本机个人产物**（注册表备份、体检报告、日志），已由 [.gitignore](.gitignore) 排除，不会进仓库。
- 脚本本身**不含任何机器专属信息**；`docs/` 里的案例报告已脱敏（`<user>` / `<旧用户名>` / `<PC>` / `<工作区>`）。
- ⚠️ **你自己的 `local/` 产物含个人标识，分享前请脱敏**：`reports/*/report.md` 开头就写着计算机名与用户名，
  明细里是全部程序路径；`rollback/*.reg` 是你注册表的完整内容（可能含许可信息）。

## 🔧 开发与提交约定

```powershell
.\tests\run-tests.cmd                          # 全部测试（双引擎）；慢速集成测试默认跳过
$env:SLOW_TESTS=1; .\tests\run-tests.cmd       # 连"真跑一次体检"的集成测试一起跑
.\scripts\dev\fix-encoding.ps1                 # 试运行：看哪些文件编码/行尾不合规（-Apply 修正）
.\scripts\dev\install-hooks.ps1                # 启用 pre-commit 钩子（每个 clone 各做一次）
```

三条硬约定（都来自真踩过的坑，`tests\` 与 CI 会拦）：

1. **`.ps1` / `.psd1` 必须 UTF-8 带 BOM** —— 5.1 读无 BOM 文件会按 ANSI 解码，报出上百个**假**语法错误（pwsh 7 完全正常，所以这个坑只在 5.1 暴露）；多数编辑器与工具写回时会丢 BOM，改完跑一次 `fix-encoding.ps1 -Apply`。
2. **`.cmd` 必须纯 ASCII + CRLF**（`cmd.exe` 按代码页读批处理，中文注释会变成 `?`）。
3. **`.githooks/pre-commit` 必须是 LF**（由 `sh` 执行；CRLF 会让 shebang 变成 `#!/bin/sh\r`）。

pre-commit 钩子只是**便利层**（不随 clone 自动安装）；真正的保证层是 `tests\` 与 CI。临时跳过：`git commit --no-verify`。

> 💡 只装了 **Microsoft Store 版 pwsh**？测试会跳过不可用的引擎、`.cmd` 的输出重定向会失效 ——
> 这两件事的原因与三种解法见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 🌍 环境与相关

Windows 11 x64 · PowerShell **7.6.6** + Windows PowerShell **5.1.26100** 双引擎验证 · C: 237 GB / D: 238 GB / E: 954 GB。
配套工具（[Everything](https://www.voidtools.com/) / [WizTree](https://diskanalyzer.com/) / Geek Uninstaller / RegScanner / Beyond Compare）
用于**探索与交叉验证**，脚本本身刻意不依赖它们。

本仓库的 `AGENTS.md` 上半部分是**本机私有**的约定（这台机器装了上述工具，供 AI 代理做探索），
下半部分才是本仓库的项目约定 —— 只想用脚本的话，上半部分可以完全忽略。

## 📄 许可

[MIT](LICENSE) © 2026 NeedyNeet
