# 清掉反复强杀进程留下的幽灵托盘图标：逐个点一下，explorer 发现对应进程已死就会把它摘掉。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class G {
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public uint pad; public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    static INPUT Mk(uint f) { INPUT i = new INPUT(); i.type = 0; i.dwFlags = f; return i; }
    public static void Click(int x, int y) {
        SetCursorPos(x, y); Thread.Sleep(300);
        INPUT[] a = new INPUT[] { Mk(0x0002), Mk(0x0004) };
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(600);
    }
}
'@
function Get-Icons {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $list = @()
    foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)) {
        if ($b.Current.Name -like '*桌面图标开关*') {
            $r = $b.Current.BoundingRectangle
            $list += ,@([Math]::Round($r.X + $r.Width/2), [Math]::Round($r.Y + $r.Height/2))
        }
    }
    return ,$list
}
for ($round = 1; $round -le 6; $round++) {
    $icons = Get-Icons
    $n = @($icons).Count
    "round $round : 托盘上有 $n 个我们的图标"
    if ($n -le 1) { break }
    $first = @($icons)[0]
    "  点一下 ($($first[0]),$($first[1])) 让 explorer 回收它"
    [G]::Click($first[0], $first[1])
    Start-Sleep -Milliseconds 800
}
$left = @(Get-Icons).Count
"剩余 = $left"
