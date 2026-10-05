# 12 类"程序位置登记"参考

> **给谁看**：迁移后要修登记的人；或者要写/改检查脚本的人。
> **一句话**：这 12 类里**任何一类**还指向不存在的路径，用户侧的表现都是"Windows 认不出这个程序"——而每一类的表现各不相同，所以必须逐类核对。
> **本文是这 12 类的唯一定义处**：README、[迁移避坑清单](migration-checklist.md)、[案例报告](case-report-d-apps-migration.md)都只链接到这里，不重复列表。

---

## 1. 一览表

| # | 类别 | 登记位置（注册表） | 失效时的表现 | 修复动作 |
|---|---|---|---|---|
| 1 | **卸载记录** | `HKLM` / `HKLM\WOW6432Node` / `HKCU` 的 `…\CurrentVersion\Uninstall\*`：`InstallLocation`、`DisplayIcon`、`UninstallString`、`QuietUninstallString`、`ModifyPath`、`Inno Setup: App Path` | "设置 → 应用"里图标空白、卸载/修复点了没反应 | 改指新路径；**新位置确实没有对应文件时才删记录**。<br>⚠ **例外：要删不要指** —— 若这是**旧版本**遗留的记录（同一产品已装新版本），改指会让"卸载"去执行旧版本的卸载器，反而破坏新装的版本 |
| 2 | **App Paths** | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths`、`HKLM\SOFTWARE\WOW6432Node\…\App Paths`、`HKCU\…\App Paths` | `Win+R` 输入程序名打不开；`ShellExecute` 找不到程序 | 三处都要改（默认值 = 完整 exe 路径） |
| 3 | **文件关联** | `Classes\<ext>` 的默认值、`OpenWithProgids`、`OpenWithList`，以及 `ksobak` 这类"上一个默认程序"备份值 | **双击文件打不开**，或打开错误程序 | 改 ProgID 或其命令；把死 ProgID 的默认值清掉让它回落系统默认。<br>⚠ **删掉一族 ProgID 时，必须回头清理指向它的引用**（各扩展名默认值、`OpenWithProgids`、`OpenWithList`）—— 否则只是把"死 ProgID"换成"死默认值"，双击照样打不开 |
| 4 | **打开方式动词** | `Classes\Applications\<exe>\shell\open\command` | "打开方式"里有条目但点了没反应 | 改指新路径，或删掉该 `Applications\<exe>` 键 |
| 5 | **右键菜单** | `*\shell`、`Directory\shell`、`Directory\Background\shell`、`SystemFileAssociations\…\shell`、`shellex\ContextMenuHandlers` | 右键菜单项点了没反应 / 报错 | 改命令路径或删除该项 |
| 6 | **CLSID 外壳扩展** | `Classes\CLSID\{…}\InprocServer32`（缩略图、预览、属性页、URL 协议处理） | 缩略图不显示、预览窗格报错、相关功能静默失效 | 改 DLL 路径；确认无用则删该 CLSID 键 |
| 7 | **命名空间图标** | `Explorer\MyComputer\NameSpace\{…}`、`Explorer\Desktop\NameSpace\{…}` | "此电脑/桌面"里出现**打不开的死图标** | 删该命名空间键（键可能被加保护，需先夺取所有权） |
| 8 | **协议处理** | `Classes\<proto>\shell\open\command`（`xxx://`） | 点协议链接没反应或提示找不到应用 | 改指新路径，或删该协议注册 |
| 9 | **自动播放 / 默认程序** | `Explorer\AutoplayHandlers`、`HKLM\SOFTWARE\RegisteredApplications` + `Clients\Media\<app>\Capabilities` | 插入光盘/U盘无反应；"默认应用"里显示异常 | 改路径或重新注册 |
| 10 | **服务 / 驱动** | `HKLM\SYSTEM\CurrentControlSet\Services\*\ImagePath` | 服务启动失败，或留下永久"已停止"的残留服务 | 改 `ImagePath`；确认程序已卸载则删除服务键 |
| 11 | **计划任务 / 启动项 / PATH** | `schtasks`、`…\CurrentVersion\Run`、系统环境变量 `PATH` | 自启失效；命令行找不到程序 | 改路径或删除对应项 |
| 12 | **快捷方式** | 开始菜单（**含直接躺在 `Start Menu` 根目录、不在 `Programs` 里的**）、桌面、任务栏固定、`SendTo` | 快捷方式点了没反应 / 图标变白 | 重新指向或删除 |
### 1.1 「目标不存在」有三种成因，别一律当成"迁移没同步"

