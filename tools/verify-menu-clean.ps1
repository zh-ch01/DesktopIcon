# Clean one-shot observation of tray-menu dismissal. ASCII-only output (PS 5.1 + UTF-8 is a trap).
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class C3 {
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public uint pad; public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte s, uint f, IntPtr e);
    static INPUT Mk(uint f) { INPUT i = new INPUT(); i.type = 0; i.dwFlags = f; return i; }
    public static IntPtr Ipc() { return FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1"); }
    public static void OpenMenu(int x, int y) { SetCursorPos(x, y); Thread.Sleep(250); PostMessageW(Ipc(), 0x400, new IntPtr(1), new IntPtr(0x205)); }
    public static void Click(int x, int y) { SetCursorPos(x, y); Thread.Sleep(250);
        INPUT[] a = new INPUT[] { Mk(0x0002), Mk(0x0004) }; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
    public static void Esc() { keybd_event(0x1B,0,0,IntPtr.Zero); keybd_event(0x1B,0,2,IntPtr.Zero); }
}
'@
function Stop-Instance {
    # 用 --exit 正常退出：Stop-Process 强杀会让 explorer 留下幽灵托盘图标（点不到的空位），
    # 而且会污染后续所有基于托盘的测试。强杀只作为兜底。
    $o = Join-Path $env:TEMP ("x-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--exit" -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue
    Remove-Item $o -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline -and @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Start-Sleep -Milliseconds 150 }
    if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
}

function Stat {
    $o = Join-Path $env:TEMP ("s-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--status" -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o); Remove-Item $o -ErrorAction SilentlyContinue
    $m = [regex]::Match($t, 'menu\s+= tracks=(\d+) last_track_ms=(\d+)')
    return "tracks=$($m.Groups[1].Value) last_ms=$($m.Groups[2].Value)"
}
function Shot([string]$tag) {
    $bmp = New-Object System.Drawing.Bitmap 460, 320
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(1450, 870, 0, 0, $bmp.Size); $g.Dispose()
    $p = Join-Path $shots "clean-$tag.png"; $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0,12)
}
$shots = Join-Path (Get-Location) 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
Stop-Instance
Start-Sleep -Milliseconds 400
Start-Process "dist\DesktopIconToggle.exe"
Start-Sleep -Seconds 2
"step0 fresh instance   $(Stat)"
$s0 = Shot "0-base"
"step1 baseline pixels  $s0  $(Stat)"
[C3]::OpenMenu(1642, 1173); Start-Sleep -Milliseconds 900
$s1 = Shot "1-open"
"step2 after open       $s1  $(Stat)"
[C3]::Click(700, 500); Start-Sleep -Milliseconds 1200
$s2 = Shot "2-outside"
"step3 after outside    $s2  $(Stat)"
if ($s2 -eq $s0) { "VERDICT: PASS - menu dismissed on outside click" }
elseif ($s2 -eq $s1) { "VERDICT: FAIL - menu still on screen" }
else { "VERDICT: UNCLEAR - region changed for other reasons, inspect shots/clean-*.png" }
[C3]::Esc()
