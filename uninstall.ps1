#Requires -Version 5.1
<#
.SYNOPSIS
    卸载 slideshow-guard：删除计划任务，按安装前快照还原背景设置。

.DESCRIPTION
    默认行为是「装之前什么样，卸完还什么样」：
      1. 删除登录与周期触发的计划任务
      2. 用 state\install-snapshot.json 还原 HKCU 下的背景相关值
      3. 保留 slideshow.ini —— 它属于 Windows 自己的配置，不随本工具删除
      4. 保留程序目录与日志，方便事后核查

.PARAMETER KeepSettings
    不还原注册表，只删计划任务。

.PARAMETER NoTask
    不删计划任务，只处理设置。

.PARAMETER Purge
    连 %LOCALAPPDATA%\slideshow-guard\ 一起删除，包含日志与 ini 备份。
    图库目录与 slideshow.ini 不会被删除。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
    [switch]$KeepSettings,
    [switch]$NoTask,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$appName     = 'slideshow-guard'
$installRoot = Join-Path $env:LOCALAPPDATA $appName
$guard       = Join-Path $installRoot 'slideshow-guard.ps1'
$taskName    = $appName

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 计划任务

if ($NoTask) {
    Write-Step '计划任务（已跳过）'
} else {
    Write-Step '删除计划任务'

    $removed = $false
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            try {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                $removed = $true
            } catch {
                Write-Host "Unregister-ScheduledTask 失败：$($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if (-not $removed) {
        $null = & schtasks.exe /Query /TN $taskName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $null = & schtasks.exe /Delete /TN $taskName /F 2>&1
            if ($LASTEXITCODE -eq 0) { $removed = $true }
        }
    }

    if ($removed) {
        Write-Host "已删除计划任务 $taskName"
    } else {
        Write-Host '计划任务不存在或已删除' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 还原设置

if ($KeepSettings) {
    Write-Step '还原背景设置（已跳过 -KeepSettings）'
} else {
    Write-Step '还原背景设置'

    if (-not (Test-Path -LiteralPath $guard)) {
        Write-Host "找不到 $guard，无法还原" -ForegroundColor Yellow
    } else {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $guard -RestoreSnapshot
        if ($LASTEXITCODE -eq 0) {
            Write-Host '已按安装前快照还原'
        } else {
            Write-Host "还原失败，退出码 $LASTEXITCODE" -ForegroundColor Red
        }
    }
}

# ---------------------------------------------------------------- 清理

$iniPath = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\slideshow.ini'
if ([IO.File]::Exists($iniPath)) {
    $size = (New-Object IO.FileInfo $iniPath).Length
    Write-Step '保留幻灯片配置'
    Write-Host "slideshow.ini 保持原样（$size 字节），它是 Windows 自己的配置"
}

if ($Purge) {
    Write-Step '清理程序目录'
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
        Write-Host "已删除 $installRoot"
    }
} else {
    Write-Step '保留程序目录'
    Write-Host "程序目录与日志保留在 $installRoot（加 -Purge 一并删除）"
}

Write-Step '卸载完成'
