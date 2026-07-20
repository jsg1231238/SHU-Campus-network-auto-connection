' ============================================================
'  计划任务静默启动器 —— 解决 powershell.exe 每 30 分钟弹黑窗/抢前台。
'  原因：powershell 是控制台程序，-WindowStyle Hidden 是"先建窗再隐藏"；
'        Win11 下 Windows Terminal 为默认终端时更是直接无视该参数，窗口弹到前台。
'  办法：wscript 是 GUI 程序、不带控制台；Run(...,0,True) 让 powershell 的窗口
'        从创建那一刻就是隐藏的，全程无任何窗口，并把脚本退出码原样传给计划任务。
'  计划任务动作应为：wscript.exe //B //Nologo "本文件完整路径"
' ============================================================
Set sh = CreateObject("WScript.Shell")
code = sh.Run("powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File ""E:\claude-work\20260709_netconnect\campus-net-api.ps1""", 0, True)
WScript.Quit code
