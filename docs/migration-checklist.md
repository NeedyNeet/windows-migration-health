# 大批量迁移避坑清单（照着做）

> **给谁看**：准备把程序/数据从一块盘搬到另一块盘、换硬盘、或者动过 Windows 用户目录的人。
> **什么时候看**：动手**之前**通读一遍；动手时按阶段逐条勾。
> **看完你能**：判断"该不该迁、怎么迁"，并在迁完之后把系统登记全部改对（这一步不做，就会出现"文件还在但系统认不出程序"）。

配套：[12 类登记参考](registry-reference.md)（迁完要复检的东西）· [磁盘长期健康管理](disk-health.md)（空间不够时先看这篇）

---

## 0. 三句话原则

1. **文件可以随便搬，"登记"不会跟着走。** 系统里记录一个程序位置的地方有 12 类，它们全都还指着旧路径。
2. **迁移 = 移动文件 + 同步登记。** 只做前半段，结果一定是"双击打不开、搜索搜不到、卸载按钮失效"。
3. **没有"旧→新映射表"就不要开始搬。** 有了它，事后修引用是机械替换；没有它，只能全盘搜索一点点猜。

---

## 1. 阶段 0：先判断该不该迁（含三条禁令）

| 决定 | 说明 |
|---|---|
| ❌ **绝不重命名 Windows 用户目录**（`C:\Users\<名>` → 别的名字） | 改名后 `C:\Users\旧名\...` 会留在注册表里成百上千处，一大批软件的记录、关联、配置全部失效。**要换用户名就新建账户再迁移**，或者接受"事后全量修引用"的工作量 |
| ❌ 不要用 junction/符号链接硬搬**会自动更新的程序** | 更新器往往忽略自定义位置，会把新版本装回默认目录，结果两套并存 |
| ❌ 不要把 `Program Files`、`System32` 下的东西整体搬走 | 大量程序写死绝对路径，服务/驱动也会失效 |
| ✅ **首选"重装到新位置"**，或用厂商自带的"移动安装/修改安装路径"功能 | 安装器会自己把登记写对，这是成本最低的路 |
| ✅ 便携软件（免安装）搬运风险最小 | 但仍要注意：有些便携软件注册了文件关联/右键菜单，搬完要重跑它自带的 `install` 脚本 |
| ✅ 用户文件夹（桌面/文档/下载/图片）要搬家 | 用**资源管理器 → 右键 → 属性 → 位置 → 移动**，系统会改好对应的注册表项 |

---

## 2. 阶段 1：迁移前（基线快照 + 映射表 + 三项检查）

### 2.1 导出基线（**这一步能救命**）

没有基线，事后无法判断"什么变了"。把下面整段存成 `.ps1` 跑一次（需要管理员）：

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$bak = "D:\_migration-baseline-$stamp"; New-Item -ItemType Directory $bak -Force | Out-Null

# 1) 卸载记录（"设置 → 应用"的数据来源）
reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" "$bak\uninstall-hklm.reg" /y
reg export "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" "$bak\uninstall-hklm32.reg" /y
reg export "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" "$bak\uninstall-hkcu.reg" /y

# 2) App Paths / 文件关联 / 打开方式（Classes 太大，按需导子键）
reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths" "$bak\apppaths-hklm.reg" /y
reg export "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths" "$bak\apppaths-hkcu.reg" /y
reg export "HKCU\SOFTWARE\Classes" "$bak\classes-hkcu.reg" /y
reg export "HKLM\SOFTWARE\Classes\Applications" "$bak\classes-applications.reg" /y

# 3) 服务 / 驱动 / 计划任务 / 启动项
reg export "HKLM\SYSTEM\CurrentControlSet\Services" "$bak\services.reg" /y
schtasks /query /xml ONE > "$bak\scheduled-tasks.xml"
reg export "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "$bak\run-hkcu.reg" /y
reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "$bak\run-hklm.reg" /y

# 4) "此电脑"里的命名空间图标 / 自动播放 / 默认程序注册
reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace" "$bak\namespace.reg" /y
reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "$bak\autoplay.reg" /y
reg export "HKLM\SOFTWARE\RegisteredApplications" "$bak\registeredapps.reg" /y

