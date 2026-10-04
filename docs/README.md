# docs 索引

本目录四篇文档，按"你要做什么"分，不按"我知道什么"分。**每篇都能独立读完，互相只做链接、不复制内容。**

| 文档 | 给谁看 | 什么时候看 |
|---|---|---|
| [disk-health.md](disk-health.md) | 想长期保持磁盘不爆的人 | 每月扫一眼 / 每季度清理前 / 系统盘突然掉得很快时 |
| [migration-checklist.md](migration-checklist.md) | 准备搬家（换盘、改路径）的人 | **动手之前**通读；动手时按阶段勾 |
| [registry-reference.md](registry-reference.md) | 迁移后要修登记、或要改检查脚本的人 | 迁完做复检时；排查"系统认不出程序"时 |
| [case-report-d-apps-migration.md](case-report-d-apps-migration.md) | 想看完整过程与证据的人 | 想了解"这套规则是怎么总结出来的"、或复核某个结论时 |

## 推荐阅读顺序

1. **只想让磁盘别爆** → 只看 [disk-health.md](disk-health.md)。
2. **要搬家** → [migration-checklist.md](migration-checklist.md)（含动手前的判断与禁令）→ 迁完按 [registry-reference.md](registry-reference.md) 复检。
3. **遇到"文件还在但系统认不出程序"** → 直接用仓库脚本 `scripts/health-check.ps1` 体检，再对照 [registry-reference.md](registry-reference.md) 理解它报的每一类是什么。
4. **想系统了解全貌** → 四篇按上表顺序读，最后看[案例报告](case-report-d-apps-migration.md)（它把 33 条实战踩坑作为附录完整保留）。

## 与 scripts/ 的关系

- 文档里的命令都是**可直接粘贴执行**的片段；长期重复做的事已经脚本化：`scripts/health-check.ps1`（只读体检）、`scripts/health-fix.ps1`（按规则清残留）、`scripts/repair-migrated-apps.ps1`（按映射表批量改写）。
- 脚本产物一律写进仓库根目录的 `local/`（注册表备份 `local/rollback/`、体检报告 `local/reports/`），该目录**已被 .gitignore 排除**。
- 三个脚本**不依赖任何第三方工具**：文档里提到的 WizTree / Everything / Geek / RegScanner / Registry Finder / Beyond Compare 是**给人和 AI 代理做探索、预览与交叉验证**用的，脚本本身刻意不调用它们。

## 写作约定（新增或修改文档时遵守）

1. 开头三行写清：**给谁看 / 什么时候看 / 看完能得到什么**；结尾一行给出"下一步看哪篇"。
2. 人称：指南类用"你/建议"，案例报告用"当时/本次"；**不在指南里写"我"**。
3. **一处一源**：12 类登记只在 [registry-reference.md](registry-reference.md) 定义；命令片段只在最相关的那篇出现一次，其他篇用链接。
4. 通用建议里不写具体容量、盘符布局等单机数值——那些记在案例报告的「本机现状速查」。
5. 文件名用英文 kebab-case，内容用中文（与仓库其余部分一致）。
