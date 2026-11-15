#Requires -Version 5.1
<#
.SYNOPSIS
    守护 Windows 10 桌面背景处于「幻灯片播放」。

.DESCRIPTION
    采用自管轮播：每次运行从图库目录里挑一张与当前不同的图片设为壁纸，
    由计划任务按间隔重复触发，无常驻进程、无窗口。

    若检测到系统原生幻灯片已经生效（BackgroundType=2），则不接管，直接退出。

    系统原生幻灯片无法由脚本可靠启用：写入注册表后 explorer 不会重绘，
    重启 explorer 时它会把 BackgroundType 校验回 0。该结论见 docs\adr\0001。

.PARAMETER Status
    只读报告：背景类型、当前壁纸、图库、上次轮换、计划任务状态。

.PARAMETER Check
    只检测不修复。轮播正常（系统幻灯片生效，或上次轮换在两个间隔以内）退出码 0，否则 1。

.PARAMETER Apply
    立即轮换一次，跳过启动延迟。

.PARAMETER Config
    指定配置文件路径，覆盖默认位置。

.PARAMETER NoDelay
    跳过启动延迟。install.ps1 与测试用。

.PARAMETER CaptureSnapshot
    把安装前的背景相关注册表值写入 state\install-snapshot.json，然后退出。

.PARAMETER RestoreSnapshot
    按 state\install-snapshot.json 还原，然后退出。uninstall.ps1 用。

.EXAMPLE
    .\slideshow-guard.ps1 -Status

.EXAMPLE
    .\slideshow-guard.ps1 -Check

.EXAMPLE
    .\slideshow-guard.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Check,
    [switch]$Apply,
    [string]$Config,
    [switch]$NoDelay,
    [switch]$CaptureSnapshot,
    [switch]$RestoreSnapshot
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 常量与路径

$script:AppName      = 'slideshow-guard'
$script:InstallRoot  = Join-Path $env:LOCALAPPDATA $script:AppName
$script:StateDir     = Join-Path $script:InstallRoot 'state'
$script:LogDir       = Join-Path $script:InstallRoot 'logs'
$script:LogPath      = Join-Path $script:LogDir 'guard.log'
$script:LastRunPath  = Join-Path $script:StateDir 'last-run.json'
$script:SnapshotPath = Join-Path $script:StateDir 'install-snapshot.json'
$script:TaskName     = 'slideshow-guard'

$script:WpKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
$script:SlKey   = 'HKCU:\Control Panel\Personalization\Desktop Slideshow'
$script:DeskKey = 'HKCU:\Control Panel\Desktop'

$script:ImageExtensions = @('.jpg', '.jpeg', '.png', '.bmp')
$script:LogMaxBytes = 262144
$script:SuppressLog = [bool]$Status

# ---------------------------------------------------------------- 日志

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Message
    )
    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:SuppressLog) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $script:LogPath) {
            if ((Get-Item -LiteralPath $script:LogPath).Length -ge $script:LogMaxBytes) {
                Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.1') -Force
            }
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::AppendAllText($script:LogPath, $entry + [Environment]::NewLine, $utf8)
    } catch {
        # 日志失败不阻断主流程
    }
    Write-Verbose $entry
}

# ---------------------------------------------------------------- 配置

function Get-GuardConfig {
    param([string]$Path)

    $defaults = [ordered]@{
        sourceFolder        = '%USERPROFILE%\Pictures\Slideshow'
        intervalMinutes     = 30
        wallpaperStyle      = 10
        startupDelaySeconds = 30
        seedFromSystem      = $true
        logMaxBytes         = 262144
    }

    $source = $null
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "配置文件不存在: $Path" }
        $source = $Path
    } elseif (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'config.json')) {
        $source = Join-Path $script:InstallRoot 'config.json'
    }

    $merged = [ordered]@{}
    foreach ($k in $defaults.Keys) { $merged[$k] = $defaults[$k] }

    if ($source) {
        $text = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)
        $json = $text | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) {
            if ($merged.Contains($prop.Name) -and $null -ne $prop.Value) {
                $merged[$prop.Name] = $prop.Value
            }
        }
    }

    $merged['sourceFolder'] = [Environment]::ExpandEnvironmentVariables([string]$merged['sourceFolder'])
    $cfg = [pscustomobject]$merged
    $cfg | Add-Member -NotePropertyName ConfigSource -NotePropertyValue $source -Force
    return $cfg
}

