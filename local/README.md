# local/ —— 个人产物（**已 gitignore，不会进仓库**）

这个目录存放"只对本机有意义、且可能含个人隐私"的东西。脚本运行时会自动往这里写。

> ⚠ **分享前请先脱敏。** 这里的东西含**计算机名、用户名（包括改名前的旧用户名）、全部程序路径**：
> `reports/*/report.md` 的第三行就写着计算机名与用户名，明细里是逐条路径；
> `rollback/*.reg` 是你注册表的完整内容（可能含产品许可信息）。要把报告贴给别人看时，
> 请照本仓库 `docs/` 案例报告的做法，把这些标识符换成 `<PC>` / `<user>` / `<旧用户名>`。

| 子目录/文件 | 内容 | 来源 |
|---|---|---|
| `rollback/<运行时间戳>/` | **注册表备份**：每条改动前用 `reg export` 导出的 `.reg`（每次运行一个子目录，所以第二次跑不会覆盖第一次的原始备份）+ 批量删除清单 | `health-fix.ps1` 与 `repair-migrated-apps.ps1`（`Backup-Key`） |
| `health-fix.local.psd1`、`repair-migrated-apps.local.psd1` | **本机真值配置**：旧用户目录名、路径改指表、迁移映射表、缺失快捷方式清单、验收清单（模板见 `config\*.local.example.psd1`） | 手工维护；两个脚本启动时读取 |
| `reports/` | 体检报告：`report.md`（人读）、`findings.csv`（逐条明细）、`snapshot.json`（磁盘增长基线）、`history/` | `health-check.ps1 -OutDir local\reports` |
| `health-fix-log.txt` | 清理脚本的详细日志（含每一条改动与统计） | `health-fix.ps1` |
| `remove-residue.ps1` + `delete-targets.psd1` | **本机自建工具**：按清单删"确认已卸载"的登记。默认试运行；每条改动前 `reg export`；备份失败即跳过；`-Apply` 时生成 `rollback-all.cmd`。清单每条写明动作（删整键/删子键/删值）、路径、是否走 32 位视图 | 手工运行（清单由体检报告 + 处置复核生成） |
| `fix-ie-clsid.ps1` + `fix-ie-clsid.cmd` | **本机一次性收尾**：删掉 `{0002DF01-…}`（IE 的 CLSID）被 360 劫持的 `LocalServer32`。该键 DACL 只给 Administrators `ReadKey`，故脚本走"夺取所有权 → 授权 → 再删"并留档原 SDDL；默认试运行，`-Apply` 才写（`.cmd` 自提权） | 手工运行 |

### 迁移映射表现在**只**在这里（重要）

2026-10-05 起，`scripts\repair-migrated-apps.ps1` 里**一条具体路径都没有**了（硬性约定 8）：
原来写死在脚本里的 8 条"旧位置 → 新位置"映射、以及 2 条"整条缺失的开始菜单快捷方式"
都搬进了本目录的 `repair-migrated-apps.local.psd1`（见该文件头部的"合并（二）"注释）。

- 因此 `repair-migrated-apps.local.psd1` 是映射表的**唯一来源**：换机器 / 重装后没有它，
  `repair` 会明确报"**未执行有效检查**"并以**退出码 3** 结束 —— 那是"没查"，不是"没事"。
- 同类防护也覆盖了"读不到 / 写坏了"这两种情况：配置文件**读不到**（ACL）或**语法坏了**时，
  `repair` 与 `health-fix` 都会明确报错并 `exit 3`，不会静默降级成"没有本机规则"。
- 这个文件里现在有四块：`PathMap`（旧→新，**顺序敏感：更具体的旧前缀必须写在前面**）、
  `ProfileMap`（用户目录改名）、`MissingShortcuts`（缺失的整条快捷方式）、`VerifyPaths`（跑完后的验收清单）。
- 改动前建议先留一份 `.bak-<时间戳>`（本仓库的惯例），`PathMap` 里带版本号的条目
  （如 `app-3.19.0`）会随程序升级腐烂，需要跟着更新。

> **为什么这两个工具在 `local\` 而不在 `scripts\`**：它们只对本机有意义 —— 一个依赖本机的删除清单，另一个硬编码了本机那个被劫持的 IE CLSID。`scripts\` 只放"面向所有人、零第三方依赖"的三个脚本。
>
> 副作用要知道：`tests\syntax.tests.ps1` 与 `tests\lint.tests.ps1` **只扫 `scripts\` 与 `tests\`**，所以这两个文件不受它们约束；而 `tests\encoding.tests.ps1` 是全仓库递归的，BOM / 纯 ASCII / CRLF 仍然管着它们。

> **历史**：早期版本的 `health-fix.cmd` 会把控制台输出重定向到 `health-fix-elevated.txt`。
> cmd 的重定向走的是 OEM 代码页（中文系统上是 936），那个文件因此是 **GBK 乱码**。
> 现在启动器不再重定向——脚本自己写的 `health-fix-log.txt` 已经是完整的 UTF-8 日志。
> 旧的 `health-fix-elevated.txt` 若还在，属历史产物，可以删。

## 为什么单独放这里

1. **隐私**：`.reg` 备份里有真实路径、用户名、已安装软件清单；体检报告里有机器名与磁盘信息。放进公开仓库等于把这些一起公开。
2. **体积与噪音**：几百个 `.reg` 与报告文件会淹没仓库的 diff。

## 怎么用这些备份

```powershell
# 还原某一个键（先看清文件名对应哪个注册表路径）
reg import .\local\rollback\HKLM_SOFTWARE_..._IntelliJ IDEA 2024.2.2.reg

# 批量删除清单（人工核对用，不要盲目导入）
notepad .\local\rollback\deleted-registry-keys-*.txt
```

> 注意：`.reg` 备份是"改动**之前**的状态"，导入即回滚。导入前请确认你确实要回滚那一项。
> 历史提示：早期版本的 repair-migrated-apps.ps1 把备份写在桌面上的 Apps-repair-backup/ 目录（本机 92 个 .reg）；新版已统一写入本目录。
