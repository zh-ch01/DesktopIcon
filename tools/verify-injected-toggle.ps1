# F23：托盘菜单里「接受注入的双击（脚本/远控）」这条开关，两条路径都要有数。
#   关=0 时注入的双击必须被拒（last=injected_off、showwindow 不动、桌面不被改）；
#   开=1 时必须接受并真的切换（last=toggled、showwindow +1、独立探针看到图标放出来）。
# 前置：必须有一个"根窗口确实是桌面本体"的落点。桌面被全屏窗口（浏览器等）盖住时这一组测不了，
#       脚本会给 SKIP 并退 4 —— 不做"能跑就算"的降级，那种条件下"没切换"根本证明不了是开关在起作用。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"
$SettingsKey = 'HKCU:\Software\DesktopIconToggle'

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class IT {
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPD { [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPD u; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] items, int cbSize);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);

    public static List<IntPtr> Layers() {
        var list = new List<IntPtr>();
        var roots = new List<IntPtr>();
        IntPtr progman = FindWindowW("Progman", null);
        if (progman != IntPtr.Zero) roots.Add(progman);
        IntPtr w = IntPtr.Zero;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) break;
            if (w != progman) roots.Add(w);
        }
        foreach (IntPtr root in roots) {
            IntPtr view = IntPtr.Zero;
            while (true) {
                view = FindWindowExW(root, view, "SHELLDLL_DefView", null);
                if (view == IntPtr.Zero) break;
                IntPtr lv = FindWindowExW(view, IntPtr.Zero, "SysListView32", null);
                if (lv != IntPtr.Zero) list.Add(lv);
            }
        }
        return list;
    }

    public static string State() {
        var ls = Layers();
        if (ls.Count == 0) return "no-iconlayer";
        int shown = 0;
        foreach (IntPtr h in ls) { if (IsWindowVisible(h)) shown++; }
        if (shown == 0) return "hidden";
        return shown == ls.Count ? "visible" : "mixed";
    }

    // 根窗口是不是桌面本体（Progman / WorkerW）。基线用"图标已隐藏"，那时列表控件不可见，
    // 点的就是桌面本体，不会掺进"其实点在某个图标上、产品按设计让位"这个干扰因素。
    public static bool DesktopRootAt(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr hit = WindowFromPoint(pt);
        if (hit == IntPtr.Zero) return false;
        IntPtr root = GetAncestor(hit, 2);   // GA_ROOT
        if (root == IntPtr.Zero) return false;
        StringBuilder sb = new StringBuilder(64);
        int len = GetClassNameW(root, sb, sb.Capacity);
        if (len <= 0) return false;
        string cls = sb.ToString(0, len);
        return cls == "Progman" || cls == "WorkerW";
    }

    public static string RootClsAt(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr hit = WindowFromPoint(pt);
        IntPtr root = GetAncestor(hit, 2);
        StringBuilder sb = new StringBuilder(64);
        int len = GetClassNameW(root, sb, sb.Capacity);
        return len <= 0 ? "(无)" : sb.ToString(0, len);
    }

    // 桌面被大窗口（IDE / 浏览器）盖住时，A 组需要一个"根窗口是桌面本体"的落点就没有了。
    // 这里把那些窗口临时最小化，并把句柄交回调用方在 finally 里逐个还原——不关闭、不杀进程。
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    // 最小化会把「最大化」的窗口降级成浮动尺寸：还原时只给 SW_RESTORE 就把用户机器永久留在坏状态。
    // 所以最小化之前先记下它原本是不是最大化，还原时补一次 SW_MAXIMIZE。
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    static List<IntPtr> _minimized = new List<IntPtr>();
    static List<IntPtr> _zoomed = new List<IntPtr>();

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    public static IntPtr[] MinimizeCovering() {
        _minimized.Clear(); _zoomed.Clear();
        EnumProc cb = delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            if ((r.R - r.L) < 600 || (r.B - r.T) < 400) return true;
            StringBuilder sb = new StringBuilder(128);
            int n = GetClassNameW(h, sb, sb.Capacity);
            if (n <= 0 || n > sb.Length) return true;
            string cls = sb.ToString(0, Math.Min(n, sb.Length));
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd"
                || cls == "Windows.UI.Core.CoreWindow") return true;
            if (IsZoomed(h)) _zoomed.Add(h);      // 此刻还没被最小化，问得出原始状态
            _minimized.Add(h);
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        foreach (IntPtr h in _minimized) { ShowWindow(h, 6); }   // SW_MINIMIZE
        return _minimized.ToArray();
    }

    public static void RestoreAll(IntPtr[] handles) {
        if (handles == null) return;
        foreach (IntPtr h in handles) {
            ShowWindow(h, 9);                                     // SW_RESTORE
            if (_zoomed.Contains(h)) ShowWindow(h, 3);            // 原本最大化的补回 SW_MAXIMIZE
        }
    }

    public static int DoubleClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(140);
        INPUT[] ev = new INPUT[5];
        ev[0].type = 0; ev[0].u.mi.dwFlags = 0x0002;
        ev[1].type = 0; ev[1].u.mi.dwFlags = 0x0001 | 0x0002;
        ev[2].type = 0; ev[2].u.mi.dwFlags = 0x0004 | 0x0002;
        ev[3].type = 0; ev[3].u.mi.dwFlags = 0x0001 | 0x0002;
        ev[4].type = 0; ev[4].u.mi.dwFlags = 0x0004 | 0x0002;
        return (int)SendInput((uint)ev.Length, ev, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }     # 默认测仓库里这一份；只有"先退掉在场那一份"时才传别的路径
    $outFile = Join-Path $env:TEMP ("it-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path "$outFile.err") { $text += (Get-Content "$outFile.err" -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

function Get-Metrics {
    $s = (Invoke-Exe @('--status')).Text
    $d = [regex]::Match($s, 'diag\s+= ups=(\d+) pairs=(\d+) showwindow=(\d+) dropped=(\d+) toggle_failed=(\d+)')
    $g = [regex]::Match($s, 'gesture\s+= on_icon=(\d+) not_desktop=(\d+)(?: throttled=\d+)? last=(\w+)')
    if (-not ($d.Success -and $g.Success)) { return $null }
    return [pscustomobject]@{ pairs = [int]$d.Groups[2].Value; shown = [int]$d.Groups[3].Value
        notDesktop = [int]$g.Groups[2].Value; last = $g.Groups[3].Value }
}

$blankX = 1700; $blankY = 400

# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是活动照样发生在那一份身上，
# 后面每一次 --status 都读不到 diag/gesture 行，Get-Metrics 直接返回 null。先按进程 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $null = Invoke-Exe @('--exit') -path $livePath
}
Start-Sleep -Milliseconds 800
if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -eq 0) { Start-Process $exe; Start-Sleep -Milliseconds 1500 }
$null = Invoke-Exe @('--hide')
if ([IT]::State() -ne 'hidden') { throw "基线置 hidden 失败（$([IT]::State())）" }

