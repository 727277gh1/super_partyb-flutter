#!/usr/bin/env pwsh
<#
.SYNOPSIS
    把 Flutter Windows 的 Release 产物打成 Inno Setup 安装包（.exe）。

.DESCRIPTION
    输入：`apps/spb_desktop/build/windows/x64/runner/Release`（已含 VC++ 运行库）。
    输出：`build/windows-installer/spb_desktop-windows-x64-setup.exe`。

    安装包脚本是 `apps/spb_desktop/windows/installer/spb_desktop.iss`；本脚本只负责
    「找到 ISCC、算出版本号、把路径用 /D 传进去、验证产物存在」。

.PARAMETER BundleDir
    要打包的目录。默认 `apps/spb_desktop/build/windows/x64/runner/Release`。

.PARAMETER Version
    写进安装包的版本号（`x.y.z`）。默认依次取 `$env:GITHUB_REF_NAME`（tag 推送上
    是 `v1.2.3`）、`apps/spb_desktop/pubspec.yaml` 的 `version:`，最后退回 `0.0.0`。
    非数字部分会被丢掉——Inno 的 `AppVersion` 必须是数字，否则它无法判断「谁更新」，
    升级安装的版本比较会失效。

.PARAMETER OutDir
    产物目录。默认 `<repo>/build/windows-installer`（`build/` 已被 .gitignore 忽略）。

.PARAMETER IssFile
    安装包脚本路径。默认 `apps/spb_desktop/windows/installer/spb_desktop.iss`。

.NOTES
    ## 为什么单独一个脚本，而不是把这几步写在 workflow 里

    `ci.yml` 的 `build-windows` 与 `release.yml` 的 `windows` 是**两个 job**，它们
    的构建步骤本就是同一份逻辑的两份拷贝（Flutter 构建 + 拷 VC++ 运行库已经重复
    了）。安装包这一步再抄一遍，就有三处「版本号怎么算」「ISCC 在哪」需要同步。
    放进脚本后两边各只有一行调用。

    ## 为什么缺 VC++ 运行库要**报错**而不是警告

    缺了它，装出来的客户端在目标机上**双击即闪退**（AGENTS.md §8 坑 1），而那种
    反馈对用户来说等于「装了个坏的」。宁可在这里红，也不要发一个必然闪退的包。

    ## 为什么找不到 ISCC 时先试 choco

    GitHub 的 windows runner 预装 Inno Setup（6.x），但那是**镜像属性**，不是我们
    能控制的（AGENTS.md §6.30 的教训：镜像会漂）。故先按 PATH 与常见安装目录探测，
    都找不到才 `choco install innosetup`，仍找不到则给出可执行的提示而不是一句
    「命令不存在」。
#>
[CmdletBinding()]
param(
    [string] $BundleDir = '',
    [string] $Version = '',
    [string] $OutDir = '',
    [string] $IssFile = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $BundleDir) {
    $BundleDir = Join-Path $repoRoot 'apps/spb_desktop/build/windows/x64/runner/Release'
}
if (-not $OutDir) {
    $OutDir = Join-Path $repoRoot 'build/windows-installer'
}
if (-not $IssFile) {
    $IssFile = Join-Path $repoRoot 'apps/spb_desktop/windows/installer/spb_desktop.iss'
}

# ── 1. 校验输入 ────────────────────────────────────────────────────────
if (-not (Test-Path $BundleDir)) {
    throw "找不到要打包的目录：$BundleDir（先跑 flutter build windows --release）"
}
$bundle = (Resolve-Path $BundleDir).Path
if (-not (Test-Path $IssFile)) {
    throw "找不到安装包脚本：$IssFile"
}
$iss = (Resolve-Path $IssFile).Path

# 缺任何一个都不该出包：exe/flutter_windows.dll 缺了是空包，
# VC++ 三件套缺了是「装完闪退」（AGENTS.md §8 坑 1）。
$required = @(
    'spb_desktop.exe',
    'flutter_windows.dll',
    'msvcp140.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll'
)
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $bundle $_)) })
if ($missing.Count -gt 0) {
    $msg = "打包目录缺：$($missing -join ', ')"
    $msg += "`n  VC++ 运行库由 workflow 的「Bundle VC++ runtime」步骤拷入，本地手跑见 docs/windows-release.md §2"
    throw $msg
}