# 5) 目录清单（可搜索的"文件台账"）
Get-ChildItem C:\,D:\ -Directory -Depth 2 -ErrorAction SilentlyContinue |
  Select-Object FullName | Out-File "$bak\dirs.txt" -Encoding utf8
```

### 2.2 记录"旧 → 新"映射表

**本清单最重要的一个习惯。** 每搬一个东西就填一行：

| 应用 | 旧路径 | 新路径 | 需要重做的登记（备注） |
|---|---|---|---|
| 例：mpv-lazy | `D:\mpv-lazy` | `D:\Apps\Portable\mpv-lazy` | App Paths + 86 个 ProgID + 自动播放处理器 → 用它自带 `installer\mpv-install.bat` 重跑 |

有了这张表，"事后修引用"就是机械替换；没有它，只能靠全盘搜索一点点猜。

### 2.3 动手前的三项检查

1. **关掉待迁移程序**（含托盘程序与服务），否则文件被占用。先看有没有服务指向它：
   ```powershell
   Get-CimInstance Win32_Service | Where-Object PathName -like 'D:\Apps\*'
   ```
2. **抽检来源目录权限是否"带病"**（所有者是无法解析的遗留 SID 时，连管理员都写不进去）：
   ```powershell
   Get-Acl '<路径>' | Select-Object Owner
   icacls '<路径>'
   ```
3. **确认目标父目录不受系统保护**：不要放进 `Program Files`、`Windows`、`System32`。

---

## 3. 阶段 2：迁移中（用 robocopy，不要用剪贴板）

```powershell
# 常规：保留数据与时间戳，不搬权限（让新位置继承正常权限，更稳）
robocopy "D:\Old\App" "D:\Apps\Installed\App" /E /COPY:DAT /DCOPY:T /R:1 /W:1 /MT:8 /LOG:"D:\_move.log"

# 有安全要求、需要一并保留权限时：额外加 /COPY:DATS /SECFIX
# 搬完校验：再跑一次带 /L（只列不复制），应显示 0 个待复制文件
robocopy "D:\Old\App" "D:\Apps\Installed\App" /E /L
```

- 大量小文件用 `/MT:8`；机械盘可降到 `/MT:4`。
- **不要**两个目录之间"剪切 + 粘贴"，尤其跨盘——失败时会留下半截。
- 搬完**先别删旧目录**，等全部验证通过再删。

---

## 4. 阶段 3：迁移后（这一步决定成败）

### 4.1 复检 12 类登记

逐类核对，完整的位置清单、失效表现与修复方法见 **[12 类登记参考](registry-reference.md)**。最少要做的是：

- [ ] 卸载记录（`InstallLocation` / `DisplayIcon` / `UninstallString` / `ModifyPath`）
- [ ] App Paths（`HKLM` + `WOW6432Node` + `HKCU` 三处）
- [ ] 文件关联（`<ext>` 默认值、`OpenWithProgids`、`ksobak` 之类的备份值）
- [ ] 打开方式动词（`Classes\Applications\<exe>`）
- [ ] 右键菜单与 CLSID 外壳扩展
- [ ] "此电脑/桌面"命名空间图标
- [ ] 协议处理（`xxx://`）
- [ ] 自动播放 / 默认程序注册
- [ ] 服务与驱动的 `ImagePath`
- [ ] 计划任务、启动项、`PATH`
- [ ] 快捷方式（**注意也有一批直接躺在 `Start Menu` 根目录、不在 `Programs` 里**）

**统一检查方法**（按旧路径全量搜）：

```powershell
reg query "HKLM\Software\Classes" /f "D:\mpv-lazy" /s
reg query "HKCU\Software\Classes" /f "D:\mpv-lazy" /s
reg query "HKLM\Software\Microsoft\Windows\CurrentVersion" /f "D:\mpv-lazy" /s
```

两个必须知道的判定细节：

1. `reg query` 对**不存在的键返回的文案随系统语言变化**（英文 `unable to find`、中文"找不到"）→ 脚本里不要用错误文本判断存在性。
2. 把旧路径按映射表换成新路径后，**先确认新目标真的存在**；不存在就**不要写入一个同样无效的路径**，而是报告出来人工决定。（否则就是把死路径改成另一个死路径。）

