# 12 类"程序位置登记"参考

> **给谁看**：迁移后要修登记的人；或者要写/改检查脚本的人。
> **一句话**：这 12 类里**任何一类**还指向不存在的路径，用户侧的表现都是"Windows 认不出这个程序"——而每一类的表现各不相同，所以必须逐类核对。
> **本文是这 12 类的唯一定义处**：README、[迁移避坑清单](migration-checklist.md)、[案例报告](case-report-d-apps-migration.md)都只链接到这里，不重复列表。

---

## 1. 一览表

| # | 类别 | 登记位置（注册表） | 失效时的表现 | 修复动作 |
|---|---|---|---|---|
| 1 | **卸载记录** | `HKLM` / `HKLM\WOW6432Node` / `HKCU` 的 `…\CurrentVersion\Uninstall\*`：`InstallLocation`、`DisplayIcon`、`UninstallString`、`QuietUninstallString`、`ModifyPath`、`Inno Setup: App Path` | "设置 → 应用"里图标空白、卸载/修复点了没反应 | 改指新路径；**新位置确实没有对应文件时才删记录** |
| 2 | **App Paths** | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths`、`HKLM\SOFTWARE\WOW6432Node\…\App Paths`、`HKCU\…\App Paths` | `Win+R` 输入程序名打不开；`ShellExecute` 找不到程序 | 三处都要改（默认值 = 完整 exe 路径） |
| 3 | **文件关联** | `Classes\<ext>` 的默认值、`OpenWithProgids`、`OpenWithList`，以及 `ksobak` 这类"上一个默认程序"备份值 | **双击文件打不开**，或打开错误程序 | 改 ProgID 或其命令；把死 ProgID 的默认值清掉让它回落系统默认 |
| 4 | **打开方式动词** | `Classes\Applications\<exe>\shell\open\command` | "打开方式"里有条目但点了没反应 | 改指新路径，或删掉该 `Applications\<exe>` 键 |
| 5 | **右键菜单** | `*\shell`、`Directory\shell`、`Directory\Background\shell`、`SystemFileAssociations\…\shell`、`shellex\ContextMenuHandlers` | 右键菜单项点了没反应 / 报错 | 改命令路径或删除该项 |
| 6 | **CLSID 外壳扩展** | `Classes\CLSID\{…}\InprocServer32`（缩略图、预览、属性页、URL 协议处理） | 缩略图不显示、预览窗格报错、相关功能静默失效 | 改 DLL 路径；确认无用则删该 CLSID 键 |
| 7 | **命名空间图标** | `Explorer\MyComputer\NameSpace\{…}`、`Explorer\Desktop\NameSpace\{…}` | "此电脑/桌面"里出现**打不开的死图标** | 删该命名空间键（键可能被加保护，需先夺取所有权） |
| 8 | **协议处理** | `Classes\<proto>\shell\open\command`（`xxx://`） | 点协议链接没反应或提示找不到应用 | 改指新路径，或删该协议注册 |
| 9 | **自动播放 / 默认程序** | `Explorer\AutoplayHandlers`、`HKLM\SOFTWARE\RegisteredApplications` + `Clients\Media\<app>\Capabilities` | 插入光盘/U盘无反应；"默认应用"里显示异常 | 改路径或重新注册 |
| 10 | **服务 / 驱动** | `HKLM\SYSTEM\CurrentControlSet\Services\*\ImagePath` | 服务启动失败，或留下永久"已停止"的残留服务 | 改 `ImagePath`；确认程序已卸载则删除服务键 |
| 11 | **计划任务 / 启动项 / PATH** | `schtasks`、`…\CurrentVersion\Run`、系统环境变量 `PATH` | 自启失效；命令行找不到程序 | 改路径或删除对应项 |
| 12 | **快捷方式** | 开始菜单（**含直接躺在 `Start Menu` 根目录、不在 `Programs` 里的**）、桌面、任务栏固定、`SendTo` | 快捷方式点了没反应 / 图标变白 | 重新指向或删除 |