# ---------------------------------------------------------------- 注册表读取

function Get-RegValue {
    param([string]$KeyPath, [string]$Name)
    $item = Get-ItemProperty -LiteralPath $KeyPath -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $prop = $item.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-BackgroundTypeName {
    param($Value)
    if ($null -eq $Value) { return '未设置' }
    switch ([int]$Value) {
        0 { '图片' }
        1 { '纯色' }
        2 { '幻灯片' }
        3 { 'Windows 聚焦' }
        default { "未知($Value)" }
    }
}

function Get-BackgroundState {
    $type    = Get-RegValue -KeyPath $script:WpKey -Name 'BackgroundType'
    $library = Get-RegValue -KeyPath $script:WpKey -Name 'SlideshowDirectoryPath1'
    $current = Get-RegValue -KeyPath $script:DeskKey -Name 'Wallpaper'

    $isSystemSlideshow = ($null -ne $type) -and ([int]$type -eq 2) -and
        (-not [string]::IsNullOrWhiteSpace([string]$library))

    [pscustomobject]@{
        BackgroundType    = $type
        CurrentWallpaper  = $current
        IsSystemSlideshow = $isSystemSlideshow
    }
}

# ---------------------------------------------------------------- 壁纸接口

function Set-DesktopWallpaper {
    param([string]$Path)

    if (-not ('SlideshowGuard.Wallpaper' -as [type])) {
        $code = @'
using System;
using System.Runtime.InteropServices;

namespace SlideshowGuard
{
    public static class Wallpaper
    {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

        private const int SPI_SETDESKWALLPAPER = 20;
        private const int SPIF_UPDATEINIFILE = 0x01;
        private const int SPIF_SENDWININICHANGE = 0x02;

        public static bool Apply(string path)
        {
            int flags = SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE;
            return SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, path, flags) != 0;
        }
    }
}
'@
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
    }

    return [SlideshowGuard.Wallpaper]::Apply($Path)
}

# ---------------------------------------------------------------- 图库

function Get-LibraryImages {
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
        Where-Object { $script:ImageExtensions -contains $_.Extension.ToLower() })
}

function Invoke-SeedLibrary {
    param([string]$Target)

    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    $existing = Get-LibraryImages -Folder $Target
    if ($existing.Count -gt 0) { return $existing.Count }

    $sources = @(
        (Join-Path $env:SystemRoot 'Web\Wallpaper\Theme1'),
        (Join-Path $env:SystemRoot 'Web\Wallpaper\Theme2'),
        (Join-Path $env:SystemRoot 'Web\Wallpaper\Windows'),
        (Join-Path $env:SystemRoot 'Web\Wallpaper\Spotlight')
    )

    $copied = 0
    foreach ($src in $sources) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue) {
            if ($script:ImageExtensions -notcontains $file.Extension.ToLower()) { continue }
            $dest = Join-Path $Target $file.Name
            if (Test-Path -LiteralPath $dest) { continue }
            try {
                Copy-Item -LiteralPath $file.FullName -Destination $dest -ErrorAction Stop
                $copied++
            } catch {
                Write-Log 'WARN' ("播种失败: {0} -> {1}" -f $file.Name, $_.Exception.Message)
            }
        }
    }

    Write-Log 'INFO' ("已播种图库 {0}，新增 {1} 张" -f $Target, $copied)
    return $copied
}

function Select-NextWallpaper {
    param([string]$Folder, [string]$Current)

    $images = Get-LibraryImages -Folder $Folder
    if ($images.Count -eq 0) { return $null }
    if ($images.Count -eq 1) { return $images[0].FullName }

    $candidates = @($images | Where-Object {
        -not [string]::Equals($_.FullName, $Current, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($candidates.Count -eq 0) { $candidates = $images }

    return ($candidates | Get-Random).FullName
}

# ---------------------------------------------------------------- 视觉侧效应比对

$script:SnapshotSections = @(
    'Control Panel\Colors',
    'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
)

$script:SnapshotValues = @{
    'Control Panel\Colors' = @('Background')
    'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' = @(
        'SystemUsesLightTheme', 'AppsUseLightTheme', 'EnableTransparency', 'ColorPrevalence'
    )
}

function Get-RegistrySnapshot {
    $snapshot = [ordered]@{}
    foreach ($section in $script:SnapshotSections) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($section, $false)
        if ($null -eq $key) { continue }
        try {
            $values = [ordered]@{}
            $names = @($key.GetValueNames())
            foreach ($name in $script:SnapshotValues[$section]) {
                if ($names -notcontains $name) { continue }
                $values[$name] = [ordered]@{
                    kind  = [string]$key.GetValueKind($name)
                    value = [string]$key.GetValue($name)
                }
            }
            $snapshot[$section] = $values
        } finally {
            $key.Close()
        }
    }
    return $snapshot
}

function Test-CollateralChange {
    param($Before)
    $after = Get-RegistrySnapshot
    $changed = @()
    foreach ($section in $script:SnapshotSections) {
        if (-not $Before.Contains($section)) { continue }
        if (-not $after.Contains($section)) { $changed += $section; continue }
        foreach ($name in $Before[$section].Keys) {
            if (-not $after[$section].Contains($name)) { $changed += ('{0}\{1}' -f $section, $name); continue }
            $b = $Before[$section][$name]
            $a = $after[$section][$name]
            if ($b.kind -ne $a.kind -or $b.value -ne $a.value) {
                $changed += ('{0}\{1}' -f $section, $name)
            }
        }
    }
    return $changed
}

function Restore-RegistrySnapshot {
    param($Snapshot)
    foreach ($section in $Snapshot.Keys) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($section, $true)
        if ($null -eq $key) { continue }
        try {
            foreach ($name in $Snapshot[$section].Keys) {
                $entry = $Snapshot[$section][$name]
                switch ($entry.kind) {
                    'DWord' { $key.SetValue($name, [int]$entry.value, [Microsoft.Win32.RegistryValueKind]::DWord) }
                    'String' { $key.SetValue($name, [string]$entry.value, [Microsoft.Win32.RegistryValueKind]::String) }
                    default { $key.SetValue($name, [string]$entry.value) }
                }
            }
        } finally {
            $key.Close()
        }
    }
}

# ---------------------------------------------------------------- 安装快照

$script:BackgroundSnapshotKeys = @(
    @{
        Path  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
        Names = @('BackgroundType', 'SlideshowDirectoryPath1', 'SlideshowSourceDirectoriesSet')
    },
    @{
        Path  = 'Control Panel\Personalization\Desktop Slideshow'
        Names = @('Interval', 'Shuffle', 'LastTickHigh', 'LastTickLow')
    },
    @{
        Path  = 'Control Panel\Desktop'
        Names = @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')
    }
)

function Save-BackgroundSnapshot {
    param([string]$Path)

    $data = @{
        capturedAt = (Get-Date).ToString('o')
        user       = $env:USERNAME
        computer   = $env:COMPUTERNAME
        keys       = @{}
    }

    foreach ($spec in $script:BackgroundSnapshotKeys) {
        $entry = @{}
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($spec.Path, $false)
        try {
            $names = @()
            if ($null -ne $key) { $names = @($key.GetValueNames()) }
            foreach ($name in $spec.Names) {
                if ($names -contains $name) {
                    $entry[$name] = @{
                        kind  = [string]$key.GetValueKind($name)
                        value = [string]$key.GetValue($name)
                    }
                } else {
                    $entry[$name] = @{ kind = 'NotExist'; value = $null }
                }
            }
        } finally {
            if ($null -ne $key) { $key.Close() }
        }
        $data['keys'][$spec.Path] = $entry
    }

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ($data | ConvertTo-Json -Depth 8), $utf8)
    Write-Verbose "已写入安装快照: $Path"
}

function Restore-BackgroundSnapshot {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "安装快照不存在: $Path" }
    $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json

    foreach ($spec in $script:BackgroundSnapshotKeys) {
        $holder = $json.keys.PSObject.Properties[$spec.Path]
        if ($null -eq $holder) { continue }
        $entry = $holder.Value

        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($spec.Path, $true)
        if ($null -eq $key) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($spec.Path)
        }
        if ($null -eq $key) { continue }

        try {
            foreach ($name in $spec.Names) {
                $valueHolder = $entry.PSObject.Properties[$name]
                if ($null -eq $valueHolder) { continue }
                $record = $valueHolder.Value

                if ($record.kind -eq 'NotExist') {
                    try { $key.DeleteValue($name, $false) } catch { }
                    continue
                }

                $kind = [Microsoft.Win32.RegistryValueKind]$record.kind
                switch ([string]$record.kind) {
                    'DWord' { $value = [int]$record.value }
                    'QWord' { $value = [long]$record.value }
                    default { $value = [string]$record.value }
                }
                $key.SetValue($name, $value, $kind)
            }
        } finally {
            $key.Close()
        }
    }

    $rundll = Join-Path $env:SystemRoot 'System32\rundll32.exe'
    try {
        Start-Process -FilePath $rundll -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -WindowStyle Hidden -Wait
    } catch { }
    Write-Verbose "已按安装快照还原: $Path"
}

# ---------------------------------------------------------------- 上次运行记录

function Save-LastRun {
    param([string]$Image, [string]$Method)
    try {
        if (-not (Test-Path -LiteralPath $script:StateDir)) {
            New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        }
        $record = @{
            at     = (Get-Date).ToString('o')
            image  = $Image
            method = $Method
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($script:LastRunPath, ($record | ConvertTo-Json), $utf8)
    } catch { }
}

function Read-LastRun {
    if (-not (Test-Path -LiteralPath $script:LastRunPath)) { return $null }
    try {
        return ([IO.File]::ReadAllText($script:LastRunPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------- 轮换

function Invoke-Rotate {
    param($Config)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $library = [string]$Config.sourceFolder

    try {
        $count = Invoke-SeedLibrary -Target $library
        if ($count -le 0) {
            return [pscustomobject]@{
                Success = $false; ElapsedMs = $watch.ElapsedMilliseconds
                Detail = "图库目录没有可用图片: $library"
            }
        }

        $before = Get-RegistrySnapshot
        $current = [string](Get-RegValue -KeyPath $script:DeskKey -Name 'Wallpaper')
        $next = Select-NextWallpaper -Folder $library -Current $current
        if (-not $next) {
            return [pscustomobject]@{
                Success = $false; ElapsedMs = $watch.ElapsedMilliseconds
                Detail = '未能从图库选出一张图片'
            }
        }

        Set-ItemProperty -LiteralPath $script:DeskKey -Name 'WallpaperStyle' -Value ([string]$Config.wallpaperStyle) -Type String
        Set-ItemProperty -LiteralPath $script:DeskKey -Name 'TileWallpaper' -Value '0' -Type String

        if (-not (Set-DesktopWallpaper -Path $next)) {
            return [pscustomobject]@{
                Success = $false; ElapsedMs = $watch.ElapsedMilliseconds
                Detail = 'SystemParametersInfo 返回失败'
            }
        }

        Start-Sleep -Milliseconds 800
        $applied = [string](Get-RegValue -KeyPath $script:DeskKey -Name 'Wallpaper')
        if (-not [string]::Equals($applied, $next, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Success = $false; ElapsedMs = $watch.ElapsedMilliseconds
                Detail = ('壁纸未生效，注册表仍是 ' + $applied)
            }
        }

        $collateral = @(Test-CollateralChange -Before $before)
        if ($collateral.Count -gt 0) {
            Restore-RegistrySnapshot -Snapshot $before
            Write-Log 'ERROR' ('轮换改动了无关项，已还原: {0}' -f ($collateral -join ', '))
            return [pscustomobject]@{
                Success = $false; ElapsedMs = $watch.ElapsedMilliseconds
                Detail = '轮换改动了无关的视觉设置，已还原'
            }
        }

        Save-LastRun -Image $next -Method 'spi'
        return [pscustomobject]@{
            Success = $true; ElapsedMs = $watch.ElapsedMilliseconds
            Detail = ('已切换到 {0}，图库 {1} 张' -f (Split-Path -Leaf $next), $count)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false; ElapsedMs = $watch.ElapsedMilliseconds
            Detail = $_.Exception.Message
        }
    } finally {
        $watch.Stop()
    }
}

# ---------------------------------------------------------------- 状态报告

function ConvertTo-AgeText {
    param($TimeSpan)
    if ($null -eq $TimeSpan) { return '未知' }
    if ($TimeSpan.TotalMinutes -lt 1) { return '不到 1 分钟前' }
    if ($TimeSpan.TotalHours -lt 1) { return ('{0} 分钟前' -f [int]$TimeSpan.TotalMinutes) }
    if ($TimeSpan.TotalDays -lt 1) { return ('{0} 小时前' -f [math]::Round($TimeSpan.TotalHours, 1)) }
    return ('{0} 天前' -f [math]::Round($TimeSpan.TotalDays, 1))
}

function Show-Status {
    $state = Get-BackgroundState
    $cfg = $null
    try { $cfg = Get-GuardConfig -Path $Config } catch { }

    $libraryPath = $null
    $libraryCount = 0
    if ($cfg) {
        $libraryPath = [string]$cfg.sourceFolder
        $libraryCount = (Get-LibraryImages -Folder $libraryPath).Count
    }

    $taskText = '未注册'
    $lastRunTask = '无记录'
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($task) {
            $taskText = [string]$task.State
            $info = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
            if ($info -and $info.LastRunTime) {
                $result = '成功'
                if ($info.LastTaskResult -ne 0) { $result = '退出码 ' + $info.LastTaskResult }
                $lastRunTask = '{0} ({1})' -f $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss'), $result
            }
        }
    }

    $record = Read-LastRun
    $rotateText = '从未轮换'
    $stale = $true
    if ($record) {
        $when = $null
        try { $when = [datetime]::Parse($record.at) } catch { }
        if ($when) {
            $age = (Get-Date) - $when
            $rotateText = '{0}（{1}）' -f $record.at.Replace('T', ' ').Substring(0, 19), (ConvertTo-AgeText $age)
            if ($cfg) {
                $limit = [int]$cfg.intervalMinutes * 2
                if ($age.TotalMinutes -le $limit) { $stale = $false }
            }
        }
    } else {
        if ($state.IsSystemSlideshow) { $stale = $false }
    }

    $verdict = 'STALE'
    if ($state.IsSystemSlideshow) { $verdict = 'OK (系统幻灯片)' }
    elseif (-not $stale) { $verdict = 'OK (脚本轮播)' }

    Write-Host ''
    Write-Host ('slideshow-guard  {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('  背景类型   : {0} ({1})' -f $state.BackgroundType, (Get-BackgroundTypeName $state.BackgroundType))
    Write-Host ('  当前壁纸   : {0}' -f $state.CurrentWallpaper)
    Write-Host ('  图库目录   : {0} ({1} 张)' -f $libraryPath, $libraryCount)
    Write-Host ('  上次轮换   : {0}' -f $rotateText)
    Write-Host ('  计划任务   : {0} / 最近运行 {1}' -f $taskText, $lastRunTask)
    Write-Host ('  结论       : {0}' -f $verdict)
    Write-Host ''
}

# ---------------------------------------------------------------- 主流程

try {
    [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
} catch { }

$cfg = Get-GuardConfig -Path $Config
$script:LogMaxBytes = [int]$cfg.logMaxBytes

if ($Status) {
    Show-Status
    exit 0
}

if ($CaptureSnapshot) {
    Save-BackgroundSnapshot -Path $script:SnapshotPath
    Write-Host "已写入安装快照: $script:SnapshotPath"
    exit 0
}

if ($RestoreSnapshot) {
    Restore-BackgroundSnapshot -Path $script:SnapshotPath
    Write-Host "已按安装快照还原: $script:SnapshotPath"
    exit 0
}

if (-not $Check -and -not $Apply -and -not $NoDelay) {
    $delay = [int]$cfg.startupDelaySeconds
    if ($delay -gt 0) {
        Write-Verbose "启动延迟 $delay 秒"
        Start-Sleep -Seconds $delay
    }
}

$state = Get-BackgroundState

if ($Check) {
    if ($state.IsSystemSlideshow) { exit 0 }

    $record = Read-LastRun
    if ($record) {
        try {
            $when = [datetime]::Parse($record.at)
            $limit = [int]$cfg.intervalMinutes * 2
            if (((Get-Date) - $when).TotalMinutes -le $limit) { exit 0 }
        } catch { }
    }

    exit 1
}

if (-not $Apply -and $state.IsSystemSlideshow) {
    Write-Log 'INFO' '跳过：系统幻灯片已生效，不接管'
    exit 0
}

$result = Invoke-Rotate -Config $cfg

if ($result.Success) {
    Write-Log 'INFO' ('完成：耗时 {0}ms，{1}' -f $result.ElapsedMs, $result.Detail)
    exit 0
}

Write-Log 'ERROR' ('失败：耗时 {0}ms，{1}' -f $result.ElapsedMs, $result.Detail)
exit 1
