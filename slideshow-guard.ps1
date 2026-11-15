#Requires -Version 5.1
<#
.SYNOPSIS
    守护 Windows 10 桌面处于「幻灯片放映」模式并真实轮播。

.DESCRIPTION
    判定健康的三个条件：
      1. HKCU\...\Explorer\Wallpapers\BackgroundType = 2
      2. %APPDATA%\Microsoft\Windows\Themes\slideshow.ini 存在且长度大于 0
      3. TranscodedWallpaper 的写入时间在允许的静默期内

    关键事实：slideshow.ini 是幻灯片配置的载体，里面的 ImagesRootPIDL 由
    Windows 加密编码，脚本无法生成。因此本工具只做「备份 → 检测 → 还原」，
    不尝试构造配置。

.PARAMETER Status
    只读报告。

.PARAMETER Check
    只检测。健康退出码 0，否则 1。

.PARAMETER Apply
    立即修复一次，跳过启动延迟。

.PARAMETER Config
    指定配置文件路径。

.PARAMETER NoDelay
    跳过启动延迟。

.PARAMETER CaptureSnapshot
    写入安装前快照后退出。

.PARAMETER RestoreSnapshot
    按安装前快照还原后退出。

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

$script:AppName     = 'slideshow-guard'
$script:InstallRoot = Join-Path $env:LOCALAPPDATA $script:AppName
$script:StateDir    = Join-Path $script:InstallRoot 'state'
$script:LogDir      = Join-Path $script:InstallRoot 'logs'
$script:LogPath     = Join-Path $script:LogDir 'guard.log'
$script:BackupPath  = Join-Path $script:StateDir 'slideshow.ini.bak'
$script:SnapshotPath= Join-Path $script:StateDir 'install-snapshot.json'
$script:TaskName    = 'slideshow-guard'

$script:ThemesDir     = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
$script:IniPath       = Join-Path $script:ThemesDir 'slideshow.ini'
$script:TranscodedPath= Join-Path $script:ThemesDir 'TranscodedWallpaper'

$script:WpKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
$script:SlKey   = 'HKCU:\Control Panel\Personalization\Desktop Slideshow'

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
    } catch { }
    Write-Verbose $entry
}

# ---------------------------------------------------------------- 配置

