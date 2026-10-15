# 隔离实验：不给托盘图标做右键，而是直接往后台实例的消息窗口投一条托盘回调消息
# （wParam=图标 id，lParam=WM_RBUTTONUP），让菜单在屏幕中间弹出来，再用 UIA 把菜单项列出来。
# 目的：分清"菜单代码自己有问题"和"托盘/抽屉交互有问题"。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class V {
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT {
        public uint type; public uint pad; public int dx; public int dy;
        public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int max);

    public static IntPtr Ipc() { return FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1"); }
    public static void Move(int x, int y) { SetCursorPos(x, y); System.Threading.Thread.Sleep(200); }

    /// legacy 格式：lParam 直接就是鼠标消息号
    public static bool NotifyLegacy(IntPtr ipc, uint mouseMsg) {
        return PostMessageW(ipc, 0x400, new IntPtr(1), new IntPtr((int)mouseMsg));
    }
    /// v4 格式：低 16 位是图标 id，高 16 位是鼠标消息号
    public static bool NotifyV4(IntPtr ipc, uint mouseMsg) {
        return PostMessageW(ipc, 0x400, new IntPtr(1), new IntPtr((int)(((mouseMsg & 0xFFFF) << 16) | 1)));
    }

    public static string ClassName(IntPtr h) {
        System.Text.StringBuilder sb = new System.Text.StringBuilder(64);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static void Esc() { keybd_event(0x1B, 0, 0, IntPtr.Zero); keybd_event(0x1B, 0, 2, IntPtr.Zero); }
    public static void LeftClick() {
        INPUT[] a = new INPUT[] { Mk(0x0002), Mk(0x0004) };
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }
    static INPUT Mk(uint f) { INPUT i = new INPUT(); i.type = 0; i.dwFlags = f; return i; }
}
'@

function Show-MenuItems([string]$tag) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)
    $found = 0
    foreach ($i in $items) {
        $r = $i.Current.BoundingRectangle
        if ($r.Width -gt 0 -and $r.Height -gt 0) {
            $found++
            "  [$tag] 项 #$found 类=$([V]::ClassName($i.Current.NativeWindowHandle)) 名=[$($i.Current.Name)] 位置=$([Math]::Round($r.X)),$([Math]::Round($r.Y)) 尺寸=$([Math]::Round($r.Width))x$([Math]::Round($r.Height))"
        }
    }
    if ($found -eq 0) { "  [$tag] 没枚举到菜单项" }
    return $found
}

$exe = "dist\DesktopIconToggle.exe"
Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
Start-Process $exe
Start-Sleep -Seconds 2
$ipc = [V]::Ipc()
"实例=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count) ipc=$ipc"

[V]::Move(960, 500)
"把光标放到 (960,500)，投一条 legacy 右键通知"
$null = [V]::NotifyLegacy($ipc, 517)   # 517 = 0x205 WM_RBUTTONUP
Start-Sleep -Milliseconds 900
"投完 0.9 秒后：进程数=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"
$n = Show-MenuItems "legacy"
Start-Sleep -Milliseconds 600
"再等 0.6 秒：进程数=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"
[V]::Esc()
Start-Sleep -Milliseconds 500
"Esc 之后：进程数=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"

if ($ipc -ne [IntPtr]::Zero -and @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) {
    ""
    "同样方式，v4 格式再投一次"
    $null = [V]::NotifyV4($ipc, 517)
    Start-Sleep -Milliseconds 900
    "投完：进程数=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"
    $null = Show-MenuItems "v4"
    [V]::Esc()
    Start-Sleep -Milliseconds 400
    "Esc 之后：进程数=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"
}
