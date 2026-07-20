# 项目变更日志

校园网自动认证脚本（锐捷 Ruijie ePortal）。目标：把原来"开浏览器 + 模拟点击"的认证方式，重构为"一条 HTTP 请求"的无人值守方案。

> 顺序说明：**按时间正序排列（开发开始 → 结束）**，最上面是最早的阶段。

---

## 阶段 1 · 2026-07-09 ~20:20 — 需求评审，确定技术路线

- **涉及文件**：`check-campus-net.ps1`（原方案，仅评审）
- **背景**：原脚本走 UI 自动化——打开 Edge → 用 UI Automation（UIA）按关键字找登录按钮 → 找不到就按像素坐标点击 / 猜 Tab 次数 + 回车。
- **指出的脆弱点**：
  1. `$PortalUrl` 把整条认证地址写死，其中 `wlanuserip`、`mac` 是会话级参数，重连后会变 → 迟早失效；
  2. UIA 关键字用的是拼音（`denglu`/`huanying`），而页面元素 `Name` 是中文，**永远匹配不到**，实际每次都退化成"盲按 Tab+回车"；
  3. 像素偏移 `$rect.Top + 280` 依赖分辨率 / DPI 缩放；
  4. 依赖**交互式桌面**（必须有人登录、屏幕解锁），无法在锁屏 / 计划任务后台下工作。
- **结论**：目标是"无人值守"，UI 方案根本上不适合。改为**纯 HTTP API 认证**（无浏览器、无窗口、无点击），锁屏 / 登录界面下也能跑。

## 阶段 2 · 2026-07-09 ~20:40 — 逆向认证页，锁定接口与加密

- **涉及文件（分析）**：`上网认证.html`、`上网认证_files/AuthInterFace.js`、`login_bch.js`、`security.js`
- **从源码确认的事实**：
  - 登录接口：`POST http://10.10.9.9/eportal/InterFace.do?method=login`（**80 端口**；页面里的 `:8080` 只是图片资源）；
  - 表单字段：`userId, password, service, queryString, operatorPwd, operatorUserId, validcode, passwordEncrypt`；
  - 页面隐藏域 `passwordEncrypt` 默认 `true` → **服务器强制密码加密**；
  - 加密流程（逆向自 `login_bch.js` + `AuthInterFace.js` + `security.js`）：`RSA( reverse( 明文密码 + ">" + mac ) )`，分块、十六进制、空格分隔；
  - RSA 公钥：指数 `e=0x10001`，模数 `n` 为 1024 位十六进制（页面隐藏域 `publicKeyModulus`）。
- **原因**：为 HTTP 重写取得准确依据，避免照抄锐捷默认参数。

## 阶段 3 · 2026-07-09 ~21:00 — 首版 HTTP API 脚本

- **涉及文件**：`campus-net-api.ps1`（新增）
- **实现**：
  - 用 .NET `System.Numerics.BigInteger` 复刻 `security.js` 的自定义 RSA（`Invoke-RuijieRSA`）：字符 → 字节 → 补零到 `chunkSize` 整数倍 → 每块小端打包成大整数 → \( m^e \bmod n \) → 十六进制；
  - `Get-RedirectQueryString` 抓网关重定向拿实时 queryString；`Test-Online` 预检；重试与日志轮转；
  - 密码用 Windows DPAPI 存到 `.campuspwd`，脚本内解密，不留明文。
- **离线验证**：RSA 段自测——同输入两次输出一致（确定性），单块 256 位十六进制、`chunkSize=126` 符合预期。

## 阶段 4 · 2026-07-09 ~21:15 — 修复文件编码（UTF-8 BOM）

- **涉及文件**：`campus-net-api.ps1`
- **现象**：`Parser::ParseFile` 报一堆莫名其妙的语法错（行号对不上、冒出源码里没有的 `&`、`[`）。
- **根因**：系统 ANSI 代码页是 936（GBK）。脚本存成 UTF-8 **无 BOM** 时，PowerShell 5.1 误按 GBK 解码，中文注释的字节被拆错，殃及后续解析。
- **修复**：脚本改存 **UTF-8 with BOM**（开头 `EF BB BF` 三字节让 PS 识别为 UTF-8）。改后 `ParseFile` 通过。此后每次编辑都重新写回 BOM。

## 阶段 5 · 2026-07-09 ~21:30 — 修复重定向抓取（byte[] 解码）

