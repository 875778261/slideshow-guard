#Requires -Version 5.1
<#
.SYNOPSIS
    安装 slideshow-guard：部署脚本、生成配置、注册登录计划任务，并立刻跑一次。

.DESCRIPTION
    不需要管理员权限。所有改动都落在当前用户范围内：
      - 文件写入 %LOCALAPPDATA%\slideshow-guard\
      - 计划任务注册在当前用户名下，登录时触发
      - 注册表只写 HKCU

.PARAMETER SourceFolder
    幻灯片图库目录。默认 %USERPROFILE%\Pictures\Slideshow，安装时若目录为空会从系统壁纸播种。

.PARAMETER IntervalMinutes
    切换间隔，分钟。默认 30。

.PARAMETER Reconfigure
    覆盖已存在的 config.json。

.PARAMETER NoRun
    只安装，不立刻执行一次修复。

.PARAMETER NoTask
    只部署文件与配置，不注册计划任务（测试用）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -SourceFolder D:\Wallpapers -IntervalMinutes 10
#>
[CmdletBinding()]
param(
    [string]$SourceFolder,
    [int]$IntervalMinutes = 30,
    [switch]$Reconfigure,
    [switch]$NoRun,
    [switch]$NoTask
)

$ErrorActionPreference = 'Stop'

$appName     = 'slideshow-guard'
$installRoot = Join-Path $env:LOCALAPPDATA $appName
$stateDir    = Join-Path $installRoot 'state'
$logDir      = Join-Path $installRoot 'logs'
$configPath  = Join-Path $installRoot 'config.json'
$snapshotPath= Join-Path $stateDir 'install-snapshot.json'
$taskName    = $appName

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 环境校验

Write-Step '环境校验'

$os = Get-CimInstance Win32_OperatingSystem
if (-not $os.Caption.Contains('Windows 10')) {
    Write-Host "当前系统是 $($os.Caption)，本工具只针对 Windows 10。" -ForegroundColor Yellow
}
Write-Host ("系统     : {0} ({1})" -f $os.Caption, $os.Version)
Write-Host ("PowerShell: {0}" -f $PSVersionTable.PSVersion)

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "需要 PowerShell 5.1 或更高版本"
}

# ---------------------------------------------------------------- 部署文件

Write-Step '部署文件'

foreach ($dir in @($installRoot, $stateDir, $logDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "创建 $dir"
    }
}

$sourceGuard = Join-Path $PSScriptRoot 'slideshow-guard.ps1'
$sourceVbs   = Join-Path $PSScriptRoot 'run-hidden.vbs'
foreach ($file in @($sourceGuard, $sourceVbs)) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "缺少安装文件: $file"
    }
}

Copy-Item -LiteralPath $sourceGuard -Destination (Join-Path $installRoot 'slideshow-guard.ps1') -Force
Copy-Item -LiteralPath $sourceVbs   -Destination (Join-Path $installRoot 'run-hidden.vbs')   -Force
Write-Host "已部署到 $installRoot"

# ---------------------------------------------------------------- 配置

Write-Step '生成配置'

if (-not $SourceFolder) {
    $SourceFolder = Join-Path $env:USERPROFILE 'Pictures\Slideshow'
}

if ((Test-Path -LiteralPath $configPath) -and -not $Reconfigure) {
    Write-Host "配置已存在，保持不动：$configPath" -ForegroundColor Yellow
} else {
    $config = [ordered]@{
        sourceFolder        = $SourceFolder
        intervalMinutes     = $IntervalMinutes
        wallpaperStyle      = 10
        startupDelaySeconds = 30
        seedFromSystem      = $true
        logMaxBytes         = 262144
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 4), $utf8Bom)
    Write-Host "已写入 $configPath"
    Write-Host ("图库目录 : {0}" -f $SourceFolder)
    Write-Host ("切换间隔 : {0} 分钟" -f $IntervalMinutes)
}

# ---------------------------------------------------------------- 安装前快照

Write-Step '安装前快照'

if (Test-Path -LiteralPath $snapshotPath) {
    Write-Host "快照已存在，保留首次安装前的状态：$snapshotPath" -ForegroundColor Yellow
} else {
    $guard = Join-Path $installRoot 'slideshow-guard.ps1'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $guard -CaptureSnapshot
    if ($LASTEXITCODE -ne 0) { throw "安装前快照失败，退出码 $LASTEXITCODE" }
}

# ---------------------------------------------------------------- 计划任务

if ($NoTask) {
    Write-Step '计划任务（已跳过）'
} else {
    Write-Step '注册计划任务'

    $vbsPath = Join-Path $installRoot 'run-hidden.vbs'
    $user    = "$env:USERDOMAIN\$env:USERNAME"
    $registered = $false

    try {
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' `
            -Argument ('//B //Nologo "{0}"' -f $vbsPath) -WorkingDirectory $installRoot

        $triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
        $triggerRepeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        try { $settings.Hidden = $true } catch { }
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($triggerLogon, $triggerRepeat) `
            -Settings $settings -Principal $principal `
            -Description '登录时与每隔一段时间切换桌面壁纸' -Force | Out-Null
        $registered = $true
        Write-Host "已注册计划任务 $taskName（登录时 + 每 $IntervalMinutes 分钟，隐藏窗口）"
    } catch {
        Write-Host "Register-ScheduledTask 失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (-not $registered) {
        $taskRun = 'wscript.exe //B //Nologo "{0}"' -f $vbsPath
        $output = & schtasks.exe /Create /TN $taskName /TR $taskRun /SC MINUTE /MO $IntervalMinutes /RL LIMITED /F 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host ($output | Out-String) -ForegroundColor Yellow
            throw "计划任务注册失败。可手动把 $vbsPath 放进「启动」文件夹作为替代。"
        }
        Write-Host "已通过 schtasks 注册计划任务 $taskName（每 $IntervalMinutes 分钟；登录后首次可能延迟一个周期）"
    }
}

# ---------------------------------------------------------------- 立刻跑一次

if ($NoRun) {
    Write-Step '首次运行（已跳过）'
} else {
    Write-Step '首次运行'
    $guard = Join-Path $installRoot 'slideshow-guard.ps1'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $guard -Apply -NoDelay
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Host '首次修复成功' -ForegroundColor Green
    } else {
        Write-Host "首次修复失败，退出码 $code。查看 $logDir\guard.log" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------- 收尾

Write-Step '安装完成'

Write-Host '可用命令：'
Write-Host ('  查看状态  powershell -ExecutionPolicy Bypass -File "{0}" -Status' -f (Join-Path $installRoot 'slideshow-guard.ps1'))
Write-Host ('  只检测    powershell -ExecutionPolicy Bypass -File "{0}" -Check' -f (Join-Path $installRoot 'slideshow-guard.ps1'))
Write-Host ('  立刻修复  powershell -ExecutionPolicy Bypass -File "{0}" -Apply' -f (Join-Path $installRoot 'slideshow-guard.ps1'))
Write-Host ('  卸载      powershell -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'uninstall.ps1'))
Write-Host ''
Write-Host '验证方式：连续运行两次 -Status，看「当前壁纸」与「上次轮换」是否随之变化。'
