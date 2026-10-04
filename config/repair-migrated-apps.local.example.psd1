# ============================================================================
#  repair-migrated-apps.ps1 的「机器专属映射」模板
#
#  用法：复制到 <仓库根>\local\repair-migrated-apps.local.psd1，再按本机情况填写。
#        （local/ 已被 .gitignore 排除，填进去的真值不会进仓库。）
#  不填也能跑：脚本只用内置的通用映射（旧安装位置 -> D:\Apps 布局）。
#
#  为什么是「数组 + Old/New」而不是哈希表：映射顺序敏感——更具体的前缀必须排在
#  更短的前面前面。psd1 不允许 [ordered]，数组才能保住顺序。
#
#  编码：本文件含中文，必须存成 **UTF-8 带 BOM**，否则 Windows PowerShell 5.1
#        会按 ANSI 解码导致乱码。
# ============================================================================
@{
    # 旧的"已登记路径前缀" -> 真实当前位置。本机条目排在脚本内置的通用映射之前。
    PathMap = @(
        # @{ Old = 'C:\Users\<旧用户名>\AppData\Local\Programs\<程序>'; New = 'D:\Apps\Installed\<程序>' },
        # @{ Old = 'D:\某个旧位置';                                     New = 'D:\Apps\Installed\新位置' }
    )

    # 用户目录改名：只在 HKCU\Software\Classes 下生效（URL 处理器等），
    # 绝不用于卸载记录——把死路径改成另一个死路径没有意义。
    ProfileMap = @(
        # @{ Old = 'C:\Users\<旧用户名>\'; New = 'C:\Users\<当前用户名>\' },
        # @{ Old = 'C:\Users\<旧用户名>';  New = 'C:\Users\<当前用户名>' }
    )
}
