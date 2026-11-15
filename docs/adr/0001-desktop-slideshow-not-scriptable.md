# ADR-0001：Windows 10 桌面「幻灯片放映」无法由脚本可靠启用

- Status: accepted
- Date: 2026-11-15
- Deciders: 用户、agent
- 关联：用户需求「每次开机后检查桌面背景是否是幻灯片播放，如果不是则切换过去」

## 背景

目标是用脚本保证 Windows 10 桌面始终处于「幻灯片放映」模式，而不是「图片」「纯色」或「Windows 聚焦」。验收标准是**设置 → 个性化 → 背景**里显示「幻灯片放映」，且桌面按间隔真实换图。

实测环境：Windows 10 企业版 LTSC，`10.0.19044`，当前用户 `Administrator`，console 会话（非 RDP）。

## 实测过程与结果

### 1. 直接写注册表

写入下列值后调用 `SystemParametersInfo(SPI_SETDESKWALLPAPER)` 或广播 `WM_SETTINGCHANGE`：

| 键 | 值 |
|---|---|
| `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers\BackgroundType` | `2` (DWord) |
| 同上 `SlideshowDirectoryPath1` | base64(PIDL) |
| `HKCU\Control Panel\Personalization\Desktop Slideshow\Interval` | `1800000` |
| 同上 `Shuffle` | `1` |
| 同上 `LastTickLow` / `LastTickHigh` | `0` |

结果：`BackgroundType` 读出来是 2，但桌面不重绘，`%APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper` 的 `LastWriteTime` 不变。

### 2. 重启 explorer

结果分两种：

- 当前壁纸**不在**幻灯片图库内 → explorer 启动约 15 秒后把 `BackgroundType` 重置为 `0`（图片）
- 当前壁纸**在**图库内 → `BackgroundType` 能保持 `2`

第二种情况下保持 80 秒，`LastTickLow/High` 恒为 `0`，壁纸不动——**切换定时器从未运行**。

### 3. 写 LastTick

把 `LastTickLow` 写成 `GetTickCount64()` 的真实值后 15 秒，`BackgroundType` 被重置为 `0`。explorer 对 `LastTick` 有校验，外部写入被判为不可信。

### 4. 关闭 Windows 聚焦

`HKCU\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings\EnabledState = 1` 时，聚焦服务会把 `BackgroundType` 抢回 `3`、把壁纸换成 `IrisService` 缓存图。设为 `0` 后 `BackgroundType=2` 能稳定保持 90 秒，但**仍然不换图**（同第 2 点）。

### 5. 手动通过设置应用配置（对照实验）

用户手动在「设置 → 个性化 → 背景」选「幻灯片放映」，选文件夹 `C:\Users\Administrator\Pictures\Slideshow`：

- 关掉设置窗口再打开，背景回退为「图片」
- 观察 75 秒，壁纸不变，`LastTick` 仍为 0

**手动配置同样不工作**，排除「脚本写错键」这一可能。

### 6. PIDL 编码本身没问题

脚本用 `SHParseDisplayName` 取 PIDL、`ILGetSize` 算长度、`CryptBinaryToString(CRYPT_STRING_BASE64|NOCRLF)` 转 base64，生成的 384 字符值与 Windows 在手动配置时写入的值**逐字符一致**（`OgAfREcaA1lyP6dEicVVlf5rMO4m...`）。

关键坑：`SHITEMID.cb` 已包含自身 2 字节头，`ILGetSize` 必须累加 `cb` 而不是 `2 + cb`，否则会越界读到几万字节的垃圾数据。

## 决策

**不在本机继续尝试启用系统「幻灯片放映」。**

三条理由：

1. explorer 对幻灯片状态有内部校验，外部写入的配置会被判无效并回退，没有公开手段绕过。
2. 即使 `BackgroundType` 保持 2，切换定时器也不启动，`LastTick` 恒为 0。
3. 手动配置同样失效，说明是系统层面的组件缺失或损坏，不是脚本实现问题。

推断：这台 LTSC 上有大量系统优化痕迹（`ContentDeliveryManager` 下 `SubscribedContent-*` 全为 0、`ActiveDesktop\NoComponents=1`），幻灯片组件很可能被裁剪。

## 备选方案与取舍

| 方案 | 效果 | 代价 | 结论 |
|---|---|---|---|
| A. 脚本自管轮播（计划任务 + `SPI_SETDESKWALLPAPER` 换壁纸文件） | 桌面真实轮播 | 设置界面显示「图片」；需要关闭聚焦否则壁纸被抢 | 代码已实现，未采用 |
| B. 只维持 `BackgroundType=2` | 设置项显示「幻灯片放映」 | 不换图，纯状态装饰；且仍需关闭聚焦 | 不采用 |
| C. 放弃 | — | — | **采用** |

方案 A 的完整实现保留在本仓：`slideshow-guard.ps1`（检测、轮换、快照比对、日志）、`install.ps1`（部署 + 计划任务）、`uninstall.ps1`（卸载 + 按快照还原）、`run-hidden.vbs`（无窗口启动）。在同一台机器上实测换图有效（连续两次运行切到不同图片，`TranscodedWallpaper` 时间戳更新）。

## 后果

- 本机桌面恢复为最初的「Windows 聚焦」状态，脚本与计划任务已卸载。
- 本仓保留为实验记录与可复用实现，不用于生产部署。
- 用户如需「幻灯片放映」效果，只能手动设置；若发现被聚焦抢回，需先关闭聚焦。

## 下次接手前必须先验证的事

在动手写代码前，先用 30 秒确认这台机器上系统幻灯片是否可用：

```powershell
# 1. 手动设置幻灯片放映，间隔选 1 分钟
# 2. 等 2 分钟，然后看这两个值
Get-ItemProperty 'HKCU:\Control Panel\Personalization\Desktop Slideshow' |
    Select-Object LastTickLow, LastTickHigh, Interval
```

`LastTickLow/High` 若是 `0` 且壁纸没变，说明定时器没跑，本仓结论适用，不要重复投入。

如果目标机器的 `LastTick` 会随时间变化，说明系统幻灯片是好的，此时可以回到本仓代码，把「自管轮播」换回「写注册表 + 关闭聚焦」，其余骨架（检测、快照、卸载）可直接复用。

## 参考证据

- `docs/evidence/guard.log`：实验期间的完整运行日志
- 代码内 `ConvertTo-PidlBase64` 的注释记录了 `ILGetSize` 的坑
