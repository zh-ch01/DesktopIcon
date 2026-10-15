# 端到端反证：注入真实左键双击，验"双击桌面空白处切换图标"这条链路。
# 副作用：把鼠标移到桌面空白处两次并双击（图标会隐藏再显示），结束时把光标移回原位、图标恢复可见。
# 跑法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-gesture.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class G {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref P pt);
    [DllImport("user32.dll", SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint g);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int max);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int cbSize);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, int s, uint t, uint pr);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, int s, uint f);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int w);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int r);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    // x64 的 INPUT 是 40 字节：type(4) + 填充(4) + MOUSEINPUT{ dx,dy,mouseData,dwFlags,time (20) + 填充(4) + dwExtraInfo(8) }
    // 写成 32 字节的话 SendInput 直接返回 0 一个事件都不注入——之前的"注入双击"就是这么静默失效的。
    [StructLayout(LayoutKind.Sequential)] struct INPUT {
        public uint type; public uint pad; public int dx; public int dy;
        public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra;
    }

    const uint INPUT_MOUSE = 0;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    // 0x1010 = LVM_FIRST+16；写错时消息不生效、读回全零，锚点会假称 (0,0)
    const uint LVM_GETITEMCOUNT = 0x1004, LVM_GETITEMPOSITION = 0x1010, LVM_SUBHITTEST = 0x1039;
    const uint LVHT_ONITEM = 0x000E;              // ICON|LABEL|STATEICON，不含 NOWHERE(0x1)
    const uint PROCESS_WM = 0x0008 | 0x0010 | 0x0020 | 0x1000;
    const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_RW = 0x04;

    static IntPtr Progman = FindWindowW("Progman", null);

    public static IntPtr DefView() {
        IntPtr d = FindWindowExW(Progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (d != IntPtr.Zero) { return d; }
        IntPtr w = IntPtr.Zero;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) { break; }
            d = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (d != IntPtr.Zero) { break; }
        }
        return d;
    }

    public static IntPtr List() {
        IntPtr d = DefView();
        if (d == IntPtr.Zero) { return IntPtr.Zero; }
        return FindWindowExW(d, IntPtr.Zero, "SysListView32", null);
    }

    public static bool Visible() {
        IntPtr d = DefView();
        if (d == IntPtr.Zero) { return false; }
        IntPtr l = FindWindowExW(d, IntPtr.Zero, "SysListView32", null);
        return l != IntPtr.Zero && IsWindowVisible(l);
    }

    public static int Count(IntPtr l) { return (int)SendMessageW(l, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero); }

    static uint Pid(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return pid; }

    public static P IconAt(IntPtr l, int index) {
        P r = new P();
        int junk;
        IntPtr proc = OpenProcess(PROCESS_WM, false, Pid(l));
        if (proc == IntPtr.Zero) { return r; }
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, 8, MEM_COMMIT | MEM_RESERVE, PAGE_RW);
        if (mem == IntPtr.Zero) { CloseHandle(proc); return r; }
        byte[] zero = new byte[8];
        WriteProcessMemory(proc, mem, zero, 8, out junk);
        SendMessageW(l, LVM_GETITEMPOSITION, new IntPtr(index), mem);
        byte[] back = new byte[8];
        ReadProcessMemory(proc, mem, back, 8, out junk);
        VirtualFreeEx(proc, mem, 0, MEM_RELEASE);
        CloseHandle(proc);
        r.X = BitConverter.ToInt32(back, 0);
        r.Y = BitConverter.ToInt32(back, 4);
        return r;
    }

    /// 和被测程序同一套判据：pt 用客户区坐标，命中位用 LVHT_ONITEM
    public static bool OverIcon(IntPtr l, P screenPt) {
        P pt = screenPt;
        int junk;
        ScreenToClient(l, ref pt);
        byte[] payload = new byte[24];
        BitConverter.GetBytes(pt.X).CopyTo(payload, 0);
        BitConverter.GetBytes(pt.Y).CopyTo(payload, 4);
        IntPtr proc = OpenProcess(PROCESS_WM, false, Pid(l));
        if (proc == IntPtr.Zero) { return false; }
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, payload.Length, MEM_COMMIT | MEM_RESERVE, PAGE_RW);
        if (mem == IntPtr.Zero) { CloseHandle(proc); return false; }
        WriteProcessMemory(proc, mem, payload, payload.Length, out junk);
        SendMessageW(l, LVM_SUBHITTEST, IntPtr.Zero, mem);
        byte[] back = new byte[payload.Length];
        ReadProcessMemory(proc, mem, back, back.Length, out junk);
        VirtualFreeEx(proc, mem, 0, MEM_RELEASE);
        CloseHandle(proc);
        uint flags = BitConverter.ToUInt32(back, 8);
        return (flags & LVHT_ONITEM) != 0;
    }

    public static bool OnDesktop(P pt) {
        IntPtr hit = WindowFromPoint(pt);
        if (hit == IntPtr.Zero) { return false; }
        IntPtr root = GetAncestor(hit, 2);
        if (root == IntPtr.Zero) { return false; }
        System.Text.StringBuilder sb = new System.Text.StringBuilder(64);
        GetClassNameW(root, sb, sb.Capacity);
        string name = sb.ToString();
        return name == "Progman" || name == "WorkerW";
    }

    /// 返回系统真正接收到的事件数（应为 2+2=4）；返回 0 说明注入根本没生效，别把它当成产品故障。
    public static int DoubleClick(int x, int y) {
        SetCursorPos(x, y);
        Thread.Sleep(150);
        INPUT[] first = new INPUT[] { Make(MOUSEEVENTF_LEFTDOWN), Make(MOUSEEVENTF_LEFTUP) };
        int a = (int)SendInput((uint)first.Length, first, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(60);
        INPUT[] second = new INPUT[] { Make(MOUSEEVENTF_LEFTDOWN), Make(MOUSEEVENTF_LEFTUP) };
        int b = (int)SendInput((uint)second.Length, second, Marshal.SizeOf(typeof(INPUT)));
        return a + b;
    }

    static INPUT Make(uint f) { INPUT i = new INPUT(); i.type = INPUT_MOUSE; i.dwFlags = f; return i; }
}
'@

