# 一次性诊断：IPC 窗口找不找得到、光标在哪、全屏截图
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class S {
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public static IntPtr Ipc() { return FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1"); }
    public static P Cur() { P p; GetCursorPos(out p); return p; }
    public static string Fg() {
        IntPtr h = GetForegroundWindow();
        System.Text.StringBuilder sb = new System.Text.StringBuilder(128);
        GetClassNameW(h, sb, sb.Capacity);
        System.Text.StringBuilder t = new System.Text.StringBuilder(128);
        GetWindowTextW(h, t, t.Capacity);
        return h + " " + sb.ToString() + " [" + t.ToString() + "]";
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int max);
}
'@
$ipc = [S]::Ipc(); "ipc 窗口句柄 = $ipc"
$c = [S]::Cur(); "光标 = ($($c.X),$($c.Y))"
"前台窗口 = $([S]::Fg())"
"实例 = $(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
"虚拟屏幕 = $($b.X),$($b.Y) $($b.Width)x$($b.Height)"
$bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size); $g.Dispose()
$bmp.Save("$PWD\shots\full-now.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
"截图 shots\full-now.png"
