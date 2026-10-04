> **仓库内路径说明**：本文提到的 `health-check.ps1` / `health-fix.ps1` / `repair-migrated-apps.ps1` 均位于本仓库 **`scripts/`** 目录；注册表备份（`rollback/`）与体检报告位于 **`local/`**（已 gitignore，不进仓库）；历史版本在 `versions/`。
# D:\Apps 迁移后 Windows 识别异常 — 排查报告

排查与修复时间：**2026-10-03 ~ 10-04**（依据工具产物：`rollback\deleted-registry-keys-2026-10-03.txt`、`rollback\PendingFileRenameOperations-before.txt`、`local/reports/20261004-*`）· 对象：`D:\Apps`（`Installed` / `JetBrains` / `Portable`）
症状（机主当时描述）：开始菜单/任务栏搜索搜不到、双击关联文件提示找不到应用、应用能打开但 Windows 不认它是"已安装程序"。
**状态：修复已执行（见第六节执行记录），74 处注册表取值 + 5 个快捷方式全部写入并逐条验证通过。**

> **相关文档**：本文是**案例全过程**（含证据、误判与自我纠错）。
> 可复用的规则与清单已拆分为三篇：操作流程见 [migration-checklist.md](migration-checklist.md)，12 类登记的定义见 [registry-reference.md](registry-reference.md)，磁盘长期管理见 [disk-health.md](disk-health.md)。
> 本文提到的脚本都在仓库 `scripts/` 目录，产物写在 `local/`（已 gitignore）。

> **数字口径（重要）**：本文跨多个阶段，各阶段的写入数与备份数是**累加**的，不是互相替代 ——
> 正文里出现的数字都指"截至该节"的状态，所以与最终值不同。汇总：
>
> | 阶段 | 注册表写入 | 桌面 `apps-repair-backup\` | `local\rollback\` |
> |---|---|---|---|
> | 第 1~3 轮：`D:\Apps` 迁移修复（§三~§六） | 74 处取值 / 56 个键 / 5 个快捷方式（首版脚本的**计划**范围是 70 / 52 / 4） | 56 个 `.reg` | 4 个 `.reg` |
> | 第二轮：关联类残留（§八） | 28 处取值 / 29 个键 | 89 个 | —— |
> | 清理战役（§九~§十一） | —— | 89 个 | 105 个 `.reg`（另含批量删除清单与重启队列留档） |
> | 之后 `health-fix` 全量体检清理 | 见 [versions/README.md](../versions/README.md) | 92 个 | **545 个 `.reg`（最终）** |
>
> 磁盘数字同理：§十二 是当时的状态，附录 B 是**更晚一次**的快照（它只记总容量，不再记可用量）。

## 零、本文怎么读

| 你想知道什么 | 看哪节 |
|---|---|
| 到底哪出了问题、怎么修的 | §一 ~ §六 |
| 那些"看起来像权限损坏"的误判是怎么证伪的 | §七 |
| 各类残留（关联/协议/图标/命名空间）怎么清 | §八、§九 |
| **迁移损坏 → 弃用卸载 → 卸载残留清理**（第二波，因果见下） | §十 ~ §十二 |
| **34 条实战踩坑（工具/API/环境/判断）** | **附录 A** |
| 这台机器现在的状态 | 附录 B |

> **§十~§十二 不是另一件事，是同一事故的第二波。** 因果链：迁移把几款软件的**文件本身弄坏了**
> → 这些软件机主本来就不常用 → 索性卸载 → 卸完发现**卸载残留**（登记指向已不存在的路径）。
>
> 也就是说，同一个症状（"系统认不出东西"）换了第二种成因：不是"文件搬走了、登记没跟"，而是
> "程序删了、登记没清"。这正是 `health-fix.ps1` 同时有 A 段（改路径）与 B 段（删残留）的原因，
> 也是本仓库把主题定为「**登记一致性**」而不是"迁移工具"的原因。

---

## 一、结论（一句话）

**文件确实搬到 `D:\Apps` 了，但 Windows 的登记信息还留在旧位置。**
注册表里（卸载记录、`App Paths`、文件类型关联、图标、快捷方式）仍然指向
`C:\Program Files (x86)\...`、`C:\Users\<旧用户名>\...`、`D:\JetBrains\...`、`D:\BCompare-...` 这些**已经不存在**的路径，
所以 Windows 按记录去找 → 找不到 → 表现成"识别不到"。

额外发现两点，与本次问题同源但不是同一个坑：

1. **Windows 用户目录被改过名**：注册表里到处是 `C:\Users\<旧用户名>`，但现在实际是 `C:\Users\<user>`（`C:\Users\<旧用户名>` 已不存在）。Notion、Xmind、JetBrains Daemon、百度网盘、REDlauncher、PowerToys、Python 3.14 等记录全部因此失效。
2. **`D:\WinRAR` 一开始被我误判为"权限损坏"，现已证伪**：当时"访问被拒绝"是**执行排查的那个受控会话自身的低完整性(Low Integrity)文件沙箱**造成的，不是 Windows 权限问题。用任务计划程序以**机主的正常令牌（Medium 完整性、沙箱之外）**实测：`D:\WinRAR` 可正常列出 32 个文件、`WinRAR.exe`(3.28 MB) 与 `%LOCALAPPDATA%\PowerToys\PowerToys.exe`(1.25 MB) 都可正常读取；两者的权限清单里也没有任何拒绝项，反而明确授予了 `BUILTIN\Users` 读取 / 机主账户完全控制。详见第七节。

---

## 二、逐应用对照表

| 应用 | Windows 记录的位置（已失效） | 实际位置 | 对应的症状 |
|---|---|---|---|
| 网易云音乐 3.1.41 | `C:\Program Files (x86)\NetEase\CloudMusic` | `D:\Apps\Installed\NetEase\CloudMusic` | 双击 mp3/flac/ncm 等打不开；`Win+R` 输入 `cloudmusic` 找不到；设置里的卸载/图标失效 |
| 夸克网盘 3.19.0 | `C:\Program Files (x86)\quark-cloud-drive` | `D:\Apps\Installed\quark-cloud-drive` | 搜索里没有它（根本没有开始菜单快捷方式）；.torrent 双击报找不到应用；卸载项失效 |
| Notion 4.17.0 | `C:\Users\<旧用户名>\AppData\Local\Programs\Notion` | `D:\Apps\Installed\Notion` | 设置→应用里条目在但认不出（图标/卸载失效）；`notion://` 链接失效 |
| Xmind 25.1.1061 | `C:\Users\<旧用户名>\AppData\Local\Programs\Xmind` | `D:\Apps\Installed\Xmind` | **搜索完全搜不到**（无快捷方式）；.xmind 双击打不开 |
| Beyond Compare 5.0.1 | `D:\BCompare-zh-5.0.1.29877\Beyond Compare 5` | `D:\Apps\Portable\BCompare-zh-5.0.1.29877\Beyond Compare 5` | `App Paths\BCompare.exe` 失效；快照/设置包类型双击打不开；卸载项失效 |
| CLion / DataGrip / PyCharm | `D:\JetBrains\CLion`、`D:\JetBrains\DataGrip`、`D:\JetBrains\PyCharm` | `D:\Apps\JetBrains\...` | 设置→应用里 InstallLocation/图标指向不存在的目录；Toolbox 类型注册失效；PyCharm 快捷方式指针是死路径 |
| IntelliJ IDEA 2024.2.2 | `D:\IntelliJ IDEA 2024.2.2` | `D:\Apps\JetBrains\IntelliJ IDEA 2024.2.2` | 同上；ProgramData 里还留了一个指向死路径的重复快捷方式 |
| JetBrains Toolbox | `C:\Users\<旧用户名>\AppData\Local\JetBrains\Toolbox` | **已重装到** `C:\Users\<user>\AppData\Local\JetBrains\Toolbox`（3.8.1） | 原先快捷方式指向 TRAE 虚拟缓存里的死路径、`jetbrains://` 协议失效；现已全部指向新目录 |
| WinRAR 7.01 | `D:\WinRAR` | 同左（**从未被迁移移动过**） | **无问题**：目录、App Paths、卸载项、4 个快捷方式全部指向真实存在的文件。先前判为"权限损坏"是误判，见第七节 |
| mpv（mpv-lazy） | `D:\mpv-lazy` | `D:\Apps\Portable\mpv-lazy` | `App Paths\mpv.exe` 失效 + **整套媒体关联失效**：`io.mpv.*`（86 个 ProgID）、`Applications\mpv.exe`、`io.mpv.mpeg4`（.mp4 等）、自动播放的 DVD/蓝光处理器全部指向已删除的 `D:\mpv-lazy`；见第八节 |