# ── 2. 版本号 ──────────────────────────────────────────────────────────
# 只保留前导的数字段：`v1.2.3` / `1.2.3-rc1` / `1.2.3+4` 都归一成 `1.2.3`。
# 归一化失败（例如分支名 `main`）就继续往下退，最后是 `0.0.0`。
function Resolve-NumericVersion {
    param([string] $Raw)
    if (-not $Raw) { return $null }
    if ($Raw -match '^[vV]?(\d+(?:\.\d+){0,2})') { return $Matches[1] }
    return $null
}

$appVersion = Resolve-NumericVersion -Raw $Version
$versionSource = 'param -Version'
if (-not $appVersion) {
    $appVersion = Resolve-NumericVersion -Raw $env:GITHUB_REF_NAME
    $versionSource = 'GITHUB_REF_NAME'
}
if (-not $appVersion) {
    $pubspec = Join-Path $repoRoot 'apps/spb_desktop/pubspec.yaml'
    if (Test-Path $pubspec) {
        $line = Select-String -Path $pubspec -Pattern '^version:\s*(\S+)' | Select-Object -First 1
        if ($line) {
            $appVersion = Resolve-NumericVersion -Raw $line.Matches[0].Groups[1].Value
            $versionSource = 'pubspec.yaml'
        }
    }
}
if (-not $appVersion) {
    $appVersion = '0.0.0'
    $versionSource = 'fallback'
}

# ── 3. 找 ISCC ─────────────────────────────────────────────────────────
# ⚠️ 不能「取 PATH 上第一个」。装了 Chocolatey 的机器（GitHub 的 windows runner
# 就是）PATH 上会有一个 `C:\ProgramData\Chocolatey\bin\ISCC.exe` **shim**——它是
# shimgen 生成的转发器，`VersionInfo.FileVersion` 是 `0.0.0.0`，于是「需要 6.0+」
# 的检查会把它判死，而真正的编译器就在 Program Files 下好好躺着。
# 2026-11 CI 实测：这一步红在 `需要 Inno Setup 6.0+，当前 0.0.0.0（...\Chocolatey\bin\ISCC.exe）`。
# 故收集**全部**候选、按版本号挑最高的那个（未知版本 0 排最后）。
function Get-IsccCandidates {
    $list = @()
    $cmd = @(Get-Command ISCC.exe -All -ErrorAction SilentlyContinue)
    foreach ($c in $cmd) {
        if ($c -and $c.Source) { $list += $c.Source }
    }

    $bases = @()
    if (${env:ProgramFiles(x86)}) { $bases += ${env:ProgramFiles(x86)} }
    if ($env:ProgramFiles) { $bases += $env:ProgramFiles }
    if ($env:LOCALAPPDATA) { $bases += (Join-Path $env:LOCALAPPDATA 'Programs') }
    foreach ($base in $bases) {
        foreach ($dir in @('Inno Setup 6', 'Inno Setup 5')) {
            $list += (Join-Path $base "$dir/ISCC.exe")
        }
    }
    return $list
}

function Find-Iscc {
    $seen = @{}
    $best = $null
    $bestMajor = -1
    $report = @()
    foreach ($c in (Get-IsccCandidates)) {
        if (-not $c) { continue }
        if (-not (Test-Path $c)) { continue }
        $path = (Resolve-Path $c).Path
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $vi = (Get-Item $path).VersionInfo
        $major = 0
        if ($vi.FileMajorPart) { $major = [int]$vi.FileMajorPart }
        $report += "$path (v$($vi.FileVersion))"
        if ($major -gt $bestMajor) {
            $bestMajor = $major
            $best = $path
        }
    }
    if ($report.Count -gt 0) { Write-Host ('ISCC 候选：' + ($report -join '; ')) }
    return $best
}

