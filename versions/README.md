# 版本档案（PowerShell 5.1 → 7.6 迭代）

本目录保存**同一套工具的先后两个版本**，便于对比、回退，也记录"为什么要改"。

| 目录 | 版本 | 说明 |
|---|---|---|
| `v1-ps5.1\` | 第 1 版（原始） | 在 Windows PowerShell **5.1** 上写并验证的版本。**但只在 5.1 下结果正确**：在 PS7 下会把"文件不存在"误判成"读不到"从而漏报（详见下）。已冻结，不再修改。 |
| `v2-ps7.6\` | 第 2 版 | 同时兼容 **5.1 与 7.x**，并用 PowerShell **7.6.6** 完成验收。 |

> **归档 ≠ 可直接运行**：
> - `v1-ps5.1\health-fix.cmd` 里的 `DIR` 是脱敏占位符（`<工作区>`），**不填就跑不起来**；它还含中文注释，违反现行「`.cmd` 只用 ASCII」的约定。它是冻结归档，不再修。
> - `repair-migrated-apps.ps1` 在 v1 与 v2 之间**逐字节相同**（SHA256 相等），所以它天然兼容两个引擎；它也是三个脚本里最晚才跟上「读不到 ≠ 不存在」（`Test-Exists`）的那个。
> - **现行版本永远是 [scripts/](../scripts/)**，本目录只供对比与回退。
> - **v2 冻结于 2026-10 初**；之后 `scripts/` 继续演进，两者已经不同 —— 例如旧路径扫描已从 `reg query /f` 换成 .NET 自遍历（本机实测 52~55 分钟 → 4 分钟）。**要看当前行为/性能，永远读 `scripts/`，别读这里。**

> 引擎选择：两个 `.cmd` 启动器都会**优先用 `pwsh`（7.x）**，找不到才回退 `powershell`（5.1）。不确定时双击 `.cmd` 即可。

---

## 一、v2 相对 v1 改了什么

| # | 改动 | 为什么（实际问题） |
|---|---|---|
| 1 | 脚本头加引擎自适应：`$script:PSName`（引擎名写进报告/日志）、`$script:Enc`（PS7 用 `utf8BOM`、5.1 用 `UTF8`，让两引擎产出同规格文件） | 报告/日志编码在两个引擎下默认不一致 |
| 2 | **新增 `Get-ExceptionClass`：解包 `InnerException`，按"类型名"判断**；`Get-Status` / `Test-Missing` 全部改用它 | **最关键的兼容性 bug**：PS7(.NET Core) 把 .NET 异常包成 `MethodInvocationException` / `RuntimeException`，`catch [System.IO.FileNotFoundException]` **永远匹配不上** → PS7 下所有"缺失"都被判成"读不到"而跳过，体检报告变成"一切正常"的**假阴性**（实测：同一份文件 5.1 报 43 项严重、PS7 只报 1 项） |
| 3 | 判定顺序修正：无扩展名先试 `.exe` 再下结论 | 注册表里有 `…\system32\perfmon /sys /load` 这类写法，`perfmon.exe` 其实存在，原来会误报 |
| 4 | `\WindowsApps\`、`\DriverStore\` 下的目标一律跳过判定 | 这两处对普通用户 ACL 受限，文件存在性无法可靠判断（Store 应用、驱动仓库），原来会产生假阳性 |
| 5 | `.cmd` 启动器改为**优先 `pwsh`**，并用**纯 ASCII（英文注释）** | `cmd.exe` 按代码页读批处理，中文注释在 ASCII 写入后会变 `?`；同时避免 GBK/UTF-8 混用问题 |
| 6 | `health-fix.ps1`：新增 `C2` 段（`htmlfile` 等**非扩展名类型键**的图标覆盖清理）、悬空默认值 `D` 段、Adobe/Java 记录规则、`XtuService` 服务、每段**计数统计** | ①360 曾把 `htmlfile` 图标指向自己的 exe，卸载后 .htm 图标坏了；②`.snk/.epub/.et` 等指向"根本不存在的 ProgID"；③上一版漏定义函数导致**整段静默跳过**，所以现在强制打印每段计数 |
| 7 | 启动器重定向分离：窗口输出 → `health-fix-elevated.txt`；脚本自己的日志 → `health-fix-log.txt` | 两者若指向同一文件会**互相锁死**（"being used by another process"），实测踩过 |
| 8 | `Get-ExeFrom` 的取路径正则排除 `|` | 原来会跨过字段分隔符拼出 `…2023|C:\…\x.ico` 这种非法路径；而 PS7 的 `Path.GetExtension` 对非法路径会抛异常 → 规则静默失效（5.1 不会抛） |

## 二、验收证据

| 项目 | 结果 |
|---|---|
| 双引擎语法校验（`Parser::ParseFile`） | `health-check.ps1` / `health-fix.ps1` / `repair-migrated-apps.ps1` 在 5.1 与 7.6 下均 **OK** |
| `Get-Status` 分支探针（同一批路径） | 两引擎**逐条一致**：缺失→`missing`、受限→`denied`、存在→`ok` |
| 完整体检对比（同一份脚本、同一时间窗） | 5.1：**12 严重 / 137 警告 / 3 提示**；7.6：**12 严重 / 137 警告 / 3 提示**；**严重项集合逐条相同**（`Compare-Object` 无差异） |
| 清理后最终体检（PS7.6） | **7 严重 / 137 警告 / 3 提示**（剩余 7 项见下） |
| 回滚备份 | `rollback\` 共 **545 个 `.reg`**，每条改动前导出 |

## 三、使用方式

```bat
rem 体检（只读）——双击即可，自动选引擎
health-check.cmd