### 4.2 别忘了应用自己配置里写死的绝对路径

注册表之外，很多程序把路径写在自己的配置文件里：

| 类型 | 例子 |
|---|---|
| 编辑器 / IDE | VS Code `settings.json`、JetBrains `idea.properties` |
| Python | `pyvenv.cfg`、`.pth` 文件、conda `envs.txt` |
| 版本控制 | `.gitconfig`（如 `core.hooksPath`） |
| 数据库 | MySQL `my.ini` |
| 便携软件 | mpv 的 `portable_config/*.conf`、播放器的播放列表/皮肤路径 |
| 包管理器 | npm `prefix`、pnpm store、pip 配置 |

```powershell
# 在这些目录里搜旧路径片段（rg 或 findstr）
rg -n --hidden "D:\\mpv-lazy" "D:\Apps"
findstr /s /i /m /c:"D:\mpv-lazy" D:\Apps\*.*
```

### 4.3 验收测试（站在用户角度点一遍）

- [ ] 双击常见文件类型（文档/图片/音乐/视频/压缩包）能正常打开
- [ ] `Win+R` 输入程序名（如 `mpv`、`BCompare`）能启动
- [ ] 开始菜单/任务栏**搜索**能找到迁移后的程序
- [ ] "设置 → 应用"里每条记录**图标正常、能卸载/修复**（不必真卸，点开看是否报错）
- [ ] 右键菜单项可用（尤其是迁移过外壳扩展的）
- [ ] 协议链接可用（如 `notion://`）
- [ ] 开机自启仍生效
- [ ] 用户目录与目标盘都没出现"空的同名目录"（那是搬走后留下的空壳）

> 本仓库的 `scripts/repair-migrated-apps.ps1` **默认就是试运行**：把它当"引用体检"工具，先跑一次看输出（哪些键还指向旧路径、哪些目标文件不存在），确认后再 `-Apply`。换一次迁移就改一次 `local\repair-migrated-apps.local.psd1` 里的映射表即可复用（模板见 `config\repair-migrated-apps.local.example.psd1`）。

---

## 5. 迁移台账模板（每次迁移填一张）

复制到你的笔记里：

````markdown
## 迁移批次：2026-XX-XX  执行人：___

| 应用 | 版本 | 旧路径 | 新路径 | 服务/驱动 | 卸载记录 | App Paths | 关联/协议 | 右键菜单 | 命名空间 | 快捷方式 | 自启/任务 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 例：mpv-lazy | 0.40.0 | D:\mpv-lazy | D:\Apps\Portable\mpv-lazy | 无 | 无 | ✔已改 | 86 个 ProgID 重注册 | 无 | 无 | ✔ | 无 | 用它自带 installer 重跑 |

迁移后验收：□ 双击文件  □ Win+R  □ 搜索  □ 卸载/修复按钮  □ 右键菜单  □ 协议  □ 自启
基线快照位置：D:\_migration-baseline-YYYYMMDD-HHmm\
回滚备份位置：local\rollback\
遗留问题：______________________________________________
````

---

## 6. 迁移相关的五条纪律

1. **改路径能修的就别删。** 删掉会让"设置 → 应用"少一条记录；只有在"新位置根本没有对应文件"时才删。
2. **一切改动可回滚。** 每步都留 `.reg` 备份 + 删除清单 + 说明（写清"哪个文件对应哪个键、为什么删、要不要导入"）。
3. **动手前先 dry-run。** 先打印计划改动，确认无误再真正执行。
4. **先备份，后改动。** 改一个键前 `reg export`；批量删除留一份清单。
5. **结论要靠独立复核。** 尤其是权限相关判断：不要因为一次报错就断定"权限损坏"，也不要把"读不到"当成"不存在"（详见[案例报告](case-report-d-apps-migration.md)里那次误判）。

---

**下一步**：[12 类登记参考](registry-reference.md) 逐类核对；空间不够先看[磁盘长期健康管理](disk-health.md)。