上表每一类的"失效表现"，根源都是**登记指向的路径不存在**。但**不存在的原因有三种**，处理方式不同：

| 成因 | 怎么判断 | 怎么办 |
|---|---|---|
| ① **迁移后没同步** | 新位置**有**这个程序；旧路径是"搬走前"的位置 | 把登记改指到新位置（`repair-migrated-apps`）——**文件本身别动** |
| ② **卸载残留** | 程序确实没了（安装目录与卸载器都不存在） | 删记录与引用（`health-fix`） |
| ③ **写入时就写坏了（编码）** | 旧路径**从来没存在过**，而且路径里是**乱码** | 改指到真实目录（同 ①），但**根因在安装器**，重装可能再写坏一次 |

③ 值得单独说，因为它的表现和 ① 一模一样，很容易被当成"又是搬迁没改登记"。实测遇到的真实例子：

```text
报告里的值   ：E:\steam\...\common\娴锋矙椋庝簯     <- 注册表里存的就是这个
磁盘上的目录 ：E:\steam\...\common\海沙风云        <- 目录名其实是对的
```

`娴锋矙椋庝簯` 就是 `海沙风云` 的 UTF-8 字节被按 GBK 解释后的样子 —— 安装器把编码搞错了，于是
**这条登记从写入的第一刻起就没指向过任何真实路径**。

**怎么判断是不是 ③**：到上层的真实目录里看一眼（`Get-ChildItem 'E:\steam\...\common'`）。真实目录名
是正常中文、而登记里是乱码，就是 ③。修的时候直接改指真实目录；如果打算重装，先有"它可能再写坏
一次"的心理准备。

---

## 2. 统一检查方法（按旧路径全量搜）

```powershell
# 找出所有还引用旧路径的键
reg query "HKLM\Software\Classes" /f "D:\mpv-lazy" /s
reg query "HKCU\Software\Classes" /f "D:\mpv-lazy" /s
reg query "HKLM\Software\Microsoft\Windows\CurrentVersion" /f "D:\mpv-lazy" /s
```

**一个结构性盲区**：`reg query /f /s` 是**逐键、逐值**比对的，所以**看不到"跨层拼出来"的路径** —— 例如开始菜单的磁贴缓存把路径拆成多层键名存：

```text
…\CurrentVersion\Start\TileProperties\W~D:\JetBrains\PyCharm\bin\pycharm64
                                           ↑ 键名是 "W~D:"，整条路径横跨 5 层键名
```

本机实测这类引用有 **52 条**，`reg query` **一条也找不到**（GUI 搜索工具同理）。本仓库脚本改用 .NET 遍历后能看到 —— 因为它是把键路径拼起来再比对。

两个判定细节（都实际翻过车）：

1. **`reg query` 的报错文案随系统语言变化**（英文 `unable to find` / 中文"找不到"）→ 脚本里不要用错误文本判断键是否存在，用 `Test-Path` 或 `OpenSubKey() -ne $null`。
2. **改完要确认"新目标真的存在"**：把旧路径换成新路径前先验证目标文件；不存在就不要写入一个同样无效的路径，而是报告出来人工决定。

**成本提示（实测）**：`reg query /f /s` 的开销 ≈ **根键数 × 关键词数**，**单次约 1 分钟**。本机实测 11 条清单 × 5 个根键 = 55 次 ≈ **52~55 分钟**；不同根键差异极大（`…\Microsoft\Windows\CurrentVersion` 单次就 217 秒，因为它要把**每一个值的数据**读出来 —— 实测占单次耗时的 98%，而枚举键名只要 2.3 秒、枚举值名 4.2 秒）。

