# ============================================================
#  Campus Network HTTP-API Login  (Ruijie ePortal) —— 无人值守版
#  无浏览器/无窗口/无模拟点击，锁屏与登录界面下均可运行
#
#  ⚠ 使用前必读：下面 $WifiSSID 和 $Account 两处是占位符，必须改成你自己的，
#     否则脚本会尝试连接一个不存在的 WiFi、用一个不存在的账号登录，直接失败。
#     其余参数（$Service / $PortalHost / $PubExp / $PubMod）是这所学校认证系统
#     本身的公共设置，全校通用，不用改。
#
#  首次使用先存密码（本机 PowerShell 里执行一次即可，具体见配套的《使用说明.md》）：
#    (Read-Host '校园网密码' -AsSecureString | ConvertFrom-SecureString) |
#        Set-Content (Join-Path $PSScriptRoot '.campuspwd') -Encoding ASCII
#  DPAPI 按"当前用户"加密，所以计划任务必须以同一账号运行。
# ============================================================
param(
    [string]$WifiSSID   = "改成你的WiFi名字",              # ← 必改
    [string]$Account    = "改成你的校园网账号(学号)",       # ← 必改
    [string]$Password   = "",                         # 留空则读 .campuspwd(DPAPI)，不要在这里写明文密码
    [string]$Service    = "shu",                      # 全校统一，不用改
    [string]$PortalHost = "10.10.9.9",                # 全校统一，不用改
    # RSA 公钥：这所学校认证服务器的公开"锁头"，全校所有账号通用，不用改。
    [string]$PubExp     = "10001",
    [string]$PubMod     = "94dd2a8675fb779e6b9f7103698634cd400f27a154afa67af6166a43fc26417222a79506d34cacc7641946abda1785b7acf9910ad6a0978c91ec84d40b71d2891379af19ffb333e7517e390bd26ac312fe940c340466b4a5d4af1d65c3b5944078f96a1a51a5a53e4bc302818b7c9f63c4a1b07bd7d874cef1c3d4b2f5eb7871",
    [int]$MaxRetry      = 6,
    [switch]$Plain                                    # 发明文密码(passwordEncrypt=false)，不走 RSA
)

$ErrorActionPreference = "Stop"
$logFile = Join-Path $PSScriptRoot "campus-net-log.txt"

# 日志轮转：超过 1MB 截半
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
    $keep = Get-Content $logFile -Tail 500
    Set-Content $logFile $keep -Encoding UTF8
}
function Write-Log($m){ "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | $m" | Out-File -Append $logFile -Encoding UTF8 }

# ---------- 取密码（DPAPI） ----------
if (-not $Password) {
    $pwdFile = Join-Path $PSScriptRoot ".campuspwd"
    if (-not (Test-Path $pwdFile)) { Write-Log "ERROR: 未提供 -Password 且缺少 $pwdFile"; exit 2 }
    try {
        $sec = Get-Content $pwdFile | ConvertTo-SecureString      # 当前用户 DPAPI
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    } catch { Write-Log "ERROR: 解密 .campuspwd 失败（是否与计划任务运行账号不一致？）: $_"; exit 2 }
}

# ---------- 锐捷自定义 RSA：复刻 security.js 的 encryptedString ----------
function Invoke-RuijieRSA {
    param([string]$PlainText, [string]$ExpHex, [string]$ModHex)
    $e = [System.Numerics.BigInteger]::Parse("0" + $ExpHex, 'HexNumber')
    $n = [System.Numerics.BigInteger]::Parse("0" + $ModHex, 'HexNumber')
    $digits    = [math]::Ceiling($ModHex.Length / 4.0)
    $chunkSize = 2 * ($digits - 1)                                # security.js: 2*biHighIndex(m)，字节
    $bytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($ch in $PlainText.ToCharArray()) { $bytes.Add([byte][int]$ch) }
    while ($bytes.Count % $chunkSize -ne 0) { $bytes.Add(0) }
    $arr = $bytes.ToArray()
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $arr.Length; $i += $chunkSize) {
        $chunk = New-Object byte[] ($chunkSize + 1)              # +1 末位 0 保证正数
        [Array]::Copy($arr, $i, $chunk, 0, $chunkSize)
        $block = [System.Numerics.BigInteger]::new($chunk)       # 小端无符号
        $crypt = [System.Numerics.BigInteger]::ModPow($block, $e, $n)
        $hex   = $crypt.ToString("x").TrimStart('0'); if ($hex -eq "") { $hex = "0" }
        $out.Add($hex)
    }
    return ($out -join " ")
}