function Pick-Point {
    foreach ($cx in @(1700, 1800, 1600, 960, 1400, 120, 620)) {
        foreach ($cy in @(60, 120, 300, 700, 1000)) {
            if ([IT]::DesktopRootAt($cx, $cy)) {
                $script:blankX = $cx; $script:blankY = $cy; return $true
            }
        }
    }
    return $false
}

$found = Pick-Point
$covered = @()
if (-not $found) {
    # 落点被遮住的两种可能：别的窗口盖着桌面（临时最小化就能解决），或者整个桌面就是被占满。
    # 前一种可以测：把遮挡窗口最小化、测完在 finally 里逐个还原，不关任何程序。
    Write-Host "   35 个候选点都不在桌面本体上，临时最小化遮挡窗口后重扫（跑完还原）..."
    $covered = [IT]::MinimizeCovering()
    Start-Sleep -Milliseconds 1500
    $found = Pick-Point
    if ($covered.Count -gt 0) {
        Write-Host ("   已临时最小化 {0} 个窗口；结束时会还原，中途出错也会走 finally 还原" -f $covered.Count)
    }
}
if (-not $found) {
    Write-Host ("SKIP - 最小化遮挡窗口之后仍然找不到桌面落点（当前根窗口='{0}'），这一组测不了" -f [IT]::RootClsAt(1700, 400)) -ForegroundColor Yellow
    Write-Host "     不做降级：那种条件下测出来的'没切换'根本证明不了是开关在起作用。"
    if ($covered.Length -gt 0) { [IT]::RestoreAll($covered) }
    $null = Invoke-Exe @('--show')
    exit 4
}
Write-Host ("== 落点 = ({0},{1})，根窗口已确认是桌面本体；基线 hidden ==" -f $blankX, $blankY)