状态正常、不需要动的：DeepSeek Harness、豆包、EaseUS Todo PCTrans、MySQL84 服务（服务路径已指向 `D:\Apps\Installed\MySQL\mysql-8.4.11-winx64`，正确）、以及 `D:\Apps\Portable\` 下大部分便携软件的快捷方式。

---

## 三、修复方式

已生成两个文件（同目录）：

- **`repair-migrated-apps.cmd`** — 双击运行，自动请求管理员权限并执行修复。
- **`repair-migrated-apps.ps1`** — 实际逻辑；默认 **试运行（只打印不改）**，加 `-Apply` 才写入。

修复内容（**70 处取值 / 52 个注册表键 / 4 个快捷方式**，全部为"旧路径 → 新路径"的定点替换）：

1. 卸载记录（设置→应用）：`InstallLocation`、`DisplayIcon`、`UninstallString`、`QuietUninstallString`、`Inno Setup: App Path`。
2. `App Paths`：`BCompare.exe`、`cloudmusic.exe`、`mpv.exe`（HKLM + WOW6432Node + HKCU）。
3. 文件类型关联：`cloudmusic.mp3/flac/m4a/wav/ape/ogg/aac/wma/cda/cue/ncm`、`BeyondCompare.SettingsPackage/Snapshot`、`Xmind Workbook`、`QuarkCloudDrive.torrent`、`notion`、`xmind`、`xmind-zen`。
4. 开始菜单：Xmind、夸克网盘**新建**快捷方式；PyCharm、IntelliJ IDEA 2024.2.2 的**死指针就地修正**。

安全措施：每处改动前，用 `reg.exe export` 把整个键备份到
`桌面\apps-repair-backup\*.reg`，随时可以双击导入还原。

**已知无法自动修的一项**：`IntelliJ IDEA 2024.2.2` 的 `UninstallString` 指向
`...\bin\Uninstall.exe`，而新目录里根本没有这个卸载器（JetBrains 现在只由 Toolbox 管理）。脚本会跳过它并明确列出，不写一个同样无效的路径。要正常卸载，重装一下 JetBrains Toolbox 由它接管即可。

---

## 四、当时留给机主的两件事（均已有结论）

1. **`D:\WinRAR`：什么都不用做**（原先的"权限损坏"结论已证伪，见第七节）。
   WinRAR 自身完整、注册正确；唯一可留意的是它没有 `rarreg.key`（未注册版），要注册把 key 文件放进 `D:\WinRAR\` 即可。

2. **`PowerToys`：机主已重装完成，复核通过（0.101.2362.0）**
   新版装在 `C:\Users\<user>\AppData\Local\PowerToys`（3847 项，`PowerToys.exe` 0.101.2362.0、签名 Valid），两条记录都指向新用户目录、图标与卸载器文件均存在。
   复核时又发现并清掉了**旧 0.90.1 的一条残留 bundle 记录**（`{b1781406-…}`，`DisplayIcon`/`UninstallString`/`ModifyPath` 全是旧用户目录的死路径）——这条**不能靠改路径修**：改指到新目录后，点"卸载"会去跑 0.90.1 的旧 bundle，反而可能破坏新装的 0.101，所以直接删除（备份见 `rollback\`）。
   顺带量到：`%LOCALAPPDATA%\Package Cache` 里 0.90.1 的缓存安装包还占着 **约 384 MB**（`{AA6BF89D-…}v0.90.1` 383.4 MB + `{b1781406-…}` 0.6 MB），已不再被任何已安装产品引用，**可删可留**（当前版本的两份缓存必须保留，见下）。

3. **JetBrains Toolbox：已重装完成（3.8.1.0）** — 逐应用的前后对照见第二节；重装的完整过程留档在 `local\toolbox-install\HANDOVER.md`（在已被 gitignore 的 `local/` 下，不进仓库）。

---

## 五、这套修复现在怎么用

> 本节记录**当时的操作**。这套工具后来已脚本化并搬进仓库 `scripts/`，日常用法以
> [README 的「快速开始」](../README.md) 为准。"当时"的动作对应到今天是这样：

```bat
rem 1) 先只读体检（绝不修改系统）
scripts\health-check.cmd

rem 2) 迁移路径修复：把"旧 → 新"映射填进 local\repair-migrated-apps.local.psd1
rem    不带 -Apply 时是试运行，只打印计划、不写注册表
scripts\repair-migrated-apps.cmd

