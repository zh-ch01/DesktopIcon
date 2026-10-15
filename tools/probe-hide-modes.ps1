# 对照实验：三种"隐藏桌面图标"的打法，各截一张全屏图，看谁会把壁纸一起带走。
# 会最小化全部窗口并在结束时还原；会临时隐藏/恢复桌面图标。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class M {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr r, IntPtr g, uint flags);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr arg);
    public delegate bool EnumProc(IntPtr h, IntPtr a);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int max);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int max);

    public static IntPtr Progman = FindWindowW("Progman", null);

    public static IntPtr DefView() {
        IntPtr d = FindWindowExW(Progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (d != IntPtr.Zero) { return d; }
        IntPtr w = IntPtr.Zero;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) { break; }
            d = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (d != IntPtr.Zero) { return d; }
        }
        return d;
    }

    public static IntPtr IconList() {
        IntPtr d = DefView();
        return d == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(d, IntPtr.Zero, "SysListView32", null);
    }


    public static string Tree() {
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        IntPtr d = DefView();
        if (d == IntPtr.Zero) { return "(no DefView)"; }
        DescribeInto(sb, d, 0);
        IntPtr c = IntPtr.Zero;
        while (true) {
            c = FindWindowExW(d, c, null, null);
            if (c == IntPtr.Zero) { break; }
            DescribeInto(sb, c, 1);
            IntPtr g = IntPtr.Zero;
            while (true) {
                g = FindWindowExW(c, g, null, null);
                if (g == IntPtr.Zero) { break; }
                DescribeInto(sb, g, 2);
            }
        }
        return sb.ToString();
    }

    public static string OtherWorkerW() {
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        IntPtr w = IntPtr.Zero;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) { break; }
            DescribeInto(sb, w, 0);
            IntPtr c = IntPtr.Zero;
            while (true) {
                c = FindWindowExW(w, c, null, null);
                if (c == IntPtr.Zero) { break; }
                DescribeInto(sb, c, 1);
            }
        }
        return sb.ToString();
    }

    static void DescribeInto(System.Text.StringBuilder sb, IntPtr h, int depth) {
        for (int i = 0; i < depth; i++) sb.Append("  ");
        System.Text.StringBuilder cls = new System.Text.StringBuilder(128);
        GetClassNameW(h, cls, cls.Capacity);
        System.Text.StringBuilder txt = new System.Text.StringBuilder(128);
        GetWindowTextW(h, txt, txt.Capacity);
        uint pid; GetWindowThreadProcessId(h, out pid);
        sb.Append(h.ToString()).Append(" ").Append(cls.ToString()).Append(" [").Append(txt.ToString()).Append("]")
          .Append(IsWindowVisible(h) ? " visible" : " HIDDEN").Append(" pid=").Append(pid).AppendLine();
    }

    public static void Show(IntPtr h, bool on) { ShowWindow(h, on ? 5 : 0); if (on) { UpdateWindow(h); } }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
}
'@

function Get-FullScreen([string]$path) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Average([string]$path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    $step = 8
    $sum = [double]0; $n = 0; $black = 0
    for ($y = 0; $y -lt $bmp.Height; $y += $step) {
        for ($x = 0; $x -lt $bmp.Width; $x += $step) {
            $c = $bmp.GetPixel($x, $y)
            $lum = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B
            $sum += $lum; $n++
            if ($lum -lt 12) { $black++ }
        }
    }
    $bmp.Dispose()
    return [pscustomobject]@{ meanLuma = [Math]::Round($sum / $n, 1); nearBlackPct = ('{0:P1}' -f ($black / $n)) }
}

$root = Split-Path -Parent $PSScriptRoot
$shots = Join-Path $root 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

"=== DefView 子树（谁在画壁纸） ==="
[M]::Tree()
"=== 各 WorkerW 的子窗口 ==="
[M]::OtherWorkerW()

$defView = [M]::DefView()
$iconList = [M]::IconList()
""
"defView=$defView  iconList=$iconList"

$shell = New-Object -ComObject Shell.Application
$shell.MinimizeAll()
Start-Sleep -Seconds 2

Get-FullScreen (Join-Path $shots 'A-正常.png')
"A 正常                : " + (Average (Join-Path $shots 'A-正常.png') | Out-String).Trim()

[M]::Show($defView, $false)
Start-Sleep -Milliseconds 500
Get-FullScreen (Join-Path $shots 'B-隐藏DefView.png')
"B 隐藏 SHELLDLL_DefView : " + (Average (Join-Path $shots 'B-隐藏DefView.png') | Out-String).Trim()
[M]::Show($defView, $true)
Start-Sleep -Milliseconds 400

[M]::Show($iconList, $false)
Start-Sleep -Milliseconds 500
Get-FullScreen (Join-Path $shots 'C-只隐藏列表.png')
"C 只隐藏 SysListView32  : " + (Average (Join-Path $shots 'C-只隐藏列表.png') | Out-String).Trim()
"  （DefView 仍可见 = $([M]::Visible($defView))，列表可见 = $([M]::Visible($iconList))）"
[M]::Show($iconList, $true)
Start-Sleep -Milliseconds 400

[M]::Show($defView, $false)
Start-Sleep -Milliseconds 300
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$g.Dispose(); $bmp.Dispose()
[M]::RedrawWindow([IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, 0x017F)   # 整屏重绘
Start-Sleep -Milliseconds 500
Get-FullScreen (Join-Path $shots 'D-隐藏后整屏重绘.png')
"D 隐藏 DefView + 整屏重绘 : " + (Average (Join-Path $shots 'D-隐藏后整屏重绘.png') | Out-String).Trim()
[M]::Show($defView, $true)

$shell.UndoMinimizeALL()
""
"已恢复；截图在 $shots"
