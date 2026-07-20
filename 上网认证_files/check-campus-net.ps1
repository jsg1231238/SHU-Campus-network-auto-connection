# ============================================================
#  Campus Network Auto-Check & Reconnect Script
#  v3.3 - Portable: change CONFIG section for other computers
# ============================================================
#
#  迁移到其他电脑只需要改下面 ===== CONFIG ===== 部分：
#    1. WiFi名称
#    2. Portal认证页面URL（断开网后浏览器自动跳转的那个地址）
#    3. 你的校园网账号（用于检测登录成功）
#
#  定时任务注册命令（管理员PowerShell）:
#    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"<脚本路径>`""
#    $trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
#    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
#    Register-ScheduledTask -TaskName "CampusNetAutoLogin" -Action $action -Trigger $trigger -Settings $settings -Description "校园网自动认证"
# ============================================================

param(
    # ===== CONFIG - 换电脑改这三个 =====
    [string]$WifiSSID = "改成你的WiFi名字",
    [string]$PortalUrl = "http://10.10.9.9/eportal/index.jsp?wlanuserip=改成掉线时网关分配给你的IP&wlanacname=YC_RG-N18012-Co&ssid=&nasip=172.18.2.117&snmpagentip=&mac=改成你网卡的MAC地址&t=wireless-v2-plain&url=http://123.123.123.123/&apmac=&nasid=YC_RG-N18012-Co&vid=402&port=72&nasportid=TenGigabitEthernet%202/4/28.04020000:402-0",
    [string]$SuccessAccount = "改成你的校园网账号(学号)",
    # ================================
    [int]$PageLoadWait = 6
)

$logFile = Join-Path $PSScriptRoot "campus-net-log.txt"
$statusFile = [Environment]::GetFolderPath("Desktop") + "\校园网认证状态.txt"
$browserProc = "msedge"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
}
"@ -Name "WinAPI" -PassThru

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts | $msg" | Out-File -Append -FilePath $logFile -Encoding UTF8
}

function Write-Status($status, $detail) {
    @"
========================================
  校园网自动认证状态
========================================
  最后运行: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  结果:     $status
  详情:     $detail
  WiFi:     $WifiSSID
========================================
"@ | Set-Content -Path $statusFile -Encoding UTF8
}

function Show-Toast($title, $message) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.SystemIcons]::Information
        $balloon.BalloonTipTitle = $title
        $balloon.BalloonTipText = $message
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(5000)
        Start-Sleep -Seconds 6
        $balloon.Dispose()
    } catch {}
}

function Click-At($x, $y) {
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
    Start-Sleep -Milliseconds 100
    [WinAPI]::mouse_event(0x0002, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 50
    [WinAPI]::mouse_event(0x0004, 0, 0, 0, 0)
}

function Focus-Window($hwnd) {
    if ([WinAPI]::IsIconic($hwnd)) { [WinAPI]::ShowWindow($hwnd, 9) | Out-Null }
    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
    [WinAPI]::BringWindowToTop($hwnd) | Out-Null
    Start-Sleep -Milliseconds 300
}

function Test-LoginSuccess($hwnd) {
    Focus-Window $hwnd
    Start-Sleep -Milliseconds 500

    $windowEl = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if (-not $windowEl) { return $false }

    $allEls = $windowEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    if (-not $allEls) { return $false }

    $kws = @($SuccessAccount, "huan ying", "huanying", "success", "cheng gong", "chenggong")

    foreach ($el in $allEls) {
        $name = $el.Current.Name
        if (-not $name) { continue }
        foreach ($kw in $kws) {
            if ($name.ToLower().Contains($kw)) {
                Write-Log "Login success: '$name'"
                return $true
            }
        }
    }
    return $false
}

# ====== Step 0: WiFi ======
Write-Log "===== Campus Net Check v3.3 ====="

$wifiInfo = netsh wlan show interfaces 2>&1 | Out-String
$currentSSID = ""
if ($wifiInfo -match "SSID\s*:\s*(.+)") { $currentSSID = $Matches[1].Trim() }

if ($currentSSID -ne $WifiSSID) {
    Write-Log "Connecting WiFi '$WifiSSID'..."
    netsh wlan connect name="$WifiSSID" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}
Write-Log "WiFi OK ($currentSSID)"
Start-Sleep -Seconds 2

# ====== Step 1: Open portal ======
$edgePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edgePath)) { $edgePath = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
if (-not (Test-Path $edgePath)) { $edgePath = "msedge" }

Start-Process -FilePath $edgePath -ArgumentList "--new-window", $PortalUrl
Write-Log "Portal page opened"
Start-Sleep -Seconds $PageLoadWait

# ====== Step 2: Find window ======
$procs = Get-Process -Name $browserProc -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowTitle -ne "" } |
         Sort-Object -Property StartTime -Descending |
         Select-Object -First 1