$fails = @()
$orig = (Get-ItemProperty -Path $SettingsKey -Name RespondToInjectedDoubleClick -EA SilentlyContinue).RespondToInjectedDoubleClick

try {
    # 关：注入双击必须被拒，而且在落点判定之前就拒掉（所以 not_desktop 也不许涨）
    Set-ItemProperty -Path $SettingsKey -Name RespondToInjectedDoubleClick -Value 0 -Type DWord
    $b = Get-Metrics
    $recv1 = [IT]::DoubleClickAt($blankX, $blankY)
    Start-Sleep -Milliseconds 900
    $m1 = Get-Metrics
    $s1 = [IT]::State()
    Write-Host ("  开关=0：注入事件={0}  pairs {1}->{2}  shown {3}->{4}  not_desktop {5}->{6}  last={7}  桌面={8}" -f `
        $recv1, $b.pairs, $m1.pairs, $b.shown, $m1.shown, $b.notDesktop, $m1.notDesktop, $m1.last, $s1)
    if ($recv1 -ne 5) { $fails += "开关=0：注入只被接收 $recv1 个事件，证据无效" }
    if ($m1.pairs -le $b.pairs) { $fails += "开关=0：pairs 没涨，这两下压根没配成双击，证据无效" }
    if ($m1.last -ne 'injected_off') { $fails += "开关=0：last='$($m1.last)'，应为 injected_off" }
    if ($m1.shown -ne $b.shown) { $fails += "开关=0：关着却切换了（shown $($b.shown)->$($m1.shown)）" }
    if ($s1 -ne 'hidden') { $fails += "开关=0：桌面被动过了（$s1）" }
    if ($m1.notDesktop -ne $b.notDesktop) { $fails += "开关=0：不该产生落点判定，not_desktop 却涨了（拒绝发生在落点判定之后，顺序不对）" }

    # 开：同一个点、同一种注入，必须切换
    Set-ItemProperty -Path $SettingsKey -Name RespondToInjectedDoubleClick -Value 1 -Type DWord
    $b2 = Get-Metrics
    $recv2 = [IT]::DoubleClickAt($blankX, $blankY)
    Start-Sleep -Milliseconds 900
    $m2 = Get-Metrics
    $s2 = [IT]::State()
    Write-Host ("  开关=1：注入事件={0}  pairs {1}->{2}  shown {3}->{4}  not_desktop {5}->{6}  last={7}  桌面={8}" -f `
        $recv2, $b2.pairs, $m2.pairs, $b2.shown, $m2.shown, $b2.notDesktop, $m2.notDesktop, $m2.last, $s2)
    if ($recv2 -ne 5) { $fails += "开关=1：注入只被接收 $recv2 个事件，证据无效" }
    if ($m2.shown -le $b2.shown) { $fails += "开关=1：开着却没切换（shown 仍是 $($m2.shown)，last=$($m2.last)）" }
    if ($m2.last -ne 'toggled') { $fails += "开关=1：last='$($m2.last)'，应为 toggled" }
    if ($s2 -ne 'visible') { $fails += "开关=1：独立探针没看到图标放出来（$s2）" }
    Write-Host "  -> 同一个落点、同一种注入，唯一变量就是那个开关"
}
finally {
    # 先把临时最小化的窗口还原，再管注册表和桌面状态——用户的应用不该被测试留在收起状态。
    if ($covered.Length -gt 0) { [IT]::RestoreAll($covered); Write-Host "   已还原临时最小化的 $($covered.Length) 个窗口" }
    if ($null -ne $orig) {
        Set-ItemProperty -Path $SettingsKey -Name RespondToInjectedDoubleClick -Value ([int]$orig) -Type DWord
    } else {
        Remove-ItemProperty -Path $SettingsKey -Name RespondToInjectedDoubleClick -ErrorAction SilentlyContinue
    }
    $null = Invoke-Exe @('--show')
}

if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 注入开关两条路径都有数：拒在落点判定之前，放开后同一落点必切" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "  FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
