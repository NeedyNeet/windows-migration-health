# ============================================================================
#  tests/repair.discover-targets.tests.ps1 —— -DiscoverTargets 的判定与草稿
#
#  这个模式要解决的是"新机器面对空白映射表只能人肉考古"。它由几段**纯逻辑**构成，
#  每段都能单独真跑（本套件就是跑它们，而不是跑整个模式 —— 那种要扫全盘）：
#    · Get-PathToken        ：从"带参数的命令行 / 图标索引"里取出路径本身
#    · Get-OldPathPrefix    ：把"指向已消失目标的路径"归约成"最长的、已不存在的目录前缀"
#    · Test-AppSegment      ：这一段能不能当应用名用（通用名不猜）
#    · Get-RepointKey       ：去磁盘上按"末段"还是"两级"找
#    · Get-CandidateEvidence：新位置的置信度（有名字含应用名的 .exe → 高）
#    · Find-WantedDirs      ：一趟遍历配齐所有想要的目录名（含 tail 索引、深度、噪声目录）
#    · New-RepointDraft     ：草稿文本必须是**合法 psd1**、高置信启用、其余注释掉
# ============================================================================
. "$PSScriptRoot\lib\TestKit.ps1"
. "$PSScriptRoot\lib\Extract-Function.ps1"

$repo   = Get-RepoRoot
$target = Join-Path $repo 'scripts\repair-migrated-apps.ps1'

foreach ($fn in 'Test-Exists', 'Get-PathToken', 'Get-OldPathPrefix', 'Test-AppSegment',
                'Get-RepointKey', 'Get-CandidateEvidence', 'Find-WantedDirs', 'New-RepointDraft') {
    Invoke-Expression (Get-ScriptFunctionText -Path $target -Name $fn)
}
$script:GenericSegments = @('x86', 'x64', 'bin', 'app', 'apps', 'java', 'resource', 'resources', 'plugins', 'data', 'lib')

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wmh-disc-' + [guid]::NewGuid().ToString('N').Substring(0,6))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force