if (-not $procs) {
    Write-Log "ERROR: no browser window"
    Write-Status "失败" "浏览器窗口未找到"
    Show-Toast "校园网认证" "失败 - 浏览器未打开"
    exit 1
}
$hwnd = $procs.MainWindowHandle

if (Test-LoginSuccess $hwnd) {
    Write-Log "Already logged in"
    Write-Status "已连接(无需操作)" "页面显示已登录"
    exit 0
}

# ====== Step 3: Click login ======
$rect = New-Object RECT; [WinAPI]::GetWindowRect($hwnd, [ref]$rect)
$cx = $rect.Left + [int](($rect.Right - $rect.Left) / 2)
$fy = $rect.Top + 280

Focus-Window $hwnd
$clicked = $false

$windowEl = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
if ($windowEl) {
    $types = @([System.Windows.Automation.ControlType]::Button,
               [System.Windows.Automation.ControlType]::Hyperlink,
               [System.Windows.Automation.ControlType]::Text,
               [System.Windows.Automation.ControlType]::Custom)
    $kws = @("lianjie","lian jie","denglu","deng lu","login","connect","queren","que ren")

    foreach ($t in $types) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $t)
        $els = $windowEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($els) {
            foreach ($el in $els) {
                $n = $el.Current.Name; if (-not $n) { continue }
                foreach ($kw in $kws) {
                    if ($n.ToLower().Contains($kw) -and $el.Current.IsEnabled) {
                        try { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $clicked = $true } catch {}
                        if (-not $clicked) {
                            $r2 = $el.Current.BoundingRectangle
                            if ($r2.Width -gt 0) { Click-At ([int]($r2.X+$r2.Width/2)) ([int]($r2.Y+$r2.Height/2)); $clicked = $true }
                        }
                        if ($clicked) { Write-Log "UIA clicked: '$n'"; break }
                    }
                }
                if ($clicked) { break }
            }
        }
        if ($clicked) { break }
    }
}

if (-not $clicked) {
    Write-Log "UIA no match, SendKeys fallback"
    foreach ($tabN in @(2, 3, 4, 5)) {
        Click-At $cx $fy; Start-Sleep -Milliseconds 200
        for ($i = 0; $i -lt $tabN; $i++) {
            [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
            Start-Sleep -Milliseconds 150
        }
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
        Start-Sleep -Seconds 2
        if (Test-LoginSuccess $hwnd) { Write-Log "OK: Tab x $tabN + Enter"; $clicked = $true; break }
    }
}

# ====== Step 4: Result ======
Start-Sleep -Seconds 2
if (Test-LoginSuccess $hwnd) {
    Write-Log "SUCCESS"
    Write-Status "认证成功" "校园网已连接"
    Show-Toast "校园网认证" "认证成功 - 网络已恢复"
    exit 0
} else {
    Write-Log "FAIL"
    Write-Status "认证失败" "请手动检查 - 打开浏览器查看portal页面"
    Show-Toast "校园网认证" "认证失败 - 请手动登录"
    exit 1
}
