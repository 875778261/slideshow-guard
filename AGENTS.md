# slideshow-guard

实验仓库：验证 Windows 10 桌面「幻灯片放映」能否脚本化。结论见 `docs/adr/0001-desktop-slideshow-not-scriptable.md`——本机不可行，代码保留但不用于部署。

## 动手前

先读 ADR。它记录了实测数据和「下次接手前必须先验证的 30 秒检查」，避免重复投入。

## 命令

```powershell
# 只读状态（不写日志、不改配置）
powershell -NoProfile -ExecutionPolicy Bypass -File .\slideshow-guard.ps1 -Status

# 只检测：轮播正常返回 0，否则 1
powershell -NoProfile -ExecutionPolicy Bypass -File .\slideshow-guard.ps1 -Check

# 立刻轮换一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\slideshow-guard.ps1 -Apply

# 安装 / 卸载（写 HKCU 与计划任务，不需要管理员）
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

没有 build 与测试套件。验证方式是跑 `-Status` 看「当前壁纸」与「上次轮换」是否变化，不看脚本自己打印的「成功」。

## 约束

- PowerShell 5.1 兼容（不使用 `??`、三元、`if` 表达式赋值）。
- `.ps1` 文件必须 UTF-8 **带 BOM**，否则 5.1 读中文会乱码。
- 只写 HKCU，不碰 HKLM，不要求管理员权限。
- 改动注册表前先拍快照，失败要能还原。

共享 skills 与跨仓文档在 `D:\workspace\home`。提交信息规范见 `D:\workspace\home\docs\standards\commit-convention.md`。
