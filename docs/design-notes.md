# 设计取舍：每一条都是踩坑换来的

**给谁看**：想评估"这些脚本凭什么可信"的人，或准备改动它们的人。
**什么时候看**：读完根 [README](../README.md) 之后；或者当你想删掉某段"看起来多余"的检查时 —— **先来这里看它为什么存在**。
**看完能得到什么**：知道哪 8 条设计各自对应哪次真实事故、由哪个**执行者**守着，于是分得清"看起来可以简化"和"其实不能动"。

| # | 设计 | 为什么（对应的真实事故） | 执行者 |
|---|---|---|---|
| 1 | **只读优先**：体检脚本绝不修改系统 | 可以先放心跑，用它代替"出事之后再排查" | `tests\health-check.*.tests.ps1`；脚本本身无写入调用 |
| 2 | **改前必备份**：`health-fix` / `repair-migrated-apps` 每条改动前 `reg export` 到 `local/rollback/<运行时间戳>/` | 本机累计 **545 个 `.reg`**，覆盖 560+ 处取值改动（一个备份对应一个键，键下可能有多处改动），全部可逐条回滚；**备份失败则该条改动被跳过**；第二次跑不会覆盖第一次的原始备份 | `tests\health-fix.gate.tests.ps1`（备份失败必须跳过） |
| 3 | **报告不许有假绿**：清单为空/全是占位符、或用了 `-Skip*` 开关时，报告明确写"未执行有效检查"并记入 `findings.csv`；测试框架里"跳过"也要计数并打印 `[SKIP]` | 旧实现只看"命中 0 个键"就打印 `✓ 回归检查通过` —— 于是**没配置清单也能拿到一张绿报告** | `tests\health-check.needles.tests.ps1`、`tests\harness.canary.tests.ps1`、`tests\lint.tests.ps1` |
| 4 | **"读不到" ≠ "不存在"**：权限受限的路径判为 `denied` 并跳过 | 曾把 `D:\WinRAR`（真实存在）误报成损坏；**把权限问题当残留删掉是不可逆事故** | `tests\health-check.configscan.tests.ps1`、`tests\repair.exists.tests.ps1` |
| 5 | **双引擎兼容**（5.1 / 7.x） | PS7 会把 .NET 异常包成 `MethodInvocationException`，按类型 `catch` 会**永远匹配不上** → 所有"缺失"被判成"读不到"，报告变成"一切正常"的假阴性（实测同一脚本 5.1 报 43 项、PS7 只报 1 项） | `tests\health-check.dualengine.tests.ps1`（两引擎逐行比对 `findings.csv`）＋ CI 的 `pwsh`/`powershell` 矩阵 |
| 6 | **按目标聚合 + CSV 明细** | 一个组件的残留能刷出几百行（如 Photoshop 的 89 条关联），聚合之后才看得见真问题 | `health-check` 的报告生成 + `findings.csv` |
| 7 | **保守删除规则** | Steam / `AntiCheatExpert` 交给各自启动器（删了会被重建）；Adobe 半残留保留（卸载器还在，宜用官方清理工具）；只有"安装目录与卸载器**都不存在**"才删 | `health-fix` 的 B 段判据 + `tests\health-fix.gate.tests.ps1` |
| 8 | **每段打印计数** | 曾因脚本漏定义一个函数导致**整段静默跳过**而没被发现 | `tests\conventions.tests.ps1`（约定必须有执行者） |
| 9 | **脚本零依赖**（刻意不调用 WizTree / Everything / Beyond Compare） | 发布物要能在任意 Windows 上独立运行；那些工具用于**探索与交叉验证**，脚本负责**执行与留痕** | `tests\lint.tests.ps1`（`scripts\` 下不得出现机器专属路径、不得调用不存在的 .NET 成员等） |

## 有意保留的那几项（"体检报严重 ≠ 一定要动"）

本机修复后仍有 **7 项严重**，全部是**刻意保留**的：

- Steam 游戏记录 ×3 与 `AntiCheatExpert` —— 由各自启动器自我维护，删了会被重建；
- Adobe `PHSP_24_7` / `UXPW_1_1_0` —— 其卸载器仍存在，属"半残留"，宜用 Adobe 官方清理工具或 Geek Uninstaller 处理。

**这是本项目的态度**：报告只负责"如实说出登记指向的目标是否真的存在"，**要不要动由人决定**；
工具不会因为"看起来是残留"就替你删。

## 下一步看哪篇

想排错 → [troubleshooting.md](troubleshooting.md)；想动手搬家 → [migration-checklist.md](migration-checklist.md)；想理解 12 类登记 → [registry-reference.md](registry-reference.md)。
