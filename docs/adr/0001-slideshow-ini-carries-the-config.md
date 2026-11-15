# ADR-0001：幻灯片配置的唯一载体是 slideshow.ini，且它会被 SPI 清空

- Status: accepted
- Date: 2026-11-15
- Deciders: 用户、agent
- 取代：同日的废弃结论「Windows 10 桌面幻灯片无法脚本化」（错的，已删除）

## 背景

目标：脚本保证 Windows 10 桌面始终处于「幻灯片放映」模式并真实换图。

实测环境：Windows 10 企业版 LTSC `10.0.19044`，账户 `Administrator`，console 会话。

## 根因

`%APPDATA%\Microsoft\Windows\Themes\slideshow.ini` 被清空成 **0 字节**。

这个文件是幻灯片配置的唯一载体，内容只有两行：

```ini
[Slideshow]
ImagesRootPIDL=<base64，Windows 加密编码，534 字节，手工无法构造>
```

文件为 0 字节时，Windows 判定幻灯片配置无效，把 `BackgroundType` 回退为 0（图片）或 3（Windows 聚焦），设置界面显示也退回「图片」。

## 谁清空了它

绕开设置应用、直接调 `SystemParametersInfo(SPI_SETDESKWALLPAPER)` 设壁纸时，Windows 会把它清空。

实测记录：脚本执行锚定壁纸（SPI 设图库内一张图）后立即读取，`slideshow.ini` 从 829 字节变成 0 字节。反过来，只要不动壁纸文件，ini 就保持有效，幻灯片一直正常。

需要区分两种情况：

- **在设置里改壁纸再切回「幻灯片放映」**：设置应用会在切回时重建 ini，一切正常（用户实测确认）
- **直接设壁纸后不管**：ini 停在 0 字节，不会自己重建，幻灯片失效，直到重新配置或脚本还原

之前所有尝试都属于第二种：用 SPI 改了壁纸却没有重建步骤，于是每改一次就把配置清一次，无论怎么写注册表都通不过校验。

### 删除与清空不是一回事

| 操作 | `BackgroundType` | 轮播 |
|---|---|---|
| 清成 0 字节 | 被重置为 `0`（图片） | 停止 |
| 直接删除 | 保持 `2` | 当前会话继续，**重启 explorer 后停止** |

删除看起来"症状轻"，是因为 explorer 遇到缺失文件会跳过，而不是判定它损坏；但重启后没有配置可读，轮播照样停。实测删除后观察 5 分钟，文件没有被自动重建；恢复备份并重启 explorer 后，轮播在下一个整分钟恢复。

所以删除并不能替代备份：**这两种状态都必须靠还原备份修**。

## 证据

### 账户对比

| 项 | Administrator（故障） | lhl（正常） |
|---|---|---|
| `slideshow.ini` | 0 字节 | 743 字节，含 `ImagesRootPIDL` |
| `Custom.theme` | 无 `[Slideshow]` 段 | 有 `[Slideshow]` 段 |
| `Transcoded_000` | 不存在 | 存在 |

`lhl` 是新账户，从未用 SPI 设过壁纸，所以 ini 完好。

### 修复后

把有效的 ini 复制回 Administrator，`BackgroundType` 稳定为 2；用户手动把图库改到自己目录后，Windows 把 ini 重写为 829 字节（`ImagesRootPIDL` 第 3 个字符 `I`→`J`，指向新目录）。之后 `TranscodedWallpaper` 的大小按间隔变化：

```
21:02:47  589395 B  @21:02:00
21:03:02 2921381 B  @21:03:00   ← 换图
21:04:02  589395 B  @21:04:00   ← 换图
```

### 被推翻的旧判据

`Desktop Slideshow\LastTickLow/High` 全程恒为 `0`，即使轮播正常也不更新。它不是切换计数器，不能用来判断轮播是否工作。正确判据是 `TranscodedWallpaper` 的 `LastWriteTime`。

## 决策

**工具只做「备份 → 检测 → 恢复」，不生成幻灯片配置。**

理由：`ImagesRootPIDL` 由 Windows 加密编码（头两字节 `50 80`，`cb=32848` 不是合法 PIDL 长度），`SHGetNameFromIDList` 返回 `E_INVALIDARG`。没有公开手段构造，只能原样搬运。

修复动作固定为三步：

1. 若 `slideshow.ini` 为 0 字节或不存在，从备份还原（并设回 Hidden 属性）
2. 写 `BackgroundType=2`，缺 `Interval` 时补上
3. 有还原发生则重启 explorer，让它重新读取 ini

**不碰壁纸。** 实测确认：ini 有效时，当前壁纸指向 `TranscodedWallpaper` 还是其他位置都不影响轮播；而用 SPI 改壁纸反而会清空 ini。早期版本曾从图库选图"锚定"壁纸，属于多余动作，已移除。这也让脚本不再依赖任何图片目录，不存在需要管理员权限的路径。

## 约束

- 脚本自身不要用 SPI 改壁纸。改动后 ini 会被清空；绕开设置应用时不会自动重建，需要脚本还原或用户重新切一次「幻灯片放映」。
- 安装时必须先有一份有效的 `slideshow.ini`，否则中止并提示用户手动配置一次。工具无法凭空造出它。
- `TranscodedWallpaper` 视为合法壁纸状态，不算"不在图库内"。

## 已知限制

- 图库只有 1 张图时，幻灯片状态成立但不会换图（没有下一张）。此时需要至少 2 张图才能观察到变化。
- 恢复 ini 需要重启 explorer，登录后会闪一下任务栏。正常开机时 explorer 新启动、直接读有效 ini，不需要重启。
- 图库目录由安装时的 `libraryFolder` 指定，改了图库要在设置里重新配置一次幻灯片并重跑 `install.ps1 -Reconfigure`。

## 下次接手前的验证

```powershell
# 1. 确认 ini 有效
$ini = "$env:APPDATA\Microsoft\Windows\Themes\slideshow.ini"
(New-Object IO.FileInfo $ini).Length          # 应远大于 0，实测 829

# 2. 确认轮播在跑：间隔一分钟，隔 75 秒看两次尺寸/时间
$tw = New-Object IO.FileInfo "$env:APPDATA\Microsoft\Windows\Themes\TranscodedWallpaper"
"$($tw.Length) $($tw.LastWriteTime)"
```

`TranscodedWallpaper` 两次读取大小或时间不同，说明轮播正常。不要看 `LastTick`。
