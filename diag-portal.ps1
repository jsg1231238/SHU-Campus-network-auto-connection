# Portal redirect diagnostic - run while NOT authenticated (browser shows login page)
$ProgressPreference = 'SilentlyContinue'

"===== 1. WiFi / IP ====="
(netsh wlan show interfaces) | Select-String -Pattern "SSID","State","状态" | ForEach-Object { $_.Line.Trim() }
(ipconfig) | Select-String -Pattern "IPv4","Gateway","网关" | ForEach-Object { $_.Line.Trim() }

"`n===== 2. Real gateway responses ====="
$probes = @(
    "http://www.baidu.com/",
    "http://captive.apple.com/",
    "http://www.msftconnecttest.com/redirect",
    "http://123.123.123.123/",
    "http://10.10.9.9/"
)
foreach ($u in $probes) {
    "`n--- $u ---"
    try {
        $r = Invoke-WebRequest $u -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 8
        "STATUS  : $($r.StatusCode)"
        "LOCATION: $($r.Headers.Location)"
        $c = [string]$r.Content
        if ($c) { "CONTENT : " + (($c.Substring(0,[Math]::Min(500,$c.Length))) -replace "\s+"," ") }
    } catch {
        "EXCEPTION: $($_.Exception.Message)"
        $resp = $_.Exception.Response
        if ($resp) {
            try { "EX-STATUS  : $([int]$resp.StatusCode)" } catch {}
            try { "EX-LOCATION: $($resp.Headers['Location'])" } catch {}
        }
    }
}
"`n===== done ====="
