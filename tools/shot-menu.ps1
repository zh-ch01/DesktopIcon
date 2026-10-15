# 把托盘菜单叫到屏幕中间并截图，验证菜单真的显示出来了、内容顺序正确。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class X {
    [StructLayout(LayoutKind.Sequential)] struct INPUT {
        public uint type; public uint pad; public int dx; public int dy;
        public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte s, uint f, IntPtr e);

    public static IntPtr Ipc() { return FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1"); }
    public static void Move(int x, int y) { SetCursorPos(x, y); Thread.Sleep(250); }
    public static void NotifyRightClick() { PostMessageW(Ipc(), 0x400, new IntPtr(1), new IntPtr(0x205)); }
    public static void NotifyDblClk() { PostMessageW(Ipc(), 0x400, new IntPtr(1), new IntPtr(0x203)); }
    public static void Esc() { keybd_event(0x1B, 0, 0, IntPtr.Zero); keybd_event(0x1B, 0, 2, IntPtr.Zero); }
}
'@

function Shot([string]$name) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $g.Dispose()
    $full = Join-Path $shots "$name.png"
    $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
    # 以光标为中心裁一块，方便按 1:1 尺寸看菜单
    $crop = New-Object System.Drawing.Bitmap 460, 380
    $cg = [System.Drawing.Graphics]::FromImage($crop)
    $cg.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, 460, 380),
                        (New-Object System.Drawing.Rectangle 900, 380, 460, 380), [System.Drawing.GraphicsUnit]::Pixel)
    $cg.Dispose()
    $crop.Save((Join-Path $shots "crop-$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $crop.Dispose(); $bmp.Dispose()
    return $full
}

$shots = Join-Path (Get-Location) 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
Start-Process "dist\DesktopIconToggle.exe"
Start-Sleep -Seconds 2
$before = @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count

[X]::Move(960, 420)
[X]::NotifyRightClick()
Start-Sleep -Milliseconds 800
$p = Shot "menu-open"
"菜单已叫出，截图 $p  存活=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)（调用前 $before）"
Start-Sleep -Milliseconds 500
[X]::Esc()
Start-Sleep -Milliseconds 400
"Esc 之后存活=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"

# 顺带验一下托盘左键双击 = 切换图标
$iconsBefore = ((& "dist\DesktopIconToggle.exe" --status) | Out-String) -replace '(?s).*icons\s+= (\w+).*','$1'
[X]::NotifyDblClk()
Start-Sleep -Milliseconds 800
$iconsAfter = ((& "dist\DesktopIconToggle.exe" --status) | Out-String) -replace '(?s).*icons\s+= (\w+).*','$1'
"托盘左键双击：$($iconsBefore.Trim()) -> $($iconsAfter.Trim())"
[X]::NotifyDblClk()
Start-Sleep -Milliseconds 800
$iconsBack = ((& "dist\DesktopIconToggle.exe" --status) | Out-String) -replace '(?s).*icons\s+= (\w+).*','$1'
"再来一次：$($iconsBack.Trim())"
"最终存活=$(@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)"
