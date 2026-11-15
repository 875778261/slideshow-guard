#Requires -Version 5.1
<#
.SYNOPSIS
    卸载 slideshow-guard：删除计划任务，并打印安装前的配置供手工恢复。

.DESCRIPTION
    默认只做一件事：删除计划任务。不改任何背景设置，不碰 slideshow.ini。

    为什么不自动恢复：恢复背景设置要写 Control Panel\Desktop\Wallpaper，
    而写壁纸会让 Windows 清空 slideshow.ini —— 这正是本工具要修的那个故障。
    卸载时自动恢复等于亲手制造故障，所以恢复留给用户自己做，
    脚本只负责把「装之前是什么样」打印清楚。

.PARAMETER RestoreSettings
    真的按快照写回注册表。会清空 slideshow.ini，恢复后需要重新手动配置一次幻灯片。

.PARAMETER NoTask
    不删计划任务。

.PARAMETER Purge
    连 %LOCALAPPDATA%\slideshow-guard\ 一起删除，包含日志、配置与 ini 备份。
    快照也会被删掉，删除前请先确认已经看过报告。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
    [switch]$RestoreSettings,
    [switch]$NoTask,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$appName      = 'slideshow-guard'
$installRoot  = Join-Path $env:LOCALAPPDATA $appName
$guard        = Join-Path $installRoot 'slideshow-guard.ps1'
$snapshotPath = Join-Path $installRoot 'state\install-snapshot.json'
$taskName     = $appName
$iniPath      = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\slideshow.ini'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
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

function Write-SnapshotReport {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host '没有找到安装快照，无法报告原始配置。' -ForegroundColor Yellow
        return
    }

    $snap = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json

    Write-Host ('快照时间 : {0}' -f $snap.capturedAt)
    Write-Host ('采集机器 : {0}\{1}' -f $snap.computer, $snap.user)

    $iniText = '未记录'
    $iniHolder = $snap.PSObject.Properties['iniExists']
    if ($null -ne $iniHolder) {
        if ($snap.iniExists) { $iniText = ('{0} 字节' -f $snap.iniSize) }
        else { $iniText = '不存在' }
    }
    Write-Host ('slideshow.ini : {0}' -f $iniText)

    foreach ($section in $snap.keys.PSObject.Properties) {
        Write-Host ''
        Write-Host ('[{0}]' -f $section.Name)
        foreach ($value in $section.Value.PSObject.Properties) {
            $kind = [string]$value.Value.kind
            if ($kind -eq 'NotExist') {
                Write-Host ('    {0} : <不存在>' -f $value.Name)
                continue
            }
            $text = [string]$value.Value.value
            if ($value.Name -eq 'BackgroundType') {
                $text = '{0} ({1})' -f $text, (Get-BackgroundTypeName $value.Value.value)
            }
            Write-Host ('    {0} : {1}' -f $value.Name, $text)
        }
    }
    Write-Host ''
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
        # schtasks 在任务不存在时会往 stderr 写错误，$ErrorActionPreference=Stop 下会中断脚本
        $exists = $false
        try {
            $null = & schtasks.exe /Query /TN $taskName 2>&1
            $exists = ($LASTEXITCODE -eq 0)
        } catch {
            $exists = $false
        }
        if ($exists) {
            try {
                $null = & schtasks.exe /Delete /TN $taskName /F 2>&1
                if ($LASTEXITCODE -eq 0) { $removed = $true }
            } catch { }
        }
    }

    if ($removed) {
        Write-Host "已删除计划任务 $taskName"
    } else {
        Write-Host '计划任务不存在或已删除' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 原始配置报告

Write-Step '安装前的配置（供手工恢复参考）'
Write-SnapshotReport -Path $snapshotPath

Write-Host '注意：本工具不自动恢复上面的设置。'
Write-Host '     恢复背景设置会写 Wallpaper，进而清空 slideshow.ini，'
Write-Host '     那正是本工具要修的那个故障。'
Write-Host ''

if ($RestoreSettings) {
    Write-Step '按快照恢复（-RestoreSettings）'

    $targetType = $null
    if (Test-Path -LiteralPath $snapshotPath) {
        try {
            $snap = [IO.File]::ReadAllText($snapshotPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $section = $snap.keys.PSObject.Properties['Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers']
            if ($null -ne $section) {
                $holder = $section.Value.PSObject.Properties['BackgroundType']
                if ($null -ne $holder) { $targetType = [int]$holder.Value.value }
            }
        } catch { }
    }

    if (-not (Test-Path -LiteralPath $guard)) {
        Write-Host "找不到 $guard，无法恢复" -ForegroundColor Yellow
    } else {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $guard -RestoreSnapshot
        if ($LASTEXITCODE -eq 0) {
            Write-Host '已按安装前快照还原注册表'
        } else {
            Write-Host "还原失败，退出码 $LASTEXITCODE" -ForegroundColor Red
        }
    }

    # 写 Wallpaper 会让 Windows 清空 ini。按目标状态收尾：
    #   非幻灯片 → 删除。留成 0 字节会让设置里的「幻灯片放映」写不进去，用户就没法手动配置
    #   幻灯片   → 从备份还原，否则轮播起不来
    if ($null -ne $targetType -and $targetType -ne 2) {
        if ([IO.File]::Exists($iniPath)) {
            Remove-Item -LiteralPath $iniPath -Force
            Write-Host '快照不是幻灯片模式，已删除 slideshow.ini' -ForegroundColor Yellow
            Write-Host '现在可以在「设置 → 个性化 → 背景」里正常选择背景类型' -ForegroundColor Yellow
        }
    } elseif ($null -ne $targetType -and $targetType -eq 2) {
        $backupPath = Join-Path $installRoot 'state\slideshow.ini.bak'
        if ([IO.File]::Exists($backupPath)) {
            Copy-Item -LiteralPath $backupPath -Destination $iniPath -Force
            $attr = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive
            [IO.File]::SetAttributes($iniPath, $attr)
            Write-Host '快照是幻灯片模式，已从备份还原 slideshow.ini'
        } else {
            Write-Host '快照是幻灯片模式，但没有 ini 备份，需要手动重新配置一次' -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------- 幻灯片配置

Write-Step '幻灯片配置'

if ([IO.File]::Exists($iniPath)) {
    $size = (New-Object IO.FileInfo $iniPath).Length
    if ($size -gt 0) {
        Write-Host "slideshow.ini 保持原样（$size 字节），未做任何改动"
    } else {
        Write-Host 'slideshow.ini 当前是 0 字节'
        Write-Host '如需恢复幻灯片：删掉这个空文件，然后在「设置 → 个性化 → 背景」里重新选一次「幻灯片放映」'
    }
} else {
    Write-Host 'slideshow.ini 不存在，未做任何改动'
}

# ---------------------------------------------------------------- 清理

if ($Purge) {
    Write-Step '清理程序目录'
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
        Write-Host "已删除 $installRoot（快照同时删除）"
    }
} else {
    Write-Step '保留程序目录'
    Write-Host "程序目录与日志保留在 $installRoot（加 -Purge 一并删除）"
    Write-Host "快照仍在 $snapshotPath，随时可再次查看"
}

Write-Step '卸载完成'
