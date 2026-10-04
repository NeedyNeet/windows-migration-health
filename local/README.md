# local/ —— 个人产物（**已 gitignore，不会进仓库**）

这个目录存放"只对本机有意义、且可能含个人隐私"的东西。脚本运行时会自动往这里写。

| 子目录/文件 | 内容 | 来源 |
|---|---|---|
| `rollback/` | **注册表备份**：每条改动前用 `reg export` 导出的 `.reg`（本机约 545 个）+ 批量删除清单 | `health-fix.ps1` 与 `repair-migrated-apps.ps1`（`Backup-Key`） |
| `reports/` | 体检报告：`report.md`（人读）、`findings.csv`（逐条明细）、`snapshot.json`（磁盘增长基线）、`history/` | `health-check.ps1 -OutDir local\reports` |
| `health-fix-log.txt` | 清理脚本的详细日志（含每一条改动与统计） | `health-fix.ps1` |
| `health-fix-elevated.txt` | 提权窗口的原始输出 | `health-fix.cmd` |

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