# 整屏平均亮度：用来守"隐藏图标不能把壁纸一起带走"这条回归（Win11 上隐藏 DefView 会黑屏，实测亮度 128→28）
function Get-MeanLuma {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap ($b.Width, $b.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $g.Dispose()
    $sum = [double]0; $n = 0
    for ($y = 0; $y -lt $bmp.Height; $y += 16) {
        for ($x = 0; $x -lt $bmp.Width; $x += 16) {
            $c = $bmp.GetPixel($x, $y)
            $sum += (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B); $n++
        }
    }
    $bmp.Dispose()
    return [Math]::Round($sum / $n, 1)
}

function Wait-State([bool]$expect, [int]$ms = 3000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        if ([G]::Visible() -eq $expect) { return $expect }
        Start-Sleep -Milliseconds 25
    }
    return [G]::Visible()
}

function Get-InstanceReport {
    $f = Join-Path $env:TEMP ("st-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $exe -ArgumentList '--status' -NoNewWindow -Wait -RedirectStandardOutput $f
    $t = if (Test-Path $f) { [IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8).Trim() } else { '(无输出)' }
    Remove-Item $f -ErrorAction SilentlyContinue
    (($t -split "`r?`n") | Where-Object { $_ -match 'instance|diag' }) -join '  ||  '
}

$log = Join-Path (Split-Path -Parent $PSScriptRoot) 'gesture-test.log'
$lines = @()
$lines += "[START] $(Get-Date -Format 'HH:mm:ss.fff')"

# 手势是在后台实例的钩子里判定的，先确保它活着
$exe = Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\DesktopIconToggle.exe'
if (@(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count -eq 0) {
    Start-Process $exe | Out-Null
    Start-Sleep -Seconds 2
    $lines += "已启动后台实例 $exe"
}
$lines += "实例数 = $(@(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count)"

$list = [G]::List()
$count = [G]::Count($list)
$lines += "defview=$([G]::DefView()) listview=$list 桌面图标数=$count 初始可见=$([G]::Visible())"

# 找一个"确实属于桌面、且没压在任何图标上"的点。
# 注意：如果被最大化窗口盖住，屏幕上可能一个桌面像素都不露——那正是程序该"不响应"的情形，
# 但测试就没法做了，所以此时临时最小化全部窗口，测完再还原。
function Find-EmptyDesktopPoint([IntPtr]$list, [int]$count, [switch]$Tally) {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $onDesktop = 0; $overIcon = 0; $found = $null
    for ($y = 60; $y -lt $bounds.Height - 60 -and $null -eq $found; $y += 40) {
        for ($x = 60; $x -lt $bounds.Width - 60; $x += 40) {
            $pt = New-Object G+P
            $pt.X = $x; $pt.Y = $y
            if (-not [G]::OnDesktop($pt)) { continue }
            $onDesktop++
            if ($count -gt 0 -and [G]::OverIcon($list, $pt)) { $overIcon++; continue }
            $found = $pt
        }
    }
    if ($Tally) { $script:tally = "露出的桌面采样点=$onDesktop 其中压住图标=$overIcon" }
    return $found
}

$empty = Find-EmptyDesktopPoint $list $count -Tally
$lines += "扫描：$script:tally"
if ($null -eq $empty) {
    $lines += "桌面被窗口完全盖住 -> 临时最小化全部窗口（测完还原）"
    $shell = New-Object -ComObject Shell.Application
    $shell.MinimizeAll()
    Start-Sleep -Seconds 2
    $minimized = $true
    $empty = Find-EmptyDesktopPoint $list $count -Tally
    $lines += "最小化后扫描：$script:tally"
}
if ($null -eq $empty) { $lines += 'FAIL: 仍找不到空白桌面点'; $lines | Set-Content $log -Encoding UTF8; $lines; exit 1 }
$lines += "空白点 = ($($empty.X),$($empty.Y))  OnDesktop=$([G]::OnDesktop($empty))  OverIcon=$([G]::OverIcon($list,$empty))"

# 图标中心点（只做过/不过判定，不去点它——避免真的启动程序）
$iconHit = $false
if ($count -gt 0) {
    $p0 = [G]::IconAt($list, 0)
    $center = New-Object G+P
    $center.X = $p0.X + 26; $center.Y = $p0.Y + 18
    $iconHit = [G]::OverIcon($list, $center)
    $lines += "图标0位置 = ($($p0.X),$($p0.Y)) 其中心 OverIcon=$iconHit（应为 True）"
}

$origin = [System.Windows.Forms.Cursor]::Position
$baseline = [G]::Visible()
$lumaNormal = Get-MeanLuma
$lines += "基线实例自述 : " + (Get-InstanceReport)

# CASE 1：空白处注入双击 -> 应翻转
$t = Get-Date
$inj1 = [G]::DoubleClick($empty.X, $empty.Y)
$lines += "注入 #1 SendInput 接收事件数 = $inj1（应为 4；为 0 说明注入没生效，不能算产品失败）"
$after1 = Wait-State (-not $baseline)
$ms1 = ((Get-Date) - $t).TotalMilliseconds
$case1 = ($after1 -eq (-not $baseline))
$lines += ("CASE1 空白双击->切换 : 期望={0} 实测={1} 用时={2}ms -> {3}" -f (-not $baseline), $after1, [int]$ms1, $(if ($case1) { 'PASS' } else { 'FAIL' }))
$lines += "CASE1 之后的实例自述：`n" + (Get-InstanceReport)
$lumaHidden = Get-MeanLuma
$case4 = $lumaHidden -gt ($lumaNormal * 0.7)
$lines += ("CASE4 壁纸没被带走 : 正常亮度={0} 隐藏后亮度={1} -> {2}" -f $lumaNormal, $lumaHidden, $(if ($case4) { 'PASS' } else { 'FAIL' }))

# CASE 2：再双击 -> 应翻回
$t = Get-Date
$inj2 = [G]::DoubleClick($empty.X, $empty.Y)
$lines += "注入 #2 SendInput 接收事件数 = $inj2"
$after2 = Wait-State $baseline
$ms2 = ((Get-Date) - $t).TotalMilliseconds
$case2 = ($after2 -eq $baseline)
$lines += ("CASE2 再双击->恢复 : 期望={0} 实测={1} 用时={2}ms -> {3}" -f $baseline, $after2, [int]$ms2, $(if ($case2) { 'PASS' } else { 'FAIL' }))
$lines += "两轮双击之后的实例自述 : " + (Get-InstanceReport)

# CASE 3：命中判定方向（盯 P0-1 的回归：空白点必须判 False，图标中心必须判 True）
$case3 = ((-not [G]::OverIcon($list, $empty)) -and $iconHit)
$lines += "CASE3 判定方向 : 空白=False 图标=True -> $(if ($case3) { 'PASS' } else { 'FAIL' })"

[G]::SetCursorPos($origin.X, $origin.Y) | Out-Null
if ($minimized) {
    $shell = New-Object -ComObject Shell.Application
    $shell.UndoMinimizeALL()
    $lines += "已还原最小化的窗口"
}
$lines += "光标已还原 ($($origin.X),$($origin.Y))  最终可见=$([G]::Visible())"
$lines += "[END] $(Get-Date -Format 'HH:mm:ss.fff')"
$lines | Set-Content $log -Encoding UTF8
$lines
if (-not ($case1 -and $case2 -and $case3 -and $case4)) { exit 1 }
