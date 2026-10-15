# 对比：强杀进程 vs 正常 --exit，之后托盘区还剩几个我们的图标
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Drawing, System.Windows.Forms
function Count-Tray {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $n = 0
    foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)) {
        if ($b.Current.Name -like '*桌面图标开关*') { $n++ }
    }
    return $n
}
"当前托盘图标数（此前多次强杀累积）= $(Count-Tray)"
Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
"强杀之后再数 = $(Count-Tray)"
Start-Process "dist\DesktopIconToggle.exe"; Start-Sleep -Seconds 2
"重新启动后 = $(Count-Tray)"
$o="$env:TEMP\e.txt"; Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--exit" -NoNewWindow -Wait -RedirectStandardOutput $o
([IO.File]::ReadAllText($o) -split "`n" | Where-Object { $_ -match '退出|exit' })
Start-Sleep -Seconds 3
"正常 --exit 之后 = $(Count-Tray)（应为 0 或不变，说明正常退出会自己摘掉图标）"
$b=[System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp=New-Object System.Drawing.Bitmap 500,80
$g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen(1560,1140,0,0,$bmp.Size); $g.Dispose()
$bmp.Save("$PWD\shots\tray-now.png",[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
"截图 shots\tray-now.png"