> **本仓库的两个脚本都已经不用 `reg query` 做批量搜索了**：`health-check` 第 12 节与
> `repair-migrated-apps` 的发现阶段都用 .NET 自己走一遍树（只读字符串类型的值，且一次遍历覆盖
> 全部关键词）。本机实测（同一份 13 条关键词、3 个根键）：`repair` 的发现阶段
> **321 秒 → 55.1 秒**、整个试运行 **326.5 秒 → 61.3 秒**，而且换实现前后**计划改写逐行一致**
> （132/132 行、命中 66 个键完全相同）。上面那条成本模型只适用于**手工排查**时直接敲 `reg query` 的场景。

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
| `scripts/health-check.ps1`（只读体检） | 逐类核对上表 **1–12 类**的目标是否存在 → 输出 `report.md`（人读）+ `findings.csv`（逐条明细）；另外检查孤儿安装缓存、旧路径残留、磁盘容量与增长。**没查到的会明说**：清单为空/全是占位符、或用了 `-Skip*` 开关时，报告写"本节未执行检查"并记入 `findings.csv`，不会给绿勾 |
| `scripts/health-fix.ps1`（按规则清理） | A 段改路径（程序搬走）→ B 段删已卸载软件的记录/服务/协议 → C 段清"指向已删 ProgID"的引用与图标覆盖 → D 段清悬空引用。判据统一是 `Test-Missing`（目标确实不存在才动手）；每条改动前 `reg export` 到 `local/rollback/<运行时间戳>/`，**备份失败则该条改动被跳过** |
| `scripts/repair-migrated-apps.ps1`（迁移批量改写） | 按 `local\repair-migrated-apps.local.psd1` 的"旧→新"映射改写上表 1/2/4/8/9/12 类，并用 **.NET 一次性遍历**（`Find-MigratedKeys`，与 `health-check` 第 12 节同一套做法）发现更多引用点；写入前检查目标文件是否真的存在（`Test-Exists`）。另有一个只读的 `-DiscoverTargets`：从"指向已消失路径的登记"与"磁盘上的同名目录"反推出**候选映射草稿**，专门给还空着的映射表起步用 |

> **第 6 类的代码位置**：`scripts\health-check.ps1` 第 7 节，枚举由 `Get-ClsidExtensionKeys` 完成 —— 它扫的是 `Classes\CLSID` **子树**。注意 `Classes` 这一层里"以 `{` 命名"的键**不是**第 6 类的登记位置（正常机器上几乎不存在这种键）；只看这一层会把"检查了 0 项"打成绿勾（见 `AGENTS.md` 硬性约定 16）。
>
> 删这类键时若遇到 `AccessDenied`（DACL 只给 `Administrators` 一个 `ReadKey`，`TrustedInstaller`/`SYSTEM` 才是 `FullControl`），按 **夺取所有权 → 重建权限项 → 恢复完全控制 → 再修改** 的顺序做 —— **提权不等于有写权限**（见硬性约定 17）。

**执行顺序**：`health-check` → `repair-migrated-apps` → 再 `health-check` 复检 → 最后 `health-fix`。
顺序反了会白干：`health-fix` 会把"目标暂时找不到"的记录直接删掉，而那条记录本来正是
`repair-migrated-apps` 要改写回来的。

判定原则（三个脚本共用）：

- **"读不到" ≠ "不存在"**：权限受限的路径判为 `denied` / 用 `Test-Exists` 判为存在，绝不当作残留删除。
- **`\WindowsApps\`、`\DriverStore\`** 对普通用户不可读，直接不判定。
- **报告不许有假绿**：空清单、全是占位符、被 `-Skip*` 跳过的节，都要显式说出来。
- 报告按"不存在的目标"聚合，避免几百行噪音淹没真问题。

---

## 5. 不要动的几类

| 不要动 | 原因 |
|---|---|
| Windows 自带项（`CLSID_*`、`ms-*`、系统命名空间项、`Http`/`https`/`mailto` 等协议） | 删了会破坏系统功能；检查脚本对它们有白名单/跳过规则 |
| **由启动器自我维护的记录**（Steam 游戏、游戏反作弊组件等） | 删掉会被重建，还可能影响游戏识别——交给对应启动器 |
| **卸载器仍然存在的"半残留"**（程序目录已删、但厂商卸载器还在） | 这类用厂商官方清理工具或 Geek 处理更安全；脚本对它们保守保留 |
| **MSI 安装数据库**（`…\CurrentVersion\Installer\…`、`Classes\Installer\Products`） | 这是 Windows Installer 自己的账本（产品记录 / 每个组件的基准路径 / 上次用的安装源位置）。**手改没有受支持的方式**，改坏会让 repair 与卸载失效。它里面的旧路径唯一正确的解法是**重装或修复那个产品**，让安装器自己重写；已经不用的产品，这些记录是无害的遗物 —— 所以体检报告把它们标成"提示"而不是"警告" |

---

**相关**：[迁移避坑清单](migration-checklist.md)（怎么迁 + 迁完勾什么）· [磁盘长期健康管理](disk-health.md)（空间与备份）· [案例报告](case-report-d-apps-migration.md)（这套规则是怎么从一次真实事故里总结出来的）