try {
    Test-Case 'Get-PathToken：引号 / 图标索引 / 带参数的命令行都只取路径本身' {
        Assert-Equal (Get-PathToken '"C:\a b\app.exe" /uninstall') 'C:\a b\app.exe' '带引号 + 参数'
        Assert-Equal (Get-PathToken 'C:\a\app.exe,0') 'C:\a\app.exe' '图标索引'
        Assert-Equal (Get-PathToken 'C:\Program Files\a.exe -flag') 'C:\Program Files\a.exe' '带参数（无引号）'
        Assert-Equal (Get-PathToken 'C:\Program Files\Some Dir') 'C:\Program Files\Some Dir' '纯目录（含空格，不该被截断）'
    }

    Test-Case 'Get-OldPathPrefix：归约到"最长的、已不存在的目录前缀"' {
        # 造一个真实的"消失"场景：$tmpRoot 存在，$tmpRoot\gone 不存在
        $gone = Join-Path $tmpRoot 'gone'
        Assert-Equal (Get-OldPathPrefix (Join-Path $gone 'app.exe')) $gone '文件消失 → 归约到它所在的目录'
        Assert-Equal (Get-OldPathPrefix $gone) $gone '目录本身消失 → 就是它'
        Assert-True ($null -eq (Get-OldPathPrefix $tmpRoot)) '存在的目录不该被当候选'
        Assert-True ($null -eq (Get-OldPathPrefix 'relative\path')) '相对路径不算'
        Assert-True ($null -eq (Get-OldPathPrefix '%ProgramFiles%\X\y.exe')) '未展开的环境变量不算'
        Assert-True ($null -eq (Get-OldPathPrefix 'C:\Windows\<占位符>\x.exe')) '含占位符的不算'
        Assert-True ($null -eq (Get-OldPathPrefix 'C:\ProgramData\Package Cache\{ABC}\gone.exe')) 'MSI 安装缓存不算（它的"不存在"是正常的）'
        Assert-True ($null -eq (Get-OldPathPrefix '')) '空值不算'
    }

    Test-Case 'Test-AppSegment：通用名 / 太短 / 无字母都不当应用名' {
        Assert-True (Test-AppSegment 'quark-cloud-drive') '正常应用名要认'
        Assert-True (Test-AppSegment 'NetEase') '正常应用名要认'
        Assert-True (-not (Test-AppSegment 'x86')) '黑名单里的不算'
        Assert-True (-not (Test-AppSegment 'bin')) '黑名单里的不算'
        Assert-True (-not (Test-AppSegment 'v2')) '太短不算'
        Assert-True (-not (Test-AppSegment '123')) '没有字母不算'
        Assert-True (-not (Test-AppSegment '')) '空的不算'
    }

    Test-Case 'Get-RepointKey：末段是应用名 → leaf；末段通用 → 退一级按两级找；两段都通用 → 放弃' {
        $k1 = Get-RepointKey 'C:\Program Files (x86)\quark-cloud-drive'
        Assert-Equal $k1.Mode 'leaf' '末段是应用名'
        Assert-Equal $k1.Key 'quark-cloud-drive' '键就是末段'
        $k2 = Get-RepointKey 'C:\Program Files\ldplayer9box\x86'
        Assert-Equal $k2.Mode 'tail' '末段是通用名 → 按两级'
        Assert-Equal $k2.Key 'ldplayer9box\x86' '键是"上一段\末段"'
        Assert-Equal $k2.App 'ldplayer9box' '应用名取上一段'
        Assert-True ($null -eq (Get-RepointKey 'D:\x86\bin')) '两段都通用 → 放弃（不猜）'
    }

    Test-Case 'Find-WantedDirs：leaf 与 tail 两种索引都能命中，且尊重 MaxDepth 与噪声目录' {
        $root = Join-Path $tmpRoot 'scan'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'Apps\quark-cloud-drive') -Force          # leaf 命中（深度 2）
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'Games\ldplayer9box\x86') -Force          # tail 命中（深度 3）
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'deep\a\b\c\quark-cloud-drive') -Force    # 太深（深度 5）
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'node_modules\quark-cloud-drive') -Force  # 噪声目录下
        $r = Find-WantedDirs -Roots @($root) -MaxDepth 4 -LeafNames @('quark-cloud-drive') -TailNames @('ldplayer9box\x86')
        $leafHits = @($r.Leaf['quark-cloud-drive'])
        Assert-Equal $leafHits.Count 1 ("leaf 只应命中 1 处（深层与噪声目录都要排除），实际 {0}：{1}" -f $leafHits.Count, ($leafHits -join ' | '))
        Assert-Match $leafHits[0] 'Apps\\quark-cloud-drive$' '命中的应当是浅层那个'
        $tailHits = @($r.Tail['ldplayer9box\x86'])
        Assert-Equal $tailHits.Count 1 ("tail 应当命中 1 处，实际 {0}" -f $tailHits.Count)
        Assert-Match $tailHits[0] 'ldplayer9box\\x86$' 'tail 命中的是那个子目录本身（保留 \x86 这一级）'
        Assert-True ($r.Scanned -ge 5) ("遍历计数应当被记下来，实际 {0}" -f $r.Scanned)
    }

    Test-Case 'Get-CandidateEvidence：有名字含应用名的 .exe → high；只有别的 exe → medium；没有 → low' {
        $d1 = Join-Path $tmpRoot 'ev-high';   $null = New-Item -ItemType Directory -Path $d1 -Force
        Set-Content -LiteralPath (Join-Path $d1 'QuarkCloudDrive.exe') -Value 'x'
        Assert-Equal (Get-CandidateEvidence -OldPrefix 'C:\x\quark-cloud-drive' -Candidate $d1 -App 'quark-cloud-drive').Confidence 'high' '名字含应用名 → high'
        $d2 = Join-Path $tmpRoot 'ev-medium'; $null = New-Item -ItemType Directory -Path $d2 -Force
        Set-Content -LiteralPath (Join-Path $d2 'other.exe') -Value 'x'
        Assert-Equal (Get-CandidateEvidence -OldPrefix 'C:\x\quark-cloud-drive' -Candidate $d2 -App 'quark-cloud-drive').Confidence 'medium' '只有别的 exe → medium'
        $d3 = Join-Path $tmpRoot 'ev-low';    $null = New-Item -ItemType Directory -Path $d3 -Force
        Set-Content -LiteralPath (Join-Path $d3 'readme.txt') -Value 'x'
        Assert-Equal (Get-CandidateEvidence -OldPrefix 'C:\x\quark-cloud-drive' -Candidate $d3 -App 'quark-cloud-drive').Confidence 'low' '没有 exe → low'
        # tail 模式要连上一级一起看（.exe 通常在应用目录本身，而不是那个子目录里）
        $d4 = Join-Path $tmpRoot 'ev-tail\ldplayer9box'; $null = New-Item -ItemType Directory -Path (Join-Path $d4 'x86') -Force
        Set-Content -LiteralPath (Join-Path $d4 'ldplayer9box.exe') -Value 'x'
        Assert-Equal (Get-CandidateEvidence -OldPrefix 'C:\x\ldplayer9box\x86' -Candidate (Join-Path $d4 'x86') -App 'ldplayer9box' -CheckParent).Confidence 'high' 'tail 模式要看上一级'
    }

    Test-Case 'New-RepointDraft：只有高置信生成条目、提示只列目录、未命中列出，且整体是**合法 psd1**' {
        $hi = @([pscustomobject]@{ Old = 'C:\a\quark-cloud-drive'; New = 'D:\Apps\quark-cloud-drive'; Refs = 9; Confidence = 'high'; Why = 'x' })
        $hints = @([pscustomobject]@{ Old = 'C:\a\Tencent'; Refs = 25; Tips = @('C:\ProgramData\Tencent', 'D:\Program Files (x86)\Tencent') })
        $un = @([pscustomobject]@{ Old = 'C:\a\bar'; Refs = 1 })
        $draft = New-RepointDraft -High $hi -Hints $hints -Unmatched $un
        Assert-True ($draft -is [string]) ("草稿应当是字符串，实际 {0}" -f $draft.GetType().Name)
        $f = Join-Path $tmpRoot 'draft.psd1'
        [IO.File]::WriteAllText($f, $draft, (New-Object Text.UTF8Encoding($true)))
        $parsed = Import-PowerShellDataFile -LiteralPath $f        # 解析不了会抛 → 测试失败（尾逗号就是这样被抓出来的）
        Assert-Equal @($parsed.PathMap).Count 1 '只有高置信那条应当被启用'
        Assert-Equal @($parsed.PathMap)[0].Old 'C:\a\quark-cloud-drive' '启用的是高置信那条'
        Assert-Match $draft 'C:\\ProgramData\\Tencent' '提示区要列出同名目录供人判断'
        Assert-NotMatch $draft "Old = 'C:\\a\\Tencent'" '提示区的旧前缀**不能**被写成条目（不替你猜 Old→New）'
        Assert-Match $draft 'C:\\a\\bar' '没找到候选的旧前缀也要列出来'
    }

    Test-Case 'New-RepointDraft：**多条**条目时逗号位置正确（尾逗号 / 逗号掉进注释都会毁掉整个文件）' {
        # 这条是补出来的：上面那个用例只放 1 条，抓不到"逗号被追加到行尾注释后面"这个 bug，
        # 而真实草稿里有 3 条 → 文件直接解析失败。教训：草稿的**形状**必须用多条数据测。
        $hi2 = @(
            [pscustomobject]@{ Old = 'C:\a\one';   New = 'D:\Apps\one';   Refs = 1; Confidence = 'high'; Why = 'w1' }
            [pscustomobject]@{ Old = 'C:\a\two';   New = 'D:\Apps\two';   Refs = 2; Confidence = 'high'; Why = 'w2' }
            [pscustomobject]@{ Old = 'C:\a\three'; New = 'D:\Apps\three'; Refs = 3; Confidence = 'high'; Why = 'w3' }
        )
        $draft2 = New-RepointDraft -High $hi2 -Hints @() -Unmatched @()
        $f2 = Join-Path $tmpRoot 'draft2.psd1'
        [IO.File]::WriteAllText($f2, $draft2, (New-Object Text.UTF8Encoding($true)))
        $parsed2 = Import-PowerShellDataFile -LiteralPath $f2
        Assert-Equal @($parsed2.PathMap).Count 3 ("三条条目都要能解析出来，实际 {0}" -f @($parsed2.PathMap).Count)
        Assert-Equal @($parsed2.PathMap)[2].New 'D:\Apps\three' '最后一条也要完整（尾逗号会毁掉它）'
        Assert-NotMatch $draft2 '引用,\s*$' '逗号不能在注释后面（那等于没分隔元素）'
        Assert-NotMatch $draft2 ',\s*\)' '不允许尾逗号'
    }
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-TestRun 'repair.discover-targets'
