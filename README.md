# slideshow-guard

守护 Windows 10 桌面处于「幻灯片放映」模式并真实换图。

登录时和每 10 分钟检查一次，不满足就修；满足则零写入、直接退出。

## 它修什么

幻灯片配置全部装在 `%APPDATA%\Microsoft\Windows\Themes\slideshow.ini` 里，而这个文件会被**任何一次"设壁纸"操作清空成 0 字节**。文件一空，`BackgroundType` 就回退为「图片」或「Windows 聚焦」，设置界面也跟着变。

本工具不生成这个文件（里面的 `ImagesRootPIDL` 由 Windows 加密编码，手工造不出来），只做三件事：

1. 安装时备份一份有效的 `slideshow.ini`
2. 定期检查它是否还有效、`BackgroundType` 是否还是 2
3. 失效就还原备份，必要时重启 explorer 让它重新读取

细节见 [ADR-0001](docs/adr/0001-slideshow-ini-carries-the-config.md)。

## 安装前提

这台机器上的幻灯片必须**本来就能用**——手动设置后等一个间隔，桌面确实换了图。达不到这个前提，`install.ps1` 会中止并提示你先手动配一次。

## 用法

```powershell
# 安装（不需要管理员权限）
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 指定图库与切换间隔
powershell -ExecutionPolicy Bypass -File .\install.ps1 -LibraryFolder D:\Wallpapers -IntervalMinutes 10

# 查看状态
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\slideshow-guard\slideshow-guard.ps1" -Status

# 只检测：健康返回 0，否则 1
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\slideshow-guard\slideshow-guard.ps1" -Check

# 立刻修一次
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\slideshow-guard\slideshow-guard.ps1" -Apply

# 卸载（按安装前快照还原，保留 slideshow.ini）
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

状态报告示例：

```
  背景类型       : 2 (幻灯片)
  切换间隔       : 1 分钟
  slideshow.ini  : 829 字节
  上次转码       : 不到 1 分钟前
  静默容限       : 10 分钟
  ini 备份       : 829 字节
  计划任务       : Ready / 最近运行 2026-11-15 21:09:09 (成功)
  结论           : OK
```

## 文件

| 文件 | 作用 |
|---|---|
| `slideshow-guard.ps1` | 检测与自愈，单文件，PS 5.1 兼容 |
| `install.ps1` | 校验配置、部署、备份 ini、注册计划任务 |
| `uninstall.ps1` | 删任务、按快照还原、可选清理 |
| `run-hidden.vbs` | 无窗口启动器 |
| `config.example.json` | 配置模板 |

## 已知限制

- 图库只有 1 张图时状态成立但不会换图（没有下一张）。
- 修复 ini 后要重启 explorer，登录后会闪一下任务栏。正常开机时 explorer 新启动、直接读到有效 ini，不需要重启。
- 改了图库目录，需要在设置里重新配置一次幻灯片，再跑 `install.ps1 -Reconfigure`。

## 坑

- **别用 SPI 设壁纸**。每次 `SystemParametersInfo(SPI_SETDESKWALLPAPER)` 都会清空 `slideshow.ini`，这正是本工具要修的那个故障的成因。
- `Desktop Slideshow\LastTickLow/High` 恒为 0，即使轮播正常也不更新，不能拿它判断轮播是否工作。正确判据是 `TranscodedWallpaper` 的 `LastWriteTime`。
- `slideshow.ini` 带 Hidden 属性，`Get-Item` 不加 `-Force` 会看不到，容易误判为"文件不存在"。
- `BackgroundType=2` 时若当前壁纸在幻灯片图库之外，explorer 重启会把它重置为 0。