rem 更快：编辑 health-check.cmd，把  set "SKIP="  改成  set "SKIP=-SkipOldPathScan"

rem 清理（默认试运行，加 -Apply 才写入；会自动请求管理员）
health-fix.cmd
health-fix.cmd -Apply
```

命令行等价写法：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\health-check.ps1          # 用 7.x
powershell -NoProfile -ExecutionPolicy Bypass -File .\health-check.ps1    # 用 5.1
```

## 四、两版共同的注意事项

1. **`.ps1` 必须是 UTF-8 带 BOM**：5.1 读无 BOM 的脚本会按 ANSI 解码 → 中文全乱码 → 报出上百个**假**语法错误。用编辑器改过脚本后请补 BOM：
   ```powershell
   $p='.\health-check.ps1'; [IO.File]::WriteAllText($p,[IO.File]::ReadAllText($p),(New-Object Text.UTF8Encoding($true)))
   ```
   （PS7 能读无 BOM 的脚本，所以这个坑**只在用 5.1 时暴露**。不确定就双击 `.cmd`。）
2. **`reg.exe` 的报错文案随语言变化**（中文"找不到" / 英文 "unable to find"）→ 不要用错误文本做存在性判断。
3. **默认值（空名）** 不能用 `Remove-ItemProperty -Name ''`，要用 .NET `DeleteValue('')`。
4. 受限权限下删不掉的键/文件：键走"夺取所有权 → 清拒绝项 → 授权 → 再改"；文件走"重启时删除"队列。

## 五、清理后仍保留的 7 项（有意为之）

| 项目 | 为什么保留 |
|---|---|
| `Steam App 1250760 / 2050650 / 993090` | 这些记录由 **Steam 自己维护**，删了会被重建，且可能影响游戏识别 |
| `AntiCheatExpert` | 由游戏启动器（Hypergryph Launcher）管理，同上 |
| `PHSP_24_7`（Adobe Photoshop 2023）、`UXPW_1_1_0`（UXP WebView Support） | 其 **Adobe 卸载器仍然存在**（`…\Adobe Desktop Common\HDBox\Uninstaller.exe`），属于"半残留"，保守保留；要彻底清建议用 **Adobe 官方清理工具**或 **Geek Uninstaller** |