rem 3) 确认输出无误后再真正写入（会弹 UAC）
scripts\repair-migrated-apps.cmd -Apply
```

只想看某个 app 的记录对不对：

```powershell
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\网易云音乐" /s
```

修完之后图标或"打开方式"还是旧的：注销再登录一次，或执行
`taskkill /f /im explorer.exe & start explorer.exe`。

> 执行策略：本机 `LocalMachine = Restricted`，所以三个 `.cmd` 启动器都带了 `-ExecutionPolicy Bypass`。

---

## 六、执行记录（已完成）

以管理员权限实际执行了三轮（脚本是幂等的，重复执行只会处理"仍指向旧路径"的项）：

| 轮次 | 结果 |
|---|---|
| 第 1 轮 | 具名取值（`UninstallString` / `DisplayIcon` / `InstallLocation` / `Inno Setup: App Path` 等）写入成功；发现两个只在真实写入时才暴露的问题并当场修掉：① 键的**默认值**不能用 `Set-ItemProperty -Name ''` 写（41 处因此失败），改用 `Set-Item`；② `Toolbox.*` 关联键因一处 `-replace` 写法错误**根本没被扫到**，已修正并补扫。 |
| 第 2 轮 | 45 处写入，**45/45 成功、0 失败、0 报错**。 |
| 第 3 轮 | 补修 `C:\ProgramData\...\Start Menu\Beyond Compare 5.lnk`（它直接躺在 `Start Menu` 根目录而不是 `Programs` 子目录，第一版只扫了 `Programs`，已把扫描范围扩大到整棵 `Start Menu`）。 |

最终写入统计：**74 处注册表取值 / 56 个注册表键 / 5 个开始菜单快捷方式**。

独立验证（不依赖脚本自己的判断）：

- 16 项抽查全部解析到真实存在的文件：`App Paths`（cloudmusic / BCompare / mpv，含 x86 视图）、`cloudmusic.mp3` 与 `.ncm` 处理程序与图标、`notion://`、`.xmind`、`.torrent`、Beyond Compare 快照类型、PyCharm/IDEA 的 Toolbox 处理程序、IDEA 与 CLion 的 `InstallLocation`。
- `Get-StartApps`（开始菜单/任务栏搜索的数据源）现在能找到：**Xmind、夸克网盘、Notion、cloudmusic、Beyond Compare、CLion、PyCharm、DataGrip、IntelliJ IDEA**。
- 开始菜单里已无任何指向 `D:\Apps` 相关旧路径的死快捷方式（剩余的死快捷方式都属于别的软件：GARbro、Python 3.9/3.11/3.12/3.14、WPS、xmodhub、mGBA，以及 Clash for Windows / RePKG-GUI 这两个已被机主删掉的便携软件）。
- 脚本再审一遍剩余待修项：**0 处**，只剩那条已知无法自动修的 IDEA 卸载器路径。

备份：`C:\Users\<user>\Desktop\apps-repair-backup\`（56 个 `.reg`，按注册表键导出，双击导入即可还原该键）。

**结论修正**：原先记为"`D:\WinRAR` 权限损坏"的结论**已证伪**（见第七节）；PowerToys 也不是权限问题，而是卸载记录指向旧用户目录。两者都**不需要改权限、不需要重装**。

---

## 七、WinRAR / PowerToys "权限损坏"的复核（结论：误判，已证伪）

**当时的现象**：本会话里读 `D:\WinRAR` 和 `%LOCALAPPDATA%\PowerToys` 都报"访问被拒绝"，我据此判为权限损坏。

**复核发现**：

1. 执行排查的进程令牌是 **`Mandatory Label\Low Mandatory Level`（S-1-16-4096，低完整性）** —— 这是 DSH 文件沙箱自身的受限令牌，不是机主的正常登录令牌。
2. 用管理员令牌读取时，两处的权限清单**没有任何拒绝项**，反而明确授权：
   - `D:\WinRAR`：`BUILTIN\Users` 读取、`NT AUTHORITY\Authenticated Users` 修改、`BUILTIN\Administrators` 完全控制；所有者 `BUILTIN\Administrators`。
   - `%LOCALAPPDATA%\PowerToys`：`<PC>\<user>` 完全控制（所有者也是机主账户），`BUILTIN\Users` 读取。
3. **决定性验证**：绕过沙箱，用任务计划程序以**机主的正常令牌（Medium 完整性）**执行读取测试 ——
   - `D:\WinRAR` 成功列出 **32 个文件**：`WinRAR.exe`（3,286,680 字节，2024/05/15）、`UnRAR.exe`、`Uninstall.exe`、`RarExt.dll`、`WinRAR.chm` 等齐全；
   - `%LOCALAPPDATA%\PowerToys\PowerToys.exe` 成功读取（1,249,864 字节，2025/04/09）；
   - 两者权限清单中都没有拒绝项，所以正常程序（资源管理器、开始菜单）访问它们**不会**被拒绝。

**顺带确认**：`D:\WinRAR` 里的 4 个开始菜单快捷方式、`App Paths\WinRAR.exe`、卸载项指向的文件**全部存在**，WinRAR 根本不需要修。PowerToys 本身也没问题，唯一缺陷是那条指向旧用户目录的卸载记录（见第四节第 2 条）。

---

## 八、mpv（mpv-lazy）与"关联类"残留 —— 第二轮修复

### 症状与根因

mpv 本体一切正常（`D:\Apps\Portable\mpv-lazy\mpv.exe`，v0.40.0-119，实测可运行），快捷方式与 `App Paths` 也早已修好。真正坏掉的是**整套媒体关联**：mpv-lazy 的官方安装器把关联全部注册在 **HKLM**，而这些登记都还写着已删除的 `D:\mpv-lazy`：

- **86 个 `io.mpv.*` ProgID**（`HKLM\Software\Classes\io.mpv.<类型>`）：每个都有 `shell\open\command`、`shell\play\command`、`DefaultIcon` 三处取值；
- `Applications\mpv.exe`（"打开方式"对话框里的动词，含 `open` + `play`）；
- `.mp4` 等走的是 `io.mpv.mpeg4`，经 `.mp4\OpenWithProgIds` 挂接；
- 自动播放处理器 `MpvPlayDVDMovieOnArrival` / `MpvPlayBluRayOnArrival`（`DefaultIcon` 也是旧路径）；
- `HKLM\Software\Clients\Media\mpv\Capabilities` + `RegisteredApplications`（"默认应用"里能不能选 mpv）。

> 后果：双击视频/选"用 mpv 打开"会提示找不到程序；mpv 不会出现在"打开方式"列表里。

### 修法与验证

**首选官方途径**：重新运行 mpv-lazy 自带的安装器
`D:\Apps\Portable\mpv-lazy\installer\mpv-install.bat /u`（管理员，无人值守）。
它按 `%~dp0\..` 计算 mpv 路径，所以从新位置运行即注册新路径 —— 实测 `ADMIN=yes`、无错误、自报"注册成功"。
它同时会写 `LongPathsEnabled=1`（该安装器的固有行为）并注册 `RegisteredApplications`。

**验证**（不依赖脚本自述）：
- 整个 `HKLM\Software` 全域搜索 `D:\mpv-lazy` → **零残留**；
- 抽样：`io.mpv.mpeg4`（.mp4 实际用的 ProgID）的 open/play 命令与图标、`Applications\mpv.exe` 的两个动词、两个自动播放处理器的 `DefaultIcon`、`App Paths\mpv.exe` → 全部为新路径；
- `.mp4\OpenWithProgIds` → `io.mpv.mpeg4` 链路成立；`SystemFileAssociations\video|audio\OpenWithList\mpv.exe` 在位。

### 顺带扫出的其他"关联类"残留（同一轮修掉）

用扩展后的脚本做**全量发现**时，又找出几处同类问题（都不在最初那批键里）：

| 位置 | 数量 | 说明 |
|---|---|---|
| `HKLM\...\Classes\Applications\idea64.exe` | 1 | IDEA 的"打开方式"动词，指向 `D:\IntelliJ IDEA 2024.2.2` |
| `HKLM\...\Classes\*\shell\Open with IntelliJ IDEA`、`Directory\shell\IntelliJ IDEA`、`Directory\background\...`、`IntelliJIdea2024.2`、`IntelliJIdeaProjectFile` | 10 | IDEA 的资源管理器右键菜单 + 项目文件 ProgID（图标与命令） |
| `HKCU\...\Classes\Application\Toolbox.{CLion,DataGrip,IDEA,PyCharm}` | 4 | 四个 IDE 的 Toolbox 打开动词，指向 `D:\JetBrains\*` |
| `HKCU\...\Classes\*\shell\QuarkCloudDrive.{imSendSelf,upload}`、`Directory\shell\QuarkCloudDrive.{backup,imSendSelf,upload}`、`CLSID\{82ca84ef-…}\{DefaultIcon,Instance\InitPropertyBag,Shell\Open\Command}`、`qkclouddrive`、`torrent` | 18 | 夸克网盘的右键菜单、CLSID（图标已正确改到 `app-3.19.0\resources\assets\icon_win.ico`）、`qkclouddrive://` 协议、.torrent 处理器 |
| `HKCU\...\Classes\CLSID\{95BD08AA-…}\InProcServer32` | 1 | Xmind 缩略图 shell 扩展 DLL（已指向 `D:\Apps\Installed\Xmind\resources\...\XMindShellExt.dll`，实测存在） |
| `HKLM\...\Classes\orpheus\*` | 2 | 网易云音乐的 `orpheus` 协议（图标 + 命令） |