function Get-GuardConfig {
    param([string]$Path)

    $defaults = [ordered]@{
        intervalMinutes         = 30
        startupDelaySeconds     = 30
        maxSilentMinutes        = 0
        restartExplorerOnRepair = $true
        logMaxBytes             = 262144
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

    $cfg = [pscustomobject]$merged
    $cfg | Add-Member -NotePropertyName ConfigSource -NotePropertyValue $source -Force
    return $cfg
}

function Get-SilentTolerance {
    param($Config, [int]$IntervalMs)
    $custom = [int]$Config.maxSilentMinutes
    if ($custom -gt 0) { return $custom }

    # 容限跟着注册表里的实际间隔走，而不是配置里的默认值
    $minutes = $IntervalMs / 60000
    $auto = [math]::Round($minutes * 2, 1)
    if ($auto -lt 10) { $auto = 10 }
    return $auto
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

# ---------------------------------------------------------------- 状态判定

function Get-SlideshowState {
    param($Config)

    $type     = Get-RegValue -KeyPath $script:WpKey -Name 'BackgroundType'
    $interval = Get-RegValue -KeyPath $script:SlKey -Name 'Interval'
    if ($null -eq $interval -or [int]$interval -le 0) {
        $interval = [int]$Config.intervalMinutes * 60000
    }

    $iniSize = 0
    if ([IO.File]::Exists($script:IniPath)) {
        $iniSize = (New-Object IO.FileInfo $script:IniPath).Length
    }

    $transcodedAge = $null
    if ([IO.File]::Exists($script:TranscodedPath)) {
        $transcodedAge = (Get-Date) - (New-Object IO.FileInfo $script:TranscodedPath).LastWriteTime
    }

    $backupSize = 0
    if ([IO.File]::Exists($script:BackupPath)) {
        $backupSize = (New-Object IO.FileInfo $script:BackupPath).Length
    }

    $tolerance = Get-SilentTolerance -Config $Config -IntervalMs ([int]$interval)
    $fresh = ($null -ne $transcodedAge) -and ($transcodedAge.TotalMinutes -le $tolerance)

    $healthy = ($null -ne $type) -and ([int]$type -eq 2) -and ($iniSize -gt 0) -and $fresh

    [pscustomobject]@{
        BackgroundType  = $type
        IntervalMs      = [int]$interval
        IniSize         = $iniSize
        TranscodedAge   = $transcodedAge
        BackupSize      = $backupSize
        ToleranceMinutes= $tolerance
        IsHealthy       = $healthy
    }
}

# ---------------------------------------------------------------- 配置备份与还原

function Backup-SlideshowConfig {
    $size = 0
    if ([IO.File]::Exists($script:IniPath)) {
        $size = (New-Object IO.FileInfo $script:IniPath).Length
    }
    if ($size -le 0) { return 0 }

    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $script:IniPath -Destination $script:BackupPath -Force
    return $size
}

function Restore-SlideshowConfig {
    if (-not [IO.File]::Exists($script:BackupPath)) { return $false }
    if ((New-Object IO.FileInfo $script:BackupPath).Length -le 0) { return $false }

    if (-not [IO.Directory]::Exists($script:ThemesDir)) {
        New-Item -ItemType Directory -Path $script:ThemesDir -Force | Out-Null
    }

    $copy = {
        if ([IO.File]::Exists($script:IniPath)) {
            [IO.File]::SetAttributes($script:IniPath, [IO.FileAttributes]::Normal)
        }
        Copy-Item -LiteralPath $script:BackupPath -Destination $script:IniPath -Force
    }

    try {
        & $copy
    } catch {
        # ini 可能被 explorer 独占；重启释放句柄后再试一次
        Write-Log 'WARN' ('还原 ini 失败，重启 explorer 后重试: {0}' -f $_.Exception.Message)
        if (-not (Restart-Explorer)) { throw }
        & $copy
    }

    # 还原为 Hidden，与 Windows 自己创建时一致
    $attr = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive
    [IO.File]::SetAttributes($script:IniPath, $attr)
    return $true
}

# ---------------------------------------------------------------- explorer 重启

function Restart-Explorer {
    $proc = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 500
        $proc = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) { return $true }
    } while ((Get-Date) -lt $deadline)

    try {
        Start-Process explorer.exe
        Start-Sleep -Seconds 3
    } catch { }
    return [bool](Get-Process explorer -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- 修复

function Invoke-Repair {
    param($Config)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $actions = New-Object System.Collections.Generic.List[string]

    try {
        $needRestart = $false

        # 不碰壁纸：SPI 设壁纸会清空 slideshow.ini，而 ini 有效时壁纸位置不影响轮播
        # 1. slideshow.ini 必须有效
        $iniOk = [IO.File]::Exists($script:IniPath) -and
            ((New-Object IO.FileInfo $script:IniPath).Length -gt 0)

        if (-not $iniOk) {
            if (-not (Restore-SlideshowConfig)) {
                return [pscustomobject]@{
                    Success = $false; Actions = $actions; ElapsedMs = $watch.ElapsedMilliseconds
                    Detail = 'slideshow.ini 无效且没有可用备份；请先在「设置 → 个性化 → 背景」里手动配置一次幻灯片放映，再运行 install.ps1'
                }
            }
            $actions.Add('restored-ini')
            $needRestart = $true
        }

        # 2. 背景类型
        $type = Get-RegValue -KeyPath $script:WpKey -Name 'BackgroundType'
        if ($null -eq $type -or [int]$type -ne 2) {
            Set-ItemProperty -LiteralPath $script:WpKey -Name 'BackgroundType' -Value 2 -Type DWord
            $actions.Add('set-type')
        }

        # 3. 间隔
        $interval = Get-RegValue -KeyPath $script:SlKey -Name 'Interval'
        if ($null -eq $interval -or [int]$interval -le 0) {
            if (-not (Test-Path -LiteralPath $script:SlKey)) {
                New-Item -Path $script:SlKey -Force | Out-Null
            }
            Set-ItemProperty -LiteralPath $script:SlKey -Name 'Interval' -Value ([int]$Config.intervalMinutes * 60000) -Type DWord
            $actions.Add('set-interval')
        }

        # 4. ini 是刚还原的，必须让 explorer 重新读取
        if ($needRestart) {
            if ([bool]$Config.restartExplorerOnRepair) {
                if (Restart-Explorer) { $actions.Add('restarted-explorer') }
                else { $actions.Add('restart-failed') }
            } else {
                $actions.Add('restart-skipped-needs-relogon')
            }
        }

        if ($actions.Count -eq 0) { $actions.Add('no-op') }

        Start-Sleep -Seconds 3
        $state = Get-SlideshowState -Config $Config
        $ok = ($null -ne $state.BackgroundType) -and ([int]$state.BackgroundType -eq 2) -and ($state.IniSize -gt 0)

        return [pscustomobject]@{
            Success = $ok; Actions = $actions; ElapsedMs = $watch.ElapsedMilliseconds
            Detail = ('BackgroundType={0}, ini={1} 字节' -f $state.BackgroundType, $state.IniSize)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false; Actions = $actions; ElapsedMs = $watch.ElapsedMilliseconds
            Detail = $_.Exception.Message
        }
    } finally {
        $watch.Stop()
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
        iniSize    = 0
        keys       = @{}
    }
    if ([IO.File]::Exists($script:IniPath)) {
        $data['iniSize'] = (New-Object IO.FileInfo $script:IniPath).Length
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
    $cfg = Get-GuardConfig -Path $Config
    $state = Get-SlideshowState -Config $cfg

    $taskText = '未注册'
    $lastRun = '无记录'
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($task) {
            $taskText = [string]$task.State
            $info = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
            if ($info -and $info.LastRunTime) {
                $result = '成功'
                if ($info.LastTaskResult -ne 0) { $result = '退出码 ' + $info.LastTaskResult }
                $lastRun = '{0} ({1})' -f $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss'), $result
            }
        }
    }

    $verdict = 'NOT-SLIDESHOW'
    if ($state.IsHealthy) { $verdict = 'OK' }
    elseif (($null -ne $state.BackgroundType) -and ([int]$state.BackgroundType -eq 2)) { $verdict = 'DEGRADED' }

    $intervalText = '{0} 分钟' -f [math]::Round($state.IntervalMs / 60000, 1)

    Write-Host ''
    Write-Host ('slideshow-guard  {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('  背景类型       : {0} ({1})' -f $state.BackgroundType, (Get-BackgroundTypeName $state.BackgroundType))
    Write-Host ('  切换间隔       : {0}' -f $intervalText)
    Write-Host ('  slideshow.ini  : {0} 字节' -f $state.IniSize)
    Write-Host ('  上次转码       : {0}' -f (ConvertTo-AgeText $state.TranscodedAge))
    Write-Host ('  静默容限       : {0} 分钟' -f $state.ToleranceMinutes)
    Write-Host ('  ini 备份       : {0} 字节' -f $state.BackupSize)
    Write-Host ('  计划任务       : {0} / 最近运行 {1}' -f $taskText, $lastRun)
    Write-Host ('  结论           : {0}' -f $verdict)
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

$state = Get-SlideshowState -Config $cfg

if ($Check) {
    if ($state.IsHealthy) { exit 0 }
    exit 1
}

if (-not $Apply -and $state.IsHealthy) {
    Write-Log 'INFO' ('跳过：幻灯片健康 (type={0}, ini={1}B, 转码 {2} 分钟前)' -f $state.BackgroundType, $state.IniSize, [int]$state.TranscodedAge.TotalMinutes)
    exit 0
}

Write-Log 'INFO' ('修复：type={0} ({1}), ini={2}B, 转码 {3} 分钟前, 容限 {4} 分钟' -f $state.BackgroundType, (Get-BackgroundTypeName $state.BackgroundType), $state.IniSize, [int]$state.TranscodedAge.TotalMinutes, $state.ToleranceMinutes)

$result = Invoke-Repair -Config $cfg
$actionText = ($result.Actions -join ',')

if ($result.Success) {
    Write-Log 'INFO' ('完成：耗时 {0}ms，动作 [{1}]，{2}' -f $result.ElapsedMs, $actionText, $result.Detail)
    exit 0
}

Write-Log 'ERROR' ('失败：耗时 {0}ms，动作 [{1}]，{2}' -f $result.ElapsedMs, $actionText, $result.Detail)
exit 1