- **涉及文件**：`campus-net-api.ps1`（`Get-RedirectQueryString`）；新增 `diag-portal.ps1` 诊断
- **现象**：注销状态下 6 次重试全部"未拿到重定向 queryString"。
- **诊断**：`diag-portal.ps1` 打印各探测地址的真实响应，发现网关对 `http://123.123.123.123/` 等返回的是 `200 + 一段 JS 跳转正文`，但**响应无 `Content-Type` 头**，导致 `Invoke-WebRequest -UseBasicParsing` 把 `.Content` 当成**字节数组（byte[]）**而非字符串；旧代码在 byte[] 上跑正则（表现为 `60 115 99 ...` 这串数字），永远匹配不到 `index.jsp`。
- **修复**：`if ($r.Content -is [byte[]]) { 解码成 ASCII 字符串 }` 后再正则。探测地址精简为 `123.123.123.123` 与 `baidu.com`（`msftconnecttest` 在该网络返回 502）。

## 阶段 6 · 2026-07-09 ~21:56 — 修正账号与 service（抓包比对）

- **涉及文件**：`campus-net-api.ps1`
- **现象**：能拿到 queryString、走到登录，但服务器返回 `密码错误`（日志里是乱码 `å¯ç éè¯¯`，按 UTF-8 读回即"密码错误"）。手动浏览器登录却成功。
- **诊断**：用浏览器 F12 → Network 抓到**成功登录的真实 POST 表单**，逐字段比对，发现两处不符：
  - `userId`：脚本里的账号多打了一位（9 位）≠ 浏览器抓包里的真实账号（8 位）；
  - `service`：脚本空 ≠ 浏览器 `shu`（校园网）。
- **同时离线证明 RSA 无误**：用抓包里的 mac 与公钥算出密文，和浏览器 `password` 字段**逐字节完全一致**——排除加密问题，锁定是账号 / service。
- **修复**：`$Account` 改为正确的 8 位账号、`$Service = "shu"`（用户确认账号确为 8 位）。

## 阶段 7 · 2026-07-09 ~22:04 — 修复 queryString 被空格截断

- **涉及文件**：`campus-net-api.ps1`（`Get-RedirectQueryString`）
- **现象**：账号 / service 改对后仍"密码错误"。
- **诊断**：加 `DBG body=` 日志，把脚本实发的表单和浏览器抓包逐字段比，发现 `queryString` 我们的在 `nasportid=TenGigabitEthernet` 处**戛然而止**，浏览器的后面还有 `%2525202%252F4%252F28.04020000%253A402-0`。根因：网关跳转 URL 里 `nasportid=TenGigabitEthernet 2/4/28...` 含一个**真实空格**，旧正则 `[^...\s...]` 遇空格即停 → 截断。
- **修复**：正则改为"到引号才停"`([^'"<>\r\n]+)`，捕获后把真实空格补成 `%20`（匹配浏览器地址栏规范化）。离线验证：修后编码结果与浏览器 queryString 逐字节一致。

## 阶段 8 · 2026-07-09 ~22:12 — 尝试会话/Cookie 与请求头（未解决）

- **涉及文件**：`campus-net-api.ps1`
- **现象**：请求体已和浏览器**逐字节相同**，仍"密码错误"。
- **尝试**：(a) 预建 `WebSession`，先 `GET index.jsp` 拿 `JSESSIONID`，pageInfo/login 共享 Cookie（`cookies=1` 拿到了，仍失败）；(b) 补浏览器 `User-Agent` + `Origin` + `Referer`（仍失败）。
- **结论**：差异不在请求内容，而在传输层——但 `Invoke-WebRequest` 具体哪里不对还不确定，需要"标准答案"对照。

## 阶段 9 · 2026-07-09 ~22:30 — 定位真凶并改用 curl.exe（成功）

- **涉及文件**：`campus-net-api.ps1`
- **决定性证据**：让用户把浏览器成功请求"Copy as cURL"，**原样用 `curl.exe` 重放 → 成功**。证明请求完全可复现，问题出在 `Invoke-WebRequest` 本身对 `Referer` 等**受限请求头（restricted headers）**的处理与浏览器 / curl 不一致，被服务器判为无效。
- **修复**：登录整段改用 `curl.exe`（Win10 自带 `C:\Windows\System32\curl.exe`）：先 `GET index.jsp` 取 `JSESSIONID`，再原样复刻浏览器 Cookie（`EPORTAL_COOKIE_*`）与请求头 POST 登录。同时移除已不需要的 pageInfo 调用（公钥用已验证的静态值）。
- **验证**：注销后运行 → `resp: {"result":"success",...}` + `SUCCESS`。

## 阶段 10 · 2026-07-09 ~22:41 — 收尾：DPAPI + 计划任务

