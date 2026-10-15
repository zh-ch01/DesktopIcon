# 压力：连续快速双击，验证 ShowWindowAsync 之后立刻读状态不会判反方向。
# 期望：N 次双击 => showwindow 计数 +N，且 N 为偶数时状态回到起点。
# 前置：桌面必须真空出来（遮挡窗口临时最小化、图标先显示出来再挑空白点），否则落点根本不在桌面上，
#       这份脚本只会证明"我没测到东西"。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class X5 {
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public uint pad; public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    static INPUT Mk(uint f) { INPUT i = new INPUT(); i.type = 0; i.dwFlags = f; return i; }
    public static void Dbl(int x, int y) {
        SetCursorPos(x, y); Thread.Sleep(80);
        INPUT[] a = new INPUT[] { Mk(0x0002), Mk(0x0004) }; SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(60);
        INPUT[] b = new INPUT[] { Mk(0x0002), Mk(0x0004) }; SendInput(2, b, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
# 自包含的"临时让出桌面"helper：桌面被全屏窗口（IDE/浏览器）盖住时，任何"双击落在桌面空白上"
# 的断言都会失真——命中的其实是别人的窗口，那时"双击没切换"什么也证明不了。
# 开跑前临时最小化遮挡窗口，收尾（含抛异常，见 trap）一律还原。只 ShowWindow，不关闭、不杀进程。
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class COV {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    // 最小化会把「最大化」的窗口降级成浮动尺寸：还原时只给 SW_RESTORE 就把用户机器永久留在坏状态。
    // 所以最小化之前先记下它原本是不是最大化，还原时补一次 SW_MAXIMIZE。
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder sb, int max);

    static System.Collections.Generic.List<IntPtr> _min = new System.Collections.Generic.List<IntPtr>();
    static System.Collections.Generic.List<IntPtr> _zoomed = new System.Collections.Generic.List<IntPtr>();

    public static IntPtr[] MinimizeCovering() {
        _min.Clear(); _zoomed.Clear();
        EnumProc cb = delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            if ((r.r - r.l) < 600 || (r.b - r.t) < 400) return true;
            System.Text.StringBuilder sb = new System.Text.StringBuilder(128);
            int n = GetClassNameW(h, sb, sb.Capacity);
            if (n <= 0) return true;
            string cls = sb.ToString(0, Math.Min(n, sb.Length));
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd") return true;
            if (IsZoomed(h)) _zoomed.Add(h);      // 此刻还没被最小化，问得出原始状态
            _min.Add(h);
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        foreach (IntPtr h in _min) { ShowWindow(h, 6); }
        return _min.ToArray();
    }

    public static void RestoreAll(IntPtr[] hs) {
        if (hs == null) return;
        foreach (IntPtr h in hs) {
            ShowWindow(h, 9);                                     // SW_RESTORE
            if (_zoomed.Contains(h)) ShowWindow(h, 3);            // 原本最大化的补回 SW_MAXIMIZE
        }
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

$coveredWin = @()
function Restore-Covering {
    if ($script:coveredWin.Length -gt 0) {
        [COV]::RestoreAll($script:coveredWin)
        Write-Host ("   已还原临时最小化的 {0} 个遮挡窗口" -f $script:coveredWin.Length)
        $script:coveredWin = @()
    }
}
# trap 必须响亮地失败：continue 会咽掉异常、脚本照常打印 PASS（同一族夹具在 F21 那轮吞过 4 次异常）。
trap {
    Write-Host ("   捕获异常：" + $_.Exception.Message) -ForegroundColor Red
    if (Test-Path Function:\Restore-Covering) { Restore-Covering }
    # 异常路径也不许把桌面留在 hidden：用户下次看桌面才发现图标没了，那是测试造的债。
    try { Start-Process (Join-Path (Get-Location) 'dist\DesktopIconToggle.exe') -ArgumentList '--show' -NoNewWindow -Wait } catch { }
    exit 1
}

function Stat {
    $o = Join-Path $env:TEMP ("r-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--status" -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o); Remove-Item $o -ErrorAction SilentlyContinue
    $d = [regex]::Match($t, 'diag\s+= ups=(\d+) pairs=(\d+) showwindow=(\d+) dropped=(\d+) toggle_failed=(\d+)')
    $i = [regex]::Match($t, 'icons\s+= (\w+)')
    return @{ ups=[int]$d.Groups[1].Value; pairs=[int]$d.Groups[2].Value; shown=[int]$d.Groups[3].Value; dropped=[int]$d.Groups[4].Value; failed=[int]$d.Groups[5].Value; icons=$i.Groups[1].Value }
}
# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是活动照样发生在那一份身上，
# 后面每一次 --status 都读不到它的 diag 行，字段"凭空没了"。所以先按进程的 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $eo = Join-Path $env:TEMP ("rt-exit-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $livePath -ArgumentList '--exit' -NoNewWindow -Wait -RedirectStandardOutput $eo -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $eo, "$eo.err" -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 800
if ((@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count) -eq 0) { Start-Process "dist\DesktopIconToggle.exe"; Start-Sleep 2 }

$coveredWin = [COV]::MinimizeCovering()
if ($coveredWin.Length -gt 0) { Start-Sleep -Milliseconds 1500; Write-Host ("   已临时最小化 {0} 个遮挡窗口（测完自动还原）" -f $coveredWin.Length) }

# 先把图标显示出来再挑空白点：隐藏状态下"每个点都不压图标"，挑出来的点在显示出来后可能正好是某个图标，
# 那一次双击会被正确判为"点在图标上"而不切换 —— 于是 pairs 涨、shown 不涨，测出的是一个假 FAIL。
Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--show" -NoNewWindow -Wait | Out-Null
Start-Sleep -Milliseconds 600

# 找一个确定在桌面上的空白点
$pt = $null
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class X6 {
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint g);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref P p);
    [DllImport("user32.dll", SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, int s, uint t, uint pr);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, int s, uint f);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int w);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr b, byte[] d, int s, out int r);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static IntPtr List() {
        IntPtr p = FindWindowW("Progman", null);
        IntPtr d = FindWindowExW(p, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (d == IntPtr.Zero) { IntPtr w = IntPtr.Zero; while (true) { w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null); if (w == IntPtr.Zero) break; d = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null); if (d != IntPtr.Zero) break; } }
        return d == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(d, IntPtr.Zero, "SysListView32", null);
    }
    public static bool OnDesktop(int x, int y) {
        P p = new P(); p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p); if (h == IntPtr.Zero) return false;
        IntPtr root = GetAncestor(h, 2); if (root == IntPtr.Zero) return false;
        System.Text.StringBuilder sb = new System.Text.StringBuilder(64); GetClassNameW(root, sb, sb.Capacity);
        string n = sb.ToString(); return n == "Progman" || n == "WorkerW";
    }
    public static bool OverIcon(IntPtr l, int sx, int sy) {
        P p = new P(); p.X = sx; p.Y = sy; ScreenToClient(l, ref p);
        uint pid; GetWindowThreadProcessId(l, out pid);
        IntPtr proc = OpenProcess(0x38, false, pid); if (proc == IntPtr.Zero) return false;
        int junk;
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, 24, 0x3000, 0x04); if (mem == IntPtr.Zero) { CloseHandle(proc); return false; }
        byte[] payload = new byte[24];
        BitConverter.GetBytes(p.X).CopyTo(payload, 0); BitConverter.GetBytes(p.Y).CopyTo(payload, 4);
        WriteProcessMemory(proc, mem, payload, 24, out junk);
        SendMessageW(l, 0x1039, IntPtr.Zero, mem);
        byte[] back = new byte[24]; ReadProcessMemory(proc, mem, back, 24, out junk);
        VirtualFreeEx(proc, mem, 0, 0x8000); CloseHandle(proc);
        return (BitConverter.ToUInt32(back, 8) & 0x000E) != 0;
    }
}
'@
$l = [X6]::List()
foreach ($cand in @(@(1500,60),@(1700,120),@(1200,300),@(960,600),@(600,900))) {
    if ([X6]::OnDesktop($cand[0],$cand[1]) -and -not [X6]::OverIcon($l,$cand[0],$cand[1])) { $pt = $cand; break }
}
if ($null -eq $pt) {
    # 固定候选点全部落空（图标铺满/桌面被盖住）→ 在工作区内扫网格，并要求候选点四周 24px 也不压图标，
    # 免得双击的 2px 容差把落点滑到邻居图标上。
    Add-Type -AssemblyName System.Windows.Forms
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $y = 40
    while ($null -eq $pt -and $y -lt ($wa.Bottom - 40)) {
        $x = 40
        while ($null -eq $pt -and $x -lt ($wa.Right - 40)) {
            if ([X6]::OnDesktop($x, $y)) {
                $busy = $false
                foreach ($o in @(@(0,0),@(-24,0),@(24,0),@(0,-24),@(0,24))) {
                    if ([X6]::OverIcon($l, $x + $o[0], $y + $o[1])) { $busy = $true; break }
                }
                if (-not $busy) { $pt = @($x, $y) }
            }
            $x += 160
        }
        $y += 120
    }
}
if ($null -eq $pt) { Restore-Covering; "no empty desktop point; run Win+D first"; exit 1 }
$a = Stat
"start  icons=$($a.icons) pairs=$($a.pairs) shown=$($a.shown) dropped=$($a.dropped) failed=$($a.failed)  point=($($pt[0]),$($pt[1]))"
for ($i = 1; $i -le 6; $i++) {
    [X5]::Dbl($pt[0], $pt[1])
    Start-Sleep -Milliseconds 300
    $b = Stat
    "  dbl$i  icons=$($b.icons) pairs=$($b.pairs) shown=$($b.shown) dropped=$($b.dropped) failed=$($b.failed)"
}
$c = Stat
Restore-Covering
$dp = $c.pairs - $a.pairs; $ds = $c.shown - $a.shown
"result pairs+$dp shown+$ds dropped+$($c.dropped - $a.dropped) failed+$($c.failed - $a.failed) final=$($c.icons) start=$($a.icons)"
if (($dp -eq 6) -and ($ds -eq 6) -and ($c.icons -eq $a.icons)) { "VERDICT: PASS - 6 次快速双击全部生效且回到起点"; exit 0 }
elseif ($ds -lt $dp) { "VERDICT: FAIL - 有 $($dp - $ds) 次配对没落到切换（dropped=$($c.dropped))"; exit 1 }
# CHECK 不是 PASS：这条压力脚本没验到"6 次全落地"，自动化不能把它当成功收走（原先这里没有退出码）。
else { "VERDICT: CHECK - pairs=$dp shown=$ds final=$($c.icons)（既不是 PASS 也不算过，见上面逐行数据）"; exit 2 }