# ---------- 已在线预检 ----------
function Test-Online {
    try {
        (Invoke-WebRequest "http://www.msftconnecttest.com/connecttest.txt" `
            -UseBasicParsing -TimeoutSec 5).Content.Trim() -eq "Microsoft Connect Test"
    } catch { $false }
}

# ---------- 抓网关重定向的实时 queryString ----------
function Get-RedirectQueryString {
    foreach ($probe in @("http://123.123.123.123/", "http://www.baidu.com/")) {
        $blob = ""
        try {
            $r = Invoke-WebRequest $probe -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 8
            # 网关重定向响应常无 Content-Type，$r.Content 会是 byte[]，必须手动解码成字符串
            if ($r.Content -is [byte[]]) { $blob = [System.Text.Encoding]::ASCII.GetString($r.Content) }
            else { $blob = [string]$r.Content }
            if ($r.Headers.Location) { $blob += " " + $r.Headers.Location }
        } catch {
            try { $blob = [string]$_.Exception.Response.Headers['Location'] } catch {}
        }
        # 到引号才停(nasportid 里含真实空格，不能用 \s 截断)，再把空格补成 %20 匹配浏览器规范化
        if ($blob -match "index\.jsp\?([^'""<>\r\n]+)") { return ($Matches[1] -replace ' ', '%20') }
    }
    return $null
}

# ---------- 单次登录尝试 ----------
function Try-Login {
    $qs = Get-RedirectQueryString
    if (-not $qs) { Write-Log "  未拿到重定向 queryString（网络未就绪或已在线）"; return $null }
    $mac = if ($qs -match "(?:^|&)mac=([^&]*)") { $Matches[1] } else { "111111111" }

    if ($Plain) {
        $encPwd = $Password          # 明文，不加 >mac、不加密
        $pwEnc  = "false"
    } else {
        $plain    = ($Password + ">" + $mac)
        $reversed = -join ($plain.ToCharArray()[($plain.Length-1)..0])
        $encPwd   = Invoke-RuijieRSA -PlainText $reversed -ExpHex $PubExp -ModHex $PubMod
        $pwEnc    = "true"
    }
    function Enc2([string]$s){ [uri]::EscapeDataString([uri]::EscapeDataString($s)) }
    $body = "userId=" + (Enc2 $Account) + "&password=" + (Enc2 $encPwd) + "&service=" + (Enc2 $Service) +
            "&queryString=" + (Enc2 $qs) + "&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=$pwEnc"

    # 用 curl.exe 复刻浏览器请求（Invoke-WebRequest 对 Referer 等受限头/cookie 处理不一致，会被判"密码错误"）
    $ref = "http://$PortalHost/eportal/index.jsp?$qs"
    # 1) GET index.jsp 拿新 JSESSIONID
    $hdr  = (& curl.exe -s --max-time 10 -D - $ref -o NUL 2>$null) -join "`n"
    $jsid = if ($hdr -match "JSESSIONID=([^;\s]+)") { $Matches[1] } else { "" }
    # 2) 复刻浏览器 cookie（记住密码写入的那批）+ JSESSIONID
    $ck = "EPORTAL_COOKIE_USERNAME=$Account; EPORTAL_COOKIE_DOMAIN=false; EPORTAL_COOKIE_OPERATORPWD=; EPORTAL_COOKIE_NEWV=true; EPORTAL_AUTO_LAND=; EPORTAL_COOKIE_PASSWORD=$encPwd; EPORTAL_COOKIE_SERVER=$Service; EPORTAL_COOKIE_SERVER_NAME=%E6%A0%A1%E5%9B%AD%E7%BD%91; EPORTAL_USER_GROUP=root"
    if ($jsid) { $ck = "$ck; JSESSIONID=$jsid" }
    # 3) 登录
    $resp = (& curl.exe -s --max-time 10 "http://$PortalHost/eportal/InterFace.do?method=login" `
        -H "Accept: */*" -H "Accept-Language: zh-CN,zh;q=0.9" `
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" `
        -H "Origin: http://$PortalHost" -H "Referer: $ref" `
        -b $ck --data-raw $body 2>$null) -join "`n"
    Write-Log "  DBG mac=$mac  jsid=$(if($jsid){'yes'}else{'no'})  enc=$pwEnc"
    Write-Log "  resp: $resp"
    return $resp
}

# ================= 主流程 =================
Write-Log "===== login start ====="

# WiFi
$ifc = netsh wlan show interfaces | Out-String
$cur = if ($ifc -match "(?m)^\s*SSID\s*:\s*(.+)$") { $Matches[1].Trim() } else { "" }
if ($cur -ne $WifiSSID) {
    netsh wlan connect name="$WifiSSID" | Out-Null
    Start-Sleep 4
}

for ($i = 1; $i -le $MaxRetry; $i++) {
    if (Test-Online) { Write-Log "已在线，退出"; exit 0 }
    Write-Log "尝试 $i/$MaxRetry"
    $res = Try-Login
    if ($res -match '"result"\s*:\s*"success"') { Write-Log "SUCCESS"; exit 0 }
    if ($res -match '"message"\s*:\s*"([^"]*)"') { Write-Log "  fail: $($Matches[1])" }
    # 登录失败响应里 validCodeUrl 非空 = 服务器要求验证码，无人值守输不了，重试无意义
    if ($res -match '"validCodeUrl"\s*:\s*"[^"]+"') { Write-Log "  服务器要求验证码，退出（请手动登录一次以清除验证码状态）"; exit 3 }
    Start-Sleep 5
}
Write-Log "FAIL: 重试耗尽"
exit 1