---

## 2. 统一检查方法（按旧路径全量搜）

```powershell
# 找出所有还引用旧路径的键
reg query "HKLM\Software\Classes" /f "D:\mpv-lazy" /s
reg query "HKCU\Software\Classes" /f "D:\mpv-lazy" /s
reg query "HKLM\Software\Microsoft\Windows\CurrentVersion" /f "D:\mpv-lazy" /s
```

两个判定细节（都实际翻过车）：

1. **`reg query` 的报错文案随系统语言变化**（英文 `unable to find` / 中文"找不到"）→ 脚本里不要用错误文本判断键是否存在，用 `Test-Path` 或 `OpenSubKey() -ne $null`。
2. **改完要确认"新目标真的存在"**：把旧路径换成新路径前先验证目标文件；不存在就不要写入一个同样无效的路径，而是报告出来人工决定。

成本提示：`reg query /f /s` 的开销 ≈ **根键数 × 关键词数**（每个约 5~10 秒）。关键词要收敛，或者改写一次索引再在内存里判断。

---

## 3. 用现成工具更快

| 工具 | 适合的场景 |
|---|---|
| **RegScanner** | 全注册表搜索（支持二进制/时间条件），结果导出 CSV 人工核对 |
| **Registry Finder** | 搜索 + **批量替换**（带预览）：迁移后"旧→新"的批量改写，比脚本更适合人眼复核 |
| **Geek Uninstaller** | 清"卸载器已失效/指向旧目录"的**孤儿卸载记录**，比手写注册表删除安全 |
| **Everything** | 找"程序搬到哪了"（定位新路径，填进映射表） |
| 本仓库脚本 | 见下一节 |

---

## 4. 与脚本的对应关系

| 脚本 | 覆盖范围 |
|---|---|
| `scripts/health-check.ps1`（只读体检） | 逐类核对上表 **1–12 类**的目标是否存在 → 输出 `report.md`（人读）+ `findings.csv`（逐条明细）；另外检查孤儿安装缓存、旧路径残留、磁盘容量与增长 |
| `scripts/health-fix.ps1`（按规则清理） | A 段改路径（程序搬走）→ B 段删已卸载软件的记录/服务/协议 → C 段清"指向已删 ProgID"的引用与图标覆盖 → D 段清悬空引用；每条改动前 `reg export` 备份 |
| `scripts/repair-migrated-apps.ps1`（迁移批量改写） | 按脚本顶部 `$pathMap`（旧→新映射表）改写上表 1/2/4/8/9/12 类，并用 `reg query` 发现更多引用点；写入前检查目标文件是否真的存在 |

判定原则（两个脚本共用）：

- **"读不到" ≠ "不存在"**：权限受限的路径判为 `denied` 并跳过，绝不当作残留删除。
- **`\WindowsApps\`、`\DriverStore\`** 对普通用户不可读，直接不判定。
- 报告按"不存在的目标"聚合，避免几百行噪音淹没真问题。

---

## 5. 三类别乱动

| 不要动 | 原因 |
|---|---|
| Windows 自带项（`CLSID_*`、`ms-*`、系统命名空间项、`Http`/`https`/`mailto` 等协议） | 删了会破坏系统功能；检查脚本对它们有白名单/跳过规则 |
| **由启动器自我维护的记录**（Steam 游戏、游戏反作弊组件等） | 删掉会被重建，还可能影响游戏识别——交给对应启动器 |
| **卸载器仍然存在的"半残留"**（程序目录已删、但厂商卸载器还在） | 这类用厂商官方清理工具或 Geek 处理更安全；脚本对它们保守保留 |

---

**相关**：[迁移避坑清单](migration-checklist.md)（怎么迁 + 迁完勾什么）· [磁盘长期健康管理](disk-health.md)（空间与备份）· [案例报告](case-report-d-apps-migration.md)（这套规则是怎么从一次真实事故里总结出来的）
