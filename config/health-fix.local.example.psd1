# ============================================================================
#  health-fix.ps1 的「机器专属配置」模板
#
#  用法：复制到 <仓库根>\local\health-fix.local.psd1，再按本机情况填写。
#        （local/ 已被 .gitignore 排除，填进去的真值不会进仓库。）
#  不填也能跑：脚本会用空默认值，只是本机专属规则不生效。
#
#  编码：本文件含中文，必须存成 **UTF-8 带 BOM**——否则 Windows PowerShell 5.1
#        会按 ANSI 解码，中文全变乱码（脚本报一堆假语法错误即此症状）。
# ============================================================================
@{
    # 改名前的 Windows 用户目录名（没改过 Windows 用户目录名就留空 ''）。
    # 用途：B6 段把"指向已不存在的旧用户目录"的死记录/服务清理掉。
    # 例：OldProfileName = '<旧用户名>'
    OldProfileName = ''

    # A 段「改路径」表：程序本体还在、只是搬了家 → 把注册表里记的旧路径改写成新路径。
    # 判据（脚本内统一遵守）：当前值里确实含 Old 才改写；备份失败则跳过该条。
    #   Path      = 注册表键的 PowerShell 路径（HKCU:\... 或 HKLM:\...）
    #   ValueName = 要改写的值名；空字符串 '' 表示该键的默认值
    #   Old / New = 旧、新路径片段
    #   Why       = 写进日志与统计的说明
    Repoint = @(
        # @{ Path='HKCU:\Software\Classes\Applications\<程序>.exe\shell\open\command'; ValueName=''; Old='D:\旧位置'; New='D:\新位置'; Why='某便携程序已搬走' },
        # @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\<服务名>'; ValueName='ImagePath'; Old='D:\旧位置\x.exe'; New='D:\新位置\x.exe'; Why='某服务的程序已搬走' }
    )
}