$iscc = Find-Iscc
if (-not $iscc) {
    Write-Host '未找到 ISCC.exe，尝试 choco install innosetup ...'
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        choco install innosetup --no-progress -y | Write-Host
        $iscc = Find-Iscc
    }
}
if (-not $iscc) {
    throw ('找不到 ISCC.exe（Inno Setup 编译器）。安装后重试：' +
        'https://jrsoftware.org/isdl.php 或 choco install innosetup')
}

# 脚本用了 {autopf} / WizardStyle / 内置 ISPP，都是 Inno 6.0+ 的语法；
# 5.x 上会得到一堆「未知参数」的报错，提前拦住更好定位。
# 版本号读不出来（0，通常是 shim）时**不**硬拦：那种情况读不到 ≠ 版本太旧，
# 交给 ISCC 自己报错比在这里瞎猜好——shim 会把参数转发给真正的编译器。
$isccVersion = (Get-Item $iscc).VersionInfo
$isccMajor = 0
if ($isccVersion.FileMajorPart) { $isccMajor = [int]$isccVersion.FileMajorPart }
if ($isccMajor -gt 0 -and $isccMajor -lt 6) {
    throw "需要 Inno Setup 6.0+，当前 $($isccVersion.FileVersion)（$iscc）"
}
if ($isccMajor -eq 0) {
    Write-Warning "读不出 $iscc 的版本号（可能是 shim），直接尝试编译"
}

# ── 4. 跑 ISCC ─────────────────────────────────────────────────────────
$outFull = $OutDir
if (-not (Test-Path $outFull)) {
    New-Item -ItemType Directory -Path $outFull -Force | Out-Null
}
$outFull = (Resolve-Path $outFull).Path

$icon = Join-Path (Split-Path -Parent $iss) 'setup_icon.ico'

# 每个 /D 都作为**单个 argv** 传入（含空格也安全）：写成一行拼接的命令字符串
# 会在路径带空格时被 PowerShell 拆成两个参数，而 ISCC 只认 `/DKey=Value`。
$isccArgs = @(
    "/DAppVersion=$appVersion"
    "/DBundleDir=$bundle"
    "/DOutputDir=$outFull"
)
if (Test-Path $icon) {
    $isccArgs += "/DSetupIconFile=$icon"
} else {
    # 图标缺失不该阻断出包：安装包会用 Inno 的默认图标。
    Write-Warning "未找到 $icon，安装包将使用默认图标（重跑 tools/gen_brand_assets.py 可生成）"
}
$isccArgs += $iss

Write-Host "ISCC      : $iscc ($($isccVersion.FileVersion))"
Write-Host "版本      : $appVersion（来源：$versionSource）"
Write-Host "打包目录  : $bundle"
Write-Host "输出目录  : $outFull"
Write-Host '开始编译安装包（lzma2/max + 固实压缩，通常 1-3 分钟）...'

& $iscc @isccArgs
if ($LASTEXITCODE -ne 0) {
    throw "ISCC 失败，退出码 $LASTEXITCODE"
}

# ── 5. 验证产物 ────────────────────────────────────────────────────────
# 不只看退出码：ISCC 成功但没产出文件的情况（OutputDir 写错、被安全软件拦下）
# 在 CI 上表现为「upload-artifact 传了个空」，而那是 v4+ 的 warn 而非 fail
# （AGENTS.md §6.33 同一类「绿不代表对」）。
$setup = Join-Path $outFull 'spb_desktop-windows-x64-setup.exe'
if (-not (Test-Path $setup)) {
    throw "ISCC 报告成功，但未找到产物：$setup"
}
$sizeMb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
if ((Get-Item $setup).Length -lt 1MB) {
    throw "产物只有 $sizeMb MB，明显不完整（打包目录选错了？）"
}

$bundleMb = [math]::Round((Get-ChildItem $bundle -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host ''
Write-Host "✅ 安装包：$setup"
Write-Host "   版本 $appVersion · 安装包 $sizeMb MB（原始 $bundleMb MB）"

# 供 workflow 后续 step 取路径（没有 GITHUB_OUTPUT 时静默跳过，本地手跑无影响）。
if ($env:GITHUB_OUTPUT) {
    "installer=$setup" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
