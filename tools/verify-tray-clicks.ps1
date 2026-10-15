# 验证托盘图标的两个点击动作：左键双击 = 切换图标；右键 = 弹菜单且不自杀。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class Y {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte s, uint f, IntPtr e);
    public static IntPtr Ipc() { return FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1"); }
    public static void Tray(uint msg) { PostMessageW(Ipc(), 0x400, new IntPtr(1), new IntPtr((int)msg)); }
    public static void Esc() { keybd_event(0x1B, 0, 0, IntPtr.Zero); keybd_event(0x1B, 0, 2, IntPtr.Zero); }
}
'@

function Icons {
    $o = Join-Path $env:TEMP ("i-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--status" -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o)
    Remove-Item $o -ErrorAction SilentlyContinue
    ([regex]::Match($t, 'icons\s+= (\w+)')).Groups[1].Value
}

function Alive { @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count }

"起始：icons=$(Icons) 实例=$(Alive)"
[Y]::Tray(0x203); Start-Sleep -Milliseconds 700
$a = Icons
"托盘左键双击一次 -> icons=$a  实例=$(Alive)"
[Y]::Tray(0x203); Start-Sleep -Milliseconds 700
$b = Icons
"再来一次 -> icons=$b  实例=$(Alive)"
[Y]::Tray(0x205); Start-Sleep -Milliseconds 900
"右键叫出菜单后 -> 实例=$(Alive)（应为 1，且菜单可见）"
Start-Sleep -Milliseconds 800
[Y]::Esc(); Start-Sleep -Milliseconds 400
"Esc 收起菜单后 -> 实例=$(Alive)"
# 打印了 FAIL 就必须给非零退出码，否则自动化把这轮当成成功（原先结尾没有 exit）。
if ($a -ne $b -and (Alive) -eq 1) { "结论：PASS"; exit 0 } else { "结论：FAIL"; exit 1 }
