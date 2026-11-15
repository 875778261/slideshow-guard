# slideshow-guard

守护 Windows 10 桌面处于「幻灯片放映」并真实换图。核心是备份与恢复 `%APPDATA%\Microsoft\Windows\Themes\slideshow.ini`，不生成它。改动前先读 `docs/adr/0001-slideshow-ini-carries-the-config.md`。

## 命令

```powershell
# 只读状态
powershell -NoProfile -ExecutionPolicy Bypass -File .\slideshow-guard.ps1 -Status

# 只检测：健康返回 0，否则 1
powershell -NoProfile -ExecutionPolicy Bypass -File .\slideshow-guard.ps1 -Check

# 立刻修复一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\slideshow-guard.ps1 -Apply

# 安装 / 卸载（写 HKCU 与计划任务，不需要管理员）
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

没有 build 与测试套件。验证一律看 `-Status` 的「上次转码」是否随间隔推进，不看脚本自己打印的成功。

## 硬约束

- **不要用 `SystemParametersInfo(SPI_SETDESKWALLPAPER)` 改壁纸**，除非当前壁纸确实不在图库内。每次改动都会把 `slideshow.ini` 清成 0 字节，也就是把幻灯片弄坏。
- 判断轮播是否工作看 `TranscodedWallpaper` 的 `LastWriteTime`，不要看 `LastTickLow/High`（恒为 0）。
- `slideshow.ini` 带 Hidden 属性，读取用 `[IO.FileInfo]` 或 `Get-Item -Force`。
- 修复顺序固定：壁纸锚定 → ini 检查/还原 → 写 type → 重启 explorer。ini 检查必须排在壁纸操作之后。
- PowerShell 5.1 兼容（不使用 `??`、三元、`if` 表达式赋值）。
- `.ps1` 文件必须 UTF-8 **带 BOM**，否则 5.1 读中文会乱码。

共享 skills 与跨仓文档在 `D:\workspace\home`。提交信息规范见 `D:\workspace\home\docs\standards\commit-convention.md`。