- **涉及文件**：`campus-net-api.ps1`
- **改动**：
  - 去掉调试阶段临时写死的明文密码，`$Password` 置空 → 走 `.campuspwd`（DPAPI）；
  - 修正过时注释（pageInfo 已移除、公钥更新说明、计划任务触发方式）；
  - 注册 Windows 计划任务 `CampusNetAutoLogin`：开机登录 + 每 30 分钟轮询（校园网每天掉线时 WiFi 不断、不触发联网事件，故用轮询兜底；`Test-Online` 预检使已在线时秒退）。
- **最终验证**：DPAPI 路径登录 `SUCCESS`；`Start-ScheduledTask` 手动触发后 `LastTaskResult=0`、日志有新记录。**全部完成。**

## 阶段 11 · 2026-07-10 ~10:18 — 代码审查加固（curl 超时 / 验证码检测 / 注释路径）

- **涉及文件**：`campus-net-api.ps1`
- **背景**：全量代码审查。核心链路（RSA 分块/字节序/补零、`password+">"+mac` 反转、双重 URL 编码、Cookie 复刻）对照 security.js / login_bch.js / AuthInterFace.js 逐项核验一致，不动；修掉三个健壮性问题。
- **改动**：
  - 两处 `curl.exe` 加 `--max-time 10`：portal 半挂起（TCP 通、应用层无响应）时 curl 默认可挂数分钟，一次挂起就吃光计划任务 3 分钟的 ExecutionTimeLimit；
  - 删除死分支 `if ($res -eq "CAPTCHA")`（任何代码路径都不会返回该字符串），改为匹配响应 JSON 里 `validCodeUrl` 非空（login_bch.js:847 确认这是服务器要求验证码的信号），命中即记日志并 `exit 3`，不再盲目重试；
  - 文末注册命令注释里 `$PSScriptRoot` 改为写死完整路径：交互式窗口里 `$PSScriptRoot` 为空，照抄会注册出指向 `\campus-net-api.ps1` 的坏任务。
- **验证**：语法解析通过；`validCodeUrl` 正则用含验证码/不含/成功三种样例响应测试全对；`--max-time` 按脚本同款调用方式实测 exit 0；实跑改后脚本 → `已在线，退出`、exit 0。

## 阶段 12 · 2026-07-10 ~10:26 — 计划任务改为完全静默（不弹窗、不抢前台）

- **涉及文件**：`launch-hidden.vbs`（新增）、`campus-net-api.ps1`（仅注册命令注释）
- **现象**：计划任务每 30 分钟运行时弹出黑窗并抢占前台。
- **根因**：`powershell.exe` 是控制台程序，`-WindowStyle Hidden` 的机制是"先建窗、再隐藏"；Win11 22H2 上 Windows Terminal 为默认终端时更是无视该参数，窗口直接弹到前台。
- **修复**：新增 `launch-hidden.vbs`——`wscript.exe` 是 GUI 程序、不带控制台，用 `Run(..., 0, True)` 让 powershell 的窗口"创建即隐藏"，并把脚本退出码原样传回计划任务（`WScript.Quit code`，LastTaskResult 语义不变）。计划任务动作改为 `wscript.exe //B //Nologo "launch-hidden.vbs 完整路径"`，触发器/时限等其余设置未动。
- **验证**：直接以 wscript 方式实跑 → exit 0、日志正常，运行期间轮询 powershell/WindowsTerminal/conhost 等进程的 `MainWindowHandle` 全程为 0（无任何可见窗口）；`Start-ScheduledTask` 触发生产任务 → `LastTaskResult=0`、日志 `已在线，退出`、同样零可见窗口。

## 阶段 13 · 2026-07-10 ~10:31 — 归档旧脚本

- **涉及文件**：`check-campus-net.ps1` → `上网认证_files/check-campus-net.ps1`（纯移动，内容未变，已核对哈希一致）
- **说明**：旧 UI 自动化版脚本仅存参考、不再维护（代码审查已确认其 `Add-Type` 参数集冲突导致无法运行），归档进参考资料目录，项目根目录只留在用的 `campus-net-api.ps1` 及配套文件。

---

## 关键经验（跨阶段）

- **"密码错误"是笼统报错**，实际根因跑遍了账号、service、queryString 截断、传输层四个层面。
- **抓"已知成功的真实请求"当标准答案**（浏览器 F12 → Copy as cURL），逐字段比对，是定位这类问题最快的手段。
- **能离线证明的绝不上网试**：RSA 是否正确，用浏览器密文逐字节比对即可（该 RSA 无随机填充、确定性）。
- **分层排除**：先证明请求体一致（排除内容）→ 再定位传输层（Cookie / 受限头）→ curl 重放证明可复现 → 锁定是 PowerShell 工具本身。
