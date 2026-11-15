#Requires -Version 5.1
<#
.SYNOPSIS
    安装 slideshow-guard：部署脚本、备份幻灯片配置、注册计划任务。

.DESCRIPTION
    前提：这台机器上的「幻灯片放映」已经能正常工作——手动设置之后桌面会按间隔换图。

    本工具不生成幻灯片配置。slideshow.ini 里的 ImagesRootPIDL 由 Windows 加密编码，
    脚本无法构造，只负责备份和恢复。所以安装时会先校验这个文件有效，无效则中止。

    不需要管理员权限：只写 HKCU 与 %LOCALAPPDATA%，计划任务注册在当前用户名下。

.PARAMETER IntervalMinutes
    幻灯片切换间隔，写入 Desktop Slideshow\Interval。默认 30。

.PARAMETER CheckEveryMinutes
    计划任务的检查周期，分钟。默认 0，即只在登录时运行一次。传正数则额外按该周期重复检查。

.PARAMETER LogonOnly
    只在登录时运行一次，不注册周期触发器。

.PARAMETER Reconfigure
    覆盖已存在的 config.json。

.PARAMETER NoRun
    只安装，不立刻执行一次检查。

.PARAMETER NoTask
    只部署文件与配置，不注册计划任务（测试用）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -LogonOnly

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -IntervalMinutes 10 -CheckEveryMinutes 30
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 30,
    [int]$CheckEveryMinutes = 0,
    [switch]$LogonOnly,
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
$backupPath  = Join-Path $stateDir 'slideshow.ini.bak'
$snapshotPath= Join-Path $stateDir 'install-snapshot.json'
$taskName    = $appName
$iniPath     = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\slideshow.ini'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 环境校验

Write-Step '环境校验'

$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("系统     : {0} ({1})" -f $os.Caption, $os.Version)
Write-Host ("PowerShell: {0}" -f $PSVersionTable.PSVersion)

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw '需要 PowerShell 5.1 或更高版本'
}

# ---------------------------------------------------------------- 校验幻灯片配置

Write-Step '校验幻灯片配置'

$iniSize = 0
if ([IO.File]::Exists($iniPath)) {
    $iniSize = (New-Object IO.FileInfo $iniPath).Length
}
Write-Host ("slideshow.ini : {0} ({1} 字节)" -f $iniPath, $iniSize)

$canBackup = $iniSize -gt 0
if (-not $canBackup) {
    Write-Host ''
    Write-Host 'slideshow.ini 无效（0 字节或不存在）。' -ForegroundColor Yellow
    Write-Host '本工具无法生成它，安装会继续，但这次没有可备份的配置。' -ForegroundColor Yellow
    Write-Host '请稍后手动配置一次幻灯片，确认桌面会换图：' -ForegroundColor Yellow
    Write-Host '  设置 → 个性化 → 背景 → 幻灯片放映' -ForegroundColor Yellow
    Write-Host '配置成功后，脚本在下次检查时即可正常工作。' -ForegroundColor Yellow
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
    if (-not (Test-Path -LiteralPath $file)) { throw "缺少安装文件: $file" }
}

Copy-Item -LiteralPath $sourceGuard -Destination (Join-Path $installRoot 'slideshow-guard.ps1') -Force
Copy-Item -LiteralPath $sourceVbs   -Destination (Join-Path $installRoot 'run-hidden.vbs')   -Force
Write-Host "已部署到 $installRoot"

# ---------------------------------------------------------------- 备份幻灯片配置

Write-Step '备份幻灯片配置'

