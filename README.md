# 校园网自动认证脚本（Ruijie ePortal）

用一条 HTTP 请求代替"开浏览器、模拟点击"的校园网认证方式，可挂 Windows 计划任务无人值守运行——开机自动登录，掉线自动重连，全程无窗口、锁屏也能跑。

已在**上海大学（SHU）校园网**（锐捷 / Ruijie ePortal）验证可用。其它学校若也是锐捷 ePortal，可能只需改几个参数；具体看下面「适用范围」。

---

## 适用范围

先判断能不能直接用：断开校园网认证，随便打开一个网站，会被强制跳转到登录页。看网址：

- 网址是 `http://10.10.9.9/eportal/...` 开头，页面样子和"欢迎登录校园网"类似 → 大概率能直接用（比如你和这个仓库是同一所学校）。
- 网址是别的地址、页面完全不同 → 说明认证系统不一样（可能不是锐捷，或是锐捷但版本/配置不同），这份代码不能直接套用，需要重新分析对方系统的认证接口和加密方式再改。

## 使用方法

有两种拿去用的方式，任选：

**方式一：直接用仓库根目录的 [campus-net-api.ps1](campus-net-api.ps1)**（推荐给自己长期用）
把 WiFi 名和账号放进同目录下一个叫 `local.settings.ps1` 的文件（自己新建，不进版本库）：
```powershell
$WifiSSID = "你的WiFi名字"
$Account  = "你的校园网账号(学号)"
```
脚本启动时会自动加载这个文件覆盖默认值，本体代码不用改。

**方式二：拿 [精简版](精简版) 文件夹**（推荐转发给别人）
里面是脚本 + 静默启动器 + 一份从零讲起的使用说明（[精简版/使用说明.md](精简版/使用说明.md)），账号信息直接改在脚本参数里，5 步就能配好，文档里写清楚了每一步点哪、看什么。

不管哪种方式，配置好之后都要做两件事才算完整可用：

1. **存密码**（一次性）：
   ```powershell
   (Read-Host '校园网密码' -AsSecureString | ConvertFrom-SecureString) | Set-Content .\.campuspwd -Encoding ASCII
   ```
   密码会用 Windows 自带的 DPAPI 加密后存本地，只有这台电脑这个账号能解开。

2. **注册计划任务**（管理员 PowerShell，一次性）：
   ```powershell
   $vbs = "填入 launch-hidden.vbs 的完整路径"
   $act = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "//B //Nologo `"$vbs`""
   $t1  = New-ScheduledTaskTrigger -AtLogOn
   $t2  = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)
   $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
   Register-ScheduledTask -TaskName "CampusNetAutoLogin" -Action $act -Trigger $t1,$t2 -Settings $set -Description "校园网自动认证"
   ```
   之后开机登录 + 每 30 分钟会自动检查一次网络，已在线会立即退出，几乎不耗资源。

## 安全说明

- 密码通过 DPAPI 加密后存本地文件，脚本本体不含任何明文密码或个人信息。
- `.gitignore` 已排除本地私有配置、运行日志、加密密码文件，仓库内容已核对不含真实个人数据。
- 仅用于自动化本人已有合法权限的校园网认证登录，不涉及绕过认证或未授权访问。

## 免责声明

本项目基于对认证页面前端代码的公开分析实现，仅供个人自动化登录使用。不同学校 / 不同时期的认证系统实现可能不同，使用前请确认自己有合法的账号访问权限，并遵守所在学校的网络使用规定。
