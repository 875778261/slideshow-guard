# slideshow-guard

实验仓库：验证「能否用脚本保证 Windows 10 桌面始终处于幻灯片放映」。

**结论：不能。** 系统「幻灯片放映」在这台机器上无法由脚本启用，手动设置同样失效。

先读 [docs/adr/0001-desktop-slideshow-not-scriptable.md](docs/adr/0001-desktop-slideshow-not-scriptable.md)，里面有三层实测原因和下次接手前的 30 秒验证方法。

## 仓库里有什么

| 文件 | 作用 | 状态 |
|---|---|---|
| `slideshow-guard.ps1` | 自管轮播：从图库选图、SPI 换壁纸、快照比对、日志 | 可用，但不是用户要的「幻灯片放映」 |
| `install.ps1` | 部署到 `%LOCALAPPDATA%`、生成配置、注册计划任务、首次运行 | 可用 |
| `uninstall.ps1` | 删任务、按安装前快照还原背景设置、可选清理 | 可用 |
| `run-hidden.vbs` | 无窗口启动 PowerShell | 可用 |
| `config.example.json` | 配置模板 | — |
| `docs/evidence/guard.log` | 实验期日志 | 证据 |

## 不要直接部署

这份代码实现的是「脚本自己换壁纸」，设置界面会显示**图片**而不是**幻灯片放映**。它在本机实测能换图，但与原始需求不符，且会与 Windows 聚焦互相抢占。

## 如果要复用

- 只想要「每次开机换一张壁纸」：可直接看 `install.ps1` + `slideshow-guard.ps1`。
- 想要「设置界面显示幻灯片放映」：先按 ADR 最后一节验证目标机器的幻灯片是否可用；可用则改写注册表路径，其余骨架（检测、快照、卸载）可直接套用。

## 已记录的坑

- `ILGetSize` 计算 PIDL 长度时，`SHITEMID.cb` 已含 2 字节头，累加 `cb` 而不是 `2 + cb`，否则越界读出几万字节垃圾。
- `BackgroundType=2` 时若当前壁纸不在幻灯片图库内，explorer 重启会把它重置为 0。
- `DesktopSpotlight\Settings\EnabledState = 1` 会把 `BackgroundType` 抢成 3，并替换壁纸。
- `rundll32 themeui.dll,OpenThemeAction <theme>` 在本机会阻塞不返回，15 秒超时后才能终止。