合计本轮写入 **28 处取值 / 29 个键**（提权执行，`write ok 28 / FAILED 0`，逐条备份到桌面 `apps-repair-backup\`）。

### 脚本相应升级（避免以后再来一轮）

`repair-migrated-apps.ps1` 新增 **发现阶段**：先用原生 `reg.exe query <root> /f <旧路径前缀> /s` 在三个 `Classes` 大树里定位**所有**仍含旧路径的键，再把这些键交给原有的可靠改写器（`.NET GetValue` 读取 + `Set-Item/Set-ItemProperty` 写入）。这样右键菜单动词、CLSID 内嵌 shell 扩展、URL 协议、`Applications\<exe>` 这些"藏得深"的位置不会再被漏掉。

其他改进：
- **死路径保护扩展**：改写后若目标文件（`.exe/.dll/.ico/.com/.bat/.cpl/.msc/.sys`）不存在，则**跳过并报告**，绝不写入另一个同样无效的路径；
- 同一键/同一取值去重，只走一遍、只写一次；
- "无法自动修复"清单按缺失目标合并显示（不再刷屏）；
- 发现阶段**刻意只搜 D:\Apps 迁移相关的前缀**：`C:\Users\<旧用户名>`（用户目录改名）是另一个更宽的问题——搜它会带出 GIMP、360se、PowerToys、GitHub Desktop 等一堆旧配置，而那些路径没有有效新目标，故不纳入本脚本；
- 运行耗时较长（三个 Classes 大树的原生全量扫描，约 3–4 分钟），属正常。

### 复核结论

- 8 个迁移相关旧前缀（`D:\JetBrains\`、`D:\IntelliJ IDEA 2024.2.2`、`D:\mpv-lazy`、`D:\BCompare-…`、`quark-cloud-drive`、`NetEase\CloudMusic`、`Programs\Notion`、`Programs\Xmind`）在 HKLM/HKCU 的 `Classes` 与 `CurrentVersion` 下：**功能层残留为 0**。
- 仅剩 Windows 自有的**外观缓存/使用统计**：`MuiCache` 的显示名、开始菜单瓷砖缓存、以及值为旧路径名的 `REG_DWORD/REG_QWORD` 使用次数计数器——这些由系统自行管理，不影响任何程序的启动或关联。

---

## 九、最后收尾：两条失效记录的删除 + PowerToys 复核

| 动作 | 结果 |
|---|---|
| 删除 `HKLM\SOFTWARE\WOW6432Node\...\Uninstall\IntelliJ IDEA 2024.2.2` | 该记录（旧版 242.22855.74）的 `UninstallString` 指向 `D:\IntelliJ IDEA 2024.2.2\bin\Uninstall.exe`（旧路径且文件不存在），点"卸载"必然失败 → **已删除**（备份 `rollback\HKLM_..._IntelliJ IDEA 2024.2.2.reg`）。保留的是 Toolbox 接管的那条（`HKCU\...\Uninstall\IntelliJ IDEA 2024.2.2`，version 2026.1，无独立卸载器，属正常） |
| 复核 PowerToys（机主已重装 0.101.2362.0） | 新版 `%LOCALAPPDATA%\PowerToys` 3847 项；`PowerToys.exe` 0.101.2362.0、签名 Valid；两条记录（HKLM MSI `{FEC7CE70-…}` + HKCU bundle `{28CDFE7F-…}`）均指向新用户目录，图标与卸载器文件**都存在** |
| 删除 PowerToys 0.90.1 的残留 bundle 记录 | `HKCU\...\Uninstall\{b1781406-…}`：版本 0.90.1，`DisplayIcon`/`UninstallString`/`ModifyPath` 全是 `C:\Users\<旧用户名>\…` 死路径 → **已删除**（备份 `rollback\HKCU_..._{b1781406-…}.reg`）。**不能改成新路径**：那会让"卸载"去执行 0.90.1 的旧 bundle，可能破坏新装的 0.101 |
| `%LOCALAPPDATA%\Package Cache` 现状 | 当前版本两份缓存**必须保留**：`{FEC7CE70-…}v0.101.2362.0`（282.1 MB，MSI 缓存，卸载/修复要用）+ `{28CDFE7F-…}`（1.2 MB，bundle 缓存）。**可删可留**：0.90.1 的两份旧缓存共 **约 384 MB**（`{AA6BF89D-…}v0.90.1` 383.4 MB + `{b1781406-…}` 0.6 MB），已不被任何已安装产品引用 |

**至此除"用户目录改名"这件更大范围、与 D:\Apps 无关的旧账（见第一节「额外发现 1」）之外，本报告涉及的问题全部处理完毕。**

删除过的注册表键备份统一放在 `rollback\`（4 个 `.reg` + `README.md`，说明每个的来历与"不要盲目导入"）；D:\Apps 修复的 89 个取值级备份仍在桌面 `apps-repair-backup\`。

---

## 十、清理 GIMP / 360 / PowerToys 旧配置 / GitHub Desktop / 剪映（百度网盘只修不删）

处理范围（按机主当时的要求）：**注册表残留 + 程序文件夹 + 用户数据一起删**（五个应用），**百度网盘保留并修复**。

### 结果一览

| 应用 | 删除内容 | 释放 |
|---|---|---|
| **剪映 JianyingPro** | 程序与数据 `%LOCALAPPDATA%\JianyingPro`（2285 MB，含 Apps 9.8.0.13769 + User Data）、注册表 0 残留、空目录 `D:\capcut` | 2.3 GB |
| 剪映**草稿** | `D:\capcut\JianyingPro Drafts`（934 MB：`1月11日` 853 MB、`2月10日` 33 MB、`2月10日 (1)` 15 MB，含素材/时间线/封面）→ **送进回收站**（可还原，实测名称 `JianyingPro Drafts`） | 934 MB（清空回收站后） |
| **GIMP** | 先跑官方卸载器 `D:\Program Files\GIMP 2\uninst\unins000.exe /VERYSILENT`（退出码 0），再删 `D:\Program Files\GIMP 2`（1135 MB）、`%LOCALAPPDATA%\GIMP`、`%APPDATA%\GIMP`、`HKCU\Software\GIMP 3`，以及 `Classes` 下全部 `GIMP*` ProgID（约 616 个键，见删除清单） | 1.1 GB |
| **360** | `%APPDATA%\360se6`（521 MB，含浏览器程序与配置）、`%APPDATA%\360Safe`/`360Login`/`360SuperKiller`、`C:\ProgramData\360Safe`/`360SD`、全部 `360*` 注册表键、两个已禁用驱动项（`360Box64`/`360netmon`）；`C:\Program Files (x86)\360`（239.8 MB）已删掉大部分 | 760 MB |
| 360 剩余 | `C:\Program Files (x86)\360` 还剩 **9 项 / 203 MB**：`SafeWrapper.dll` 等被**注入**在 11 个 Chrome 进程 + Edge + powershell 里（360 的网页防护），无法当场删除 → 已登记到系统"**重启时删除**"队列（`PendingFileRenameOperations`，9 条） | 203 MB（**重启后**） |
| **GitHub Desktop** | 未安装（无任何程序文件），仅注册表残留：`github-windows`、`x-github-client`、`x-github-desktop-auth` 三个协议 + 开始菜单 `GitHub, Inc` 文件夹 | — |
| **PowerToys 旧配置** | 0.90.1 的缓存安装包 `Package Cache\{AA6BF89D-…}v0.90.1`（383.4 MB）+ `{b1781406-…}`（0.6 MB）+ 指向旧用户目录的 `AppUserModelId`/`AppModel` 键；**保留**当前 0.101 程序（1040.9 MB）与设置（`%LOCALAPPDATA%\Microsoft\PowerToys` 17.5 MB），已确认两者都在 | 384 MB |
| **百度网盘（只修）** | 真实安装在 `C:\Users\<user>\AppData\Roaming\baidu\BaiduNetdisk`（**8.6.0.102**，含 `uninst.exe`）。卸载记录 `HKLM\…\WOW6432Node\…\Uninstall\百度云管家`（版本还是 8.5.5）的 `InstallLocation`/`DisplayIcon`/`UninstallString` 已改指新目录；另外修好 5 处指向旧目录的处理器：`BaiduNetdiskImageViewerAssociations`、`Baiduyunguanjia` 协议、`BaiduYunGuanjia.torrent`、`Applications\BaiduNetdisk.open`、`BaiduNetdiskUnite.open` | 不删 |

**合计释放约 5.5 GB**；重启再释放 203 MB；清空回收站再释放 934 MB。

### 三个"藏在里面的坑"（值得单独记下来）

1. **360 劫持过默认浏览器**：`.htm/.html/.mht/.mhtm/.mhtml/.shtm/.shtml/.xht/.xhtml/.ses` 这 10 个扩展键在 `HKCU\Software\Classes` 下的**默认值被写成 `360seURL` / `360SeSES`**（还留了 `ksobak` 备份值）。更麻烦的是：**这些键的所有者是 360 遗留的、无法解析的 SID**，导致连管理员令牌都写不进去（`reg add` 直接 `Access is denied`，`DeleteValue` 报"无法写入到注册表项"）。
   处理：对 10 个键**逐个夺取所有权 → 重置权限项 → 恢复完全控制 → 删除 360 取值**（全部记录在日志里）。验证：`.htm` 的 HKCU 覆盖值已清空，回落到系统默认 `htmlfile`（= 机主的默认浏览器），不再指向已删除的 360。
2. **360 的 `SafeWrapper.dll` 被注入到浏览器/终端进程**里，所以程序目录删不干净 → 用"重启时删除"队列解决，**不需要杀掉机主正在用的浏览器**。
3. **360 在 `360Safe\deepscan` 挂载了自己的注册表 hive**（`HKU\360SPDM` → `spdm.dat`）→ 必须先 `reg unload HKU\360SPDM` 才删得掉那批文件。

### 备份与遗留事项

- 批量删除的注册表键清单：`rollback\deleted-registry-keys-2026-10-03.txt`
- 单项删除/修改前的 `.reg` 备份（含百度网盘记录改前的原状）：`rollback\*.reg`
- 修改前的重启队列备份：`rollback\PendingFileRenameOperations-before.txt`
- **360 剩余部分**：机器重启后（21:57），剩下的 203 MB 已被系统自动删除，注入的 DLL 也已卸载 —— 见第十二节。
- **剪映草稿**：`JianyingPro Drafts`（934 MB）由机主随后**手动清空回收站**删除，该空间已真正释放（见第十二节）。
- **PowerToys 的 MSIX 稀疏包状态**：清理旧配置时一并删掉了 3 个 `AppModel\SystemAppData\Microsoft.PowerToys.*`。若某个右键菜单类模块表现异常，在 PowerToys 设置里把该模块关掉再打开即可重建（见附录 A 第 34 条）。

---

## 十一、清理 WPS（"此电脑"里的 WPS网盘 图标 + 全部 WPS 残留）

### 1. 那个图标是什么

"此电脑"里的 **WPS网盘** 不是快捷方式，而是注册在资源管理器里的 **shell 命名空间项**：

| 项 | 键 |
|---|---|
| 此电脑中的图标 | `HKCU\...\Explorer\MyComputer\NameSpace\{5FCD4425-…}` |
| 桌面命名空间 | `HKCU\...\Explorer\Desktop\NameSpace\{7AE6DE87-…}` |
| 提供者 | 两个 CLSID 的 `InprocServer32` = `D:\Kingsoft\WPS Office\11.1.0.10009\office6\qingnse64.dll` |

WPS **早就卸载/搬走**（`D:\Kingsoft` 不存在、无 WPS 进程），DLL 已不存在，所以它渲染成一个**普通黄色文件夹**、点进去也没反应。

### 2. 删除内容

| 类别 | 明细 |
|---|---|
| 命名空间项 | 上表 2 个（图标本体） |
| WPS shell 扩展 CLSID | HKCU 7 个（WPS网盘 ×2、`qingshellext`、`QingNseContextMenu`、`nsemenu`、`kwpsshellext`、`kpdfcontextmenushellext`）+ HKLM/WOW6432Node 3 个（`qingshellext64.dll`、`kmso2pdfplugins*.dll`） |
| ProgID | **86 个** WPS 家族 ProgID：72 个（`WPS.*`/`ET.*`/`WPP.*`/`kso*`）+ 9 个 `KWPS.*` + 5 个收尾（`ksobak.pdf`、`KWPS.Application[.9]`、`KWPS.Document`、`KWPS.Template`） |
| App Paths | `wps.exe`、`et.exe`、`wpp.exe`（都指向已消失的 `D:\Kingsoft\...`） |
| 软件根键 | `HKCU\Software\Kingsoft`、`HKLM\Software\WOW6432Node\Kingsoft` |
| 服务 | 死掉的 `wpscloudsvr`（其 `C:\ProgramData\Kingsoft\office6\wpscloudsvr.exe` 已不存在） |
| 死引用 | 扩展键里的 **147 处**（130 + 17）：各扩展名的默认 ProgID、`OpenWithProgids`/`OpenWithList` 条目，以及 WPS 留下的 `ksobak`（它记录的"改默认程序前的备份值"） |
| 文件 | `%APPDATA%\Kingsoft`（211 MB）→ **回收站**；`%LOCALAPPDATA%\Kingsoft`（0.1 MB）与 3 个失效的 WPS 开始菜单快捷方式 → 删除 |

### 3. 一个必须记下来的"连锁风险"

删掉那 86 个 ProgID 后，`HKCU` 里 `.docx/.xlsx/.pptx/.png/.jpg/.pdf/.rtf/...` 的**默认程序仍指向这些已删除的 ProgID**——若不处理，双击这些文件会打不开。已清空这些覆盖值，让 Windows 回落到 `HKLM` 系统默认，并逐项验证生效 ProgID 均存在：

`.png→pngfile`、`.jpg/.jpeg→jpegfile`、`.gif→giffile`、`.bmp→Paint.Picture`、`.doc→Word.Document.8`、`.docx→Word.Document.12`、`.xls→Excel.Sheet.8`、`.xlsx→Excel.Sheet.12`、`.ppt→PowerPoint.Show.8`、`.pptx→PowerPoint.Show.12`、`.pdf→Acrobat.Document.DC`、`.rtf→Word.RTF.8`、`.csv→Excel.CSV`、`.svg→svgfile`、`.txt→txtfilelegacy`。

> ⚠ **这一轮只验到"ProgID 存在"为止 —— 而附录 A 第 19 条讲的正是这一步不够。**
> `.pdf→Acrobat.Document.DC` 这个 ProgID 确实存在，但它指向的 `Acrobat.exe` 后来才发现
> 早已卸载，所以双击 PDF **实际仍然是坏的**。登记项存在 ≠ 目标文件存在，完整验收要查到目标
> 文件那一层。（这正是 `health-check.ps1` 逐项核对"**目标文件**是否存在"、而不是只核对
> "登记项是否存在"的原因。）

### 4. 两次自我纠错（都已在过程中修好）

1. **API 用错**：通过 PowerShell 提供程序对象（`Get-Item … | DeleteValue`）删这些取值会报"无法写入到注册表项"，即使权限允许也一样；换成 .NET 原生 `OpenSubKey(path, $true)` 后**一次成功**（0 个键需要改权限）。我先前误判为"权限被锁"，白绕了 2 轮。
2. **校验逻辑踩了语言坑**：`reg.exe` 对不存在的键**会返回英文 "unable to find"**，而我的判定按中文"找不到"匹配 → 一度把"已删除"误报成"仍存在"。最终改用与语言无关的判定（PowerShell 路径存在性）复核，结论一致：**均已清除**。

### 5. 一次误命中（已核实无影响）

批量匹配 `wps` 时命中了 **`amdwps`** —— 它是 **`AMD Workload Profiling Scheduling Driver`（微软/AMD 组件，与 WPS 无关）**。核实：删除被系统拒绝、**键值完整**（`ImagePath`/`Type=1`/`Start=0`/`ErrorControl`/`DisplayName` 齐全）、驱动文件在位（67,144 字节，v10.0.26100.1150）；同类未被动过的 `amdgpio2`/`amdi2c`/`AmdK8` 键**同样读不到 ACL**（说明那是驱动键的固有保护，不是我改坏的），日志中没有任何取所有权动作。`rollback\HKLM_SYSTEM_…_amdwps.reg` 只是当时导出的一份**只读快照**，键本身未被改动。

---

## 十二、最终状态（截至本报告结束）

- **已重启一次**（21:57）：360 的"重启时删除"队列已执行 —— `C:\Program Files (x86)\360` 只剩空壳，**该空壳也已删除**；`360Box64.sys` / `360netmon.sys` 及其服务注册**均已消失**；注入到进程里的 `SafeWrapper.dll` 已随重启卸载。
- **回收站**：现存 `kingsoft`（211 MB，可还原）。**剪映草稿 `JianyingPro Drafts`（934 MB）已释放**：清理时先送进回收站，随后由**机主手动清空回收站**删除 —— 该 934 MB 已真正释放。
  （本条是事后向机主确认的，不是当时的推断。）
- **WPS**：`%APPDATA%\Kingsoft`、`%LOCALAPPDATA%\Kingsoft`、`D:\Kingsoft` 全部不存在；`Classes` 下已无任何 WPS 家族 ProgID。
- **磁盘**：C: 可用 95.8 / 237.4 GB，D: 可用 137.5 / 238.3 GB，E: 可用 208.2 / 953.9 GB。
- **这批清理累计释放约 6.5 GB**：360 约 960 MB（含重启后）+ 剪映 2.3 GB + 剪映草稿 934 MB + GIMP 1.1 GB + PowerToys 旧缓存 384 MB + WPS 211 MB + 其它。
- **回滚备份**：`rollback\` 共 113 个文件（105 个 `.reg` + 批量删除清单 + 重启队列留档 + `README.md`）；桌面 `apps-repair-backup\` 89 个 `.reg`。





---

# 附录 A：实战踩坑 34 条（工具 / API / 环境 / 判断）

> 这些是**实操中真实踩到**的，不是理论清单。凡是写脚本清理注册表或做迁移的人都可能遇到。
> 其中"改这个仓库的脚本时必须遵守"的条目已抽成规则，写在仓库根目录 [`AGENTS.md`](../AGENTS.md) 的「硬性约定」里；这里保留**完整经过与证据**。
>
> 编号只表示位置，不表示重要性。**同一件事的不同侧面已合并** —— 原先 37 条里有 3 对是重复的
> （`Test-Path` 静默 False、丢 BOM、`reg query` 的成本），合并之后是 34 条不同教训。

## A.1 环境与工具行为

| # | 坑 | 现象 | 正确做法 |
|---|---|---|---|
| 1 | **受限会话会把权限问题判错** | 在低完整性沙箱里读 `D:\WinRAR` 报"访问被拒绝"，据此写下"权限损坏"结论——**是误判** | 涉及权限的结论**必须用普通用户令牌复核**（直接交互，或走任务计划程序），不要用受限工具会话下结论 |
| 2 | **受限环境里逐键调用 API 极慢 —— 但"慢"不一定只因为环境** | 同样一段逐键检查，沙箱里 20 分钟跑不完（换 .NET + 一次性索引后 67 秒）。另有一条独立的成本模型：`reg query /f /s` 的开销 ≈ 根键数 × 关键词数，单次 5~10 秒 | 两件事一起做：① 判断"脚本慢"之前先确认环境；② 把关键词收敛，或改成**一次性建索引 + 内存判断**。**优化本身在任何环境都有收益** |
| 3 | **`Test-Path` 有"静默 False"，分不清"没有"和"读不到"** | 路径因权限不可达时，有时抛异常、有时直接返回 False → 被当成"文件不存在"，产生成片假阳性（本项目一批 **31 条假阳性**就是这么来的） | 用 `[IO.File]::GetAttributes()` 的异常类型区分：`FileNotFound`/`DirectoryNotFound`＝不存在，`UnauthorizedAccess`＝读不到；`\WindowsApps\`、`\DriverStore\` 这类设计上不可读的目录**直接跳过判定**；**批量报"不存在"时一定抽查真值** |
| 4 | **长任务的子进程会被清理** | 后台跑的体检跑到一半消失（不是脚本崩） | 长任务放后台任务/计划任务，别依赖前台 shell 存活 |
| 5 | **重定向时 stdout 是块缓冲** | 前台跑 20 分钟屏幕无输出，看着像死锁 | 让脚本**增量写日志/报告文件**，靠文件增长判断进度 |

## A.2 PowerShell 与注册表 API

| # | 坑 | 正确做法 |
|---|---|---|
| 6 | 双引号字符串里写中文引号（`"打开方式"`）会**截断字符串**，报一堆"缺少 }"却指向别处 | 中文引号用「」，Markdown 的反引号只在单引号字符串里用 |
| 7 | 双引号字符串里的**反引号是转义符**（Markdown 的 `` `code` `` 会把后面的引号转义）→ 字符串"吞掉"后续代码 | 同上：别在双引号字符串里放反引号 |
| 8 | 空名（默认值）不能用 `Set-ItemProperty -Name ''` / `Remove-ItemProperty -Name ''`（静默失败） | 写用 `Set-Item -Value`；删用 .NET `$rk.DeleteValue('')` |
| 9 | PowerShell 提供程序对象（`Get-Item`）删/写值时可能报"无法写入到注册表项"，**即使权限足够** | 热点路径统一改用 .NET：`[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)`（换用后一次成功、0 个键需要改权限） |
| 10 | `$PSScriptRoot` 在 `param` 默认值里可能为空 → 脚本启动即死 | 在函数体里解析脚本目录 |
| 11 | `reg.exe` 报错文案随语言变化（中文"找不到" / 英文 "unable to find"） | 存在性判断不要依赖错误字符串，用 `Test-Path` 或 `OpenSubKey() -ne $null` |
| 12 | 图标索引可能是**负数**（`wmploc.dll,-730`） | 剥离正则写 `,\s*-?\d+\s*$`，再兜底剥掉"末尾逗号后不含反斜杠"的部分 |
| 13 | 注册表键名**不区分大小写**：`shell\open\command` 与 `shell\Open\command` 是同一个键 | 只查一次，否则产出重复行 |
| 14 | 通配符太宽会误伤：用 `wps` 匹配时命中了 `amdwps`（AMD 驱动） | 模式收紧（`^WPS\.`）+ 白名单，**删除前 dry-run 打印清单** |
| 15 | 受保护的注册表键（所有者为遗留 SID / 带拒绝项）**连管理员都写不进去** | 顺序：**夺取所有权 → 清除拒绝项 → 授权完全控制 → 再改**；不要 `icacls /reset` 硬刷整棵树 |
| 16 | 被注入到其它进程的 DLL 删不掉（本次 360 的 `SafeWrapper.dll` 被注入 11 个 Chrome/Edge/终端进程） | 写入"重启时删除"队列（`PendingFileRenameOperations`），**不要杀用户正在用的程序** |
| 17 | 目录可能被挂载成注册表 hive（本次 360 的 `spdm.dat`） | `HKLM\SYSTEM\CurrentControlSet\Control\hivelist` 查出来，先 `reg unload` |
| 18 | 报告不做聚合会被噪音淹没（Photoshop 残留一项就是 89 行） | **按"不存在的目标"聚合 + 导出 CSV**；并把"缓存被清理"这类降级为警告 |

## A.3 判断与流程

| # | 坑 | 教训 |
|---|---|---|
| 19 | **"程序还在" ≠ "关联能用"**：验证过 `.pdf → Acrobat.Document.DC` 这个 ProgID 存在，却没查它指向的 `Acrobat.exe` 是否还在——后来体检发现 Acrobat 已卸载，**双击 PDF 实际是坏的** | 验证要查到底层目标文件，不能只看登记项是否存在 |
| 20 | **清理模式成体系很重要**：清 WPS 时漏了 `KWPP.*`/`KET.*`（WPS 演示/表格）以及 `Word.*`/`Excel.*` 上的**图标覆盖键**（还漏查了 `WOW6432Node`），残留到下一轮才体检出来 | 用"体检 → 修复 → 再体检"闭环；别靠一次性拍脑袋枚举 ProgID 前缀 |
| 21 | 边改边验，每改一处就重跑 | 每次优化/修假阳性都重跑一遍，才能把"环境慢"和"算法慢"、"真阳性"和"假阳性"分开 |
| 22 | 破坏性操作前先备份、并**区分用户数据与程序残留** | 用户数据（草稿/书签/配置）先送回收站；程序残留可直接删。⚠ 注意"送回收站"**不等于已释放**（见 A.5 第 33 条） |
| 23 | **脚本里"少定义一个函数"会造成整段静默跳过**：清理脚本漏定义 `Get-RegValue`，导致协议、App Paths、部分卸载记录三段**一条都没执行**，而看总数时没发现 | ①每个功能段结束打印**计数**（0 条也要打印），②关键公共函数先做一次自检调用 |
| 24 | **文本写入工具重写 `.ps1` 会丢掉 UTF-8 BOM —— 而且这个坑只在 5.1 暴露** | 5.1 读无 BOM 脚本会按 ANSI 解码 → 中文全变乱码 → 报出上百个"意外的标记 / 缺少 }"的**假**语法错误（文件内容其实是好的）；而 PS7 能读无 BOM 文件，同一个文件在 PS7 下完全正常 —— **所以陷阱只在 5.1 显形，只在 7.x 上验证等于没验证**。多数编辑器 / 批量替换 / AI 编辑工具都会丢 BOM。想同时跑两个引擎就**始终保留 BOM**，改完用 5.1 复验：`[IO.File]::WriteAllText($p,$text,(New-Object Text.UTF8Encoding($true)))` |
| 25 | 受限会话里**同一路径判定会自相矛盾**（`Test-Path` 为 True，`dir` 却说找不到） | 报告里若"严重"项集中在某个目录，先抽样复核真值再动手 |

## A.4 从 PowerShell 5.1 升级到 7.x 之后

| # | 坑 | 教训 |
|---|---|---|
| 26 | **同一个"缺失"判定，在 PS7 下会静默失效**：PS7（.NET Core）把 .NET 异常包成 `MethodInvocationException` / `RuntimeException`，所以 `catch [System.IO.FileNotFoundException]` 这类**按 .NET 类型匹配的 catch 永远不成立** → 所有"文件不存在"被当成"读不到"跳过，报告变成"一切正常"的**假阴性**（实测：同一份脚本，5.1 报 43 项严重，PS7 只报 1 项） | 不要按 .NET 异常类型 catch；**解包 `InnerException` 后按"类型名字符串"判断**：`while ($ex.InnerException) { $ex = $ex.InnerException }`，再 `switch ($ex.GetType().Name)` |
| 27 | **`.cmd` 里的中文注释会变问号**：批处理按代码页读取，若按 UTF-8/ASCII 写入，中文全变 `?`（甚至影响命令解析） | 批处理里**只用 ASCII 注释**（写英文）；中文留给 `.ps1` |
| 28 | **同一个文件被两处重定向会互相锁死**：清理脚本自己写日志，而启动器又把 stdout 重定向到同一个文件 → `being used by another process`，脚本日志**全部写不进去** | 一个进程的日志只由一个地方写：窗口输出与脚本内部日志**分成两个文件** |
| 29 | **取路径的正则要排除字段分隔符**：把多个注册表字段用 `|` 拼成一行再取路径时，`[^"]+?` 会跨过 `|` 拼出非法路径；而 PS7 的 `Path.GetExtension` 对非法路径**会抛异常**（5.1 不会）→ 规则静默失效 | 正则写成 `([A-Za-z]:\\[^"|]+?\.(?:exe|dll|ico))`；"取路径"这类小函数要在**两个引擎上各测一遍** |
| 30 | 升级引擎后的正确姿势 | 保留旧版脚本（`versions/v1-ps5.1/`），新脚本做成**双引擎兼容**，启动器**优先 `pwsh`、回退 `powershell`**，并以"同一次体检在两个引擎下结果逐条一致"作为验收标准 |

## A.5 卸载残留清理的补充（§十~§十二）

> 这 4 条来自迁移的**第二波**：迁移弄坏了文件 → 弃用卸载 → 清理卸载残留。它们此前只存在于
> §十~§十二 的叙述里，没有成为可复用规则。

| # | 坑 | 教训 |
|---|---|---|
| 31 | **卸载记录不是"能改路径就改路径"**：把旧版本（PowerToys 0.90.1）的卸载记录改指到新目录，会让"卸载"去执行**旧** bundle，可能破坏新装的版本 | 这类记录**要删不要指**。判据：同一产品已装新版本 + 该记录是旧版本遗留 → 删记录本身，别动新版本的登记 |
| 32 | **删掉一族 ProgID 必须连带清理指向它的引用**：删掉 86 个 WPS ProgID 后，`HKCU` 里 `.docx/.xlsx/.pdf/...` 的默认值仍指向它们 —— 从"死 ProgID"变成"死默认值"，双击照样打不开 | 删除型操作要**顺着引用往回查一遍**（各扩展名默认值、`OpenWithProgids`、`OpenWithList`）；`health-fix.ps1` 的 C 段就是这个闭环 |
| 33 | **"送回收站"不等于"释放空间"**：剪映草稿 934 MB 先送回收站，直到机主随后手动清空回收站，这 934 MB 才真正释放 | 回收站是"推迟决定"，既不是"已释放"也不是"备份"。清理报告里要么注明"待清空回收站后才释放"，要么随后清空 |
| 34 | **清"旧版本残留"可能连累在用的新版本**：清 PowerToys 旧配置时连 `AppModel\SystemAppData\Microsoft.PowerToys.*`（MSIX 稀疏包状态）一起删了，可能导致右键菜单模块异常 | 删共享状态前先确认它**不被在用版本引用**；`AppModel` / `AppUserModelId` 这类尤其危险。删完若在用的程序表现异常，先怀疑这里（PowerToys 可在设置里把模块关开重建） |

---

# 附录 B：本机现状速查（某一时刻的快照）

> ⚠ **这是快照，不是"当前状态"。** 磁盘可用量、体检条数、备份文件数都会随时间变化 ——
> 要当前值请跑 `scripts\health-check.cmd`，看 `local/reports/` 里最新那份报告。
> 本附录只保留**有长期意义**的信息：机器布局、引擎版本、做过哪些清理、产物在哪。

- **引擎**：PowerShell **7.6.6 (Core)** 已安装，5.1 仍在；三个 `.cmd` 启动器都优先用 `pwsh`、找不到才回退 5.1。
- **磁盘布局**（**总容量**）：C: 237.4 GB / D: 238.3 GB / E: 953.9 GB。**可用量会变，不要在别处引用本文的数字。**
- **`D:\Apps` 登记状态**：迁移涉及的应用登记已全部对齐新路径；PowerToys 0.101.2362.0、JetBrains Toolbox 3.8.1、百度网盘 8.6.0.102 均正常。
- **已清除**：GIMP、360（含驱动与残留）、GitHub Desktop 残留、剪映、WPS 全套残留（含 `KWPP.*`/`KET.*`/图标覆盖）、PowerToys 旧缓存、Adobe（Photoshop/Acrobat 关联与 ProgID）、ACDSee、Unity/LM Studio/MongoDB 协议、旧用户目录的失效记录、mpv 全套关联修复。
- **体检结论**（截至本文，用 PS7.6 跑的）：当时那 7 项"严重"**全部为有意保留**（Steam/ACE 由各自启动器自维护、Adobe 因卸载器仍在而保守保留）；另有大量"警告"来自 `Package Cache` 被清理后系统组件的卸载入口失效（不影响使用）。**条数每次体检都会变**，以 `local/reports/` 里最新那份为准。
- **回滚备份**：`local/rollback/`（由 `health-fix` 逐条写入，**每次运行一个时间戳子目录**，所以总量随时间增长；早期批次还有 `deleted-registry-keys-2026-10-03.txt` 这类清单）+ 桌面 `apps-repair-backup/`（92 个 `.reg`，由早期版本的 `repair-migrated-apps` 写入；该脚本现已改为写入 `local/rollback/`）。
- **版本档案**：`versions/README.md`（`v1-ps5.1/` 旧版、`v2-ps7.6/` 当前版，含双引擎一致性验收证据）。