' ============================================================
'  计划任务静默启动器 —— 解决 powershell.exe 每次运行弹黑窗/抢前台的问题。
'  原理：powershell 是"控制台程序"，-WindowStyle Hidden 只是"先建窗再隐藏"，
'        某些系统下窗口仍会闪一下甚至抢到前台；wscript 是"GUI 程序"，不带控制台，
'        用 Run(...,0,True) 能让 powershell 的窗口从创建那一刻起就是隐藏的。
'
'  这个文件会自动找到自己所在的文件夹，去里面找 campus-net-api.ps1 ——
'  所以只要这两个文件放在同一个文件夹里，你不需要修改这个文件的任何内容。
' ============================================================
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path   = scriptDir & "\campus-net-api.ps1"

Set sh = CreateObject("WScript.Shell")
code = sh.Run("powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File """ & ps1Path & """", 0, True)
WScript.Quit code