if ($canBackup) {
    Copy-Item -LiteralPath $iniPath -Destination $backupPath -Force
    Write-Host ("已备份到 {0}（{1} 字节）" -f $backupPath, (New-Object IO.FileInfo $backupPath).Length)
} elseif (Test-Path -LiteralPath $backupPath) {
    Write-Host "当前 ini 无效，保留已有备份：$backupPath" -ForegroundColor Yellow
} else {
    Write-Host '跳过：当前 ini 无效且没有历史备份' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 配置

Write-Step '生成配置'

$effectiveCheck = $CheckEveryMinutes
if ($LogonOnly) { $effectiveCheck = 0 }
if ($effectiveCheck -lt 0) { $effectiveCheck = 0 }

if ((Test-Path -LiteralPath $configPath) -and -not $Reconfigure) {
    Write-Host "配置已存在，保持不动：$configPath" -ForegroundColor Yellow
} else {
    $config = [ordered]@{
        intervalMinutes         = $IntervalMinutes
        checkEveryMinutes       = $effectiveCheck
        startupDelaySeconds     = 30
        maxSilentMinutes        = 0
        restartExplorerOnRepair = $true
        logMaxBytes             = 262144
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 4), $utf8Bom)
    Write-Host "已写入 $configPath"
    Write-Host ("切换间隔 : {0} 分钟" -f $IntervalMinutes)
    if ($effectiveCheck -gt 0) {
        Write-Host ("检查周期 : {0} 分钟" -f $effectiveCheck)
    } else {
        Write-Host '检查周期 : 仅登录时'
    }
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

        $triggers = @(New-ScheduledTaskTrigger -AtLogOn -User $user)
        if ($effectiveCheck -gt 0) {
            $triggers += New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
                -RepetitionInterval (New-TimeSpan -Minutes $effectiveCheck) `
                -RepetitionDuration (New-TimeSpan -Days 3650)
        }

        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        try { $settings.Hidden = $true } catch { }
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers `
            -Settings $settings -Principal $principal `
            -Description '登录时检查桌面幻灯片是否仍然有效' -Force | Out-Null
        $registered = $true
        if ($effectiveCheck -gt 0) {
            Write-Host "已注册计划任务 $taskName（登录时 + 每 $effectiveCheck 分钟，隐藏窗口）"
        } else {
            Write-Host "已注册计划任务 $taskName（仅登录时，隐藏窗口）"
        }
    } catch {
        Write-Host "Register-ScheduledTask 失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (-not $registered) {
        $taskRun = 'wscript.exe //B //Nologo "{0}"' -f $vbsPath
        if ($effectiveCheck -gt 0) {
            $scArgs = @('/SC', 'MINUTE', '/MO', "$effectiveCheck")
        } else {
            $scArgs = @('/SC', 'ONLOGON')
        }
        try {
            $output = & schtasks.exe /Create /TN $taskName /TR $taskRun @scArgs /RL LIMITED /F 2>&1
            $schtasksCode = $LASTEXITCODE
        } catch {
            $output = $_.Exception.Message
            $schtasksCode = 1
        }
        if ($schtasksCode -ne 0) {
            Write-Host ($output | Out-String) -ForegroundColor Yellow
            throw "计划任务注册失败。可手动把 $vbsPath 放进「启动」文件夹作为替代。"
        }
        if ($effectiveCheck -gt 0) {
            Write-Host "已通过 schtasks 注册计划任务 $taskName（每 $effectiveCheck 分钟）"
        } else {
            Write-Host "已通过 schtasks 注册计划任务 $taskName（仅登录时）"
        }
    }
}

# ---------------------------------------------------------------- 立刻跑一次

if ($NoRun) {
    Write-Step '首次检查（已跳过）'
} else {
    Write-Step '首次检查'
    $guard = Join-Path $installRoot 'slideshow-guard.ps1'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $guard -Apply -NoDelay
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Host '首次检查通过' -ForegroundColor Green
    } else {
        Write-Host "首次检查未通过，退出码 $code。查看 $logDir\guard.log" -ForegroundColor Red
        if (-not $canBackup) {
            Write-Host '这通常是因为 slideshow.ini 还没配置过：先手动配一次幻灯片，再跑一次 -Apply 验证。' -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------- 收尾

Write-Step '安装完成'

$guardPath = Join-Path $installRoot 'slideshow-guard.ps1'
Write-Host '可用命令：'
Write-Host ('  查看状态  powershell -ExecutionPolicy Bypass -File "{0}" -Status' -f $guardPath)
Write-Host ('  只检测    powershell -ExecutionPolicy Bypass -File "{0}" -Check' -f $guardPath)
Write-Host ('  立刻修复  powershell -ExecutionPolicy Bypass -File "{0}" -Apply' -f $guardPath)
Write-Host ('  卸载      powershell -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'uninstall.ps1'))
Write-Host ''
Write-Host '验证方式：连跑两次 -Status，看「上次转码」是否随间隔推进。'
