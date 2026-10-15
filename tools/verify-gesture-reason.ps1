# 证明"最近一次双击的结局"这个自证字段真的在分辨原因，而不是永远报 toggled。
# 两条相反的路径都在一次跑里命中：
#   A) 双击落在一个普通应用窗口里（记事本）=> 必须记成 not_desktop，且不得切换桌面图标；
#   B) 双击落在桌面空白上               => 必须记成 toggled，且 showwindow 计数 +1。
# 只看不切：A 组那两下点在记事本的客户区空白上，不碰任何按钮；跑完关掉记事本。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class R {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] items, int cbSize);
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPD { [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPD u; }

    public static string IconState() {
        IntPtr progman = FindWindowW("Progman", null);
        IntPtr view = progman == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (view == IntPtr.Zero) return "no-defview";
        IntPtr lv = FindWindowExW(view, IntPtr.Zero, "SysListView32", null);
        if (lv == IntPtr.Zero) return "no-iconlayer";
        return IsWindowVisible(lv) ? "visible" : "hidden";
    }

    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);

    // 断言"这一双击确实点在我们自己的窗口上"：拿光标点处顶层窗口所属的进程号去比。
    public static uint PidAt(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr hit = WindowFromPoint(pt);
        if (hit == IntPtr.Zero) return 0;
        IntPtr root = GetAncestor(hit, 2);   // GA_ROOT
        uint pid; GetWindowThreadProcessId(root, out pid);
        return pid;
    }

    /// <summary>这一点的根窗口是不是桌面本体（Progman/WorkerW）。
    /// 落点必须现扫：桌面上叠着浏览器/IDE 窗口时，写死的"空白点"命中的是别人，
    /// 那时"双击没切换"什么也证明不了。（gesture-reason / explorer-restart 都曾因写死坐标而误判）</summary>
    public static bool DesktopRootAt(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr hit = WindowFromPoint(pt);
        if (hit == IntPtr.Zero) return false;
        IntPtr root = GetAncestor(hit, 2);
        if (root == IntPtr.Zero) return false;
        StringBuilder sb = new StringBuilder(128);
        int n = GetClassNameW(root, sb, sb.Capacity);
        if (n <= 0) return false;
        string cls = sb.ToString(0, Math.Min(n, sb.Length));
        return cls == "Progman" || cls == "WorkerW";
    }

    // B 组的落点必须"既不盖在别的窗口上、也不压在图标上"。只验根窗口是不够的：
    // 那样挑出来的点可能正好在某个桌面图标上，产品判 on_icon 是**正确**行为，
    // 而夹具会把它报成"空白双击没切换"（实测就误报过一次）。
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref P p);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, UIntPtr s, uint t, uint pr);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, UIntPtr s, uint f);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr b, byte[] d, UIntPtr s, out UIntPtr w);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr b, byte[] d, UIntPtr s, out UIntPtr r);
    [DllImport("user32.dll")] static extern bool SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint to, out IntPtr res);

    public static IntPtr IconList() {
        IntPtr progman = FindWindowW("Progman", null);
        IntPtr d = FindWindowExW(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (d == IntPtr.Zero) {
            IntPtr w = IntPtr.Zero;
            while (true) {
                w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
                if (w == IntPtr.Zero) break;
                d = FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (d != IntPtr.Zero) break;
            }
        }
        return d == IntPtr.Zero ? IntPtr.Zero : FindWindowExW(d, IntPtr.Zero, "SysListView32", null);
    }

    // 返回 true = 这一点压在图标/标签上；测不出来一律当 true（宁可不判"空白"）
    public static bool OverIcon(IntPtr l, int sx, int sy) {
        if (l == IntPtr.Zero) return true;
        P pt = new P(); pt.X = sx; pt.Y = sy;
        ScreenToClient(l, ref pt);
        uint pid; GetWindowThreadProcessId(l, out pid);
        IntPtr proc = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);
        if (proc == IntPtr.Zero) return true;
        try {
            IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, (UIntPtr)24, 0x3000, 0x04);
            if (mem == IntPtr.Zero) return true;
            try {
                byte[] payload = new byte[24];
                BitConverter.GetBytes(pt.X).CopyTo(payload, 0);
                BitConverter.GetBytes(pt.Y).CopyTo(payload, 4);
                UIntPtr junk;
                if (!WriteProcessMemory(proc, mem, payload, (UIntPtr)24, out junk)) return true;
                IntPtr res;
                if (!SendMessageTimeoutW(l, 0x1039, IntPtr.Zero, mem, 0x0002, 400, out res)) return true;
                byte[] back = new byte[24];
                if (!ReadProcessMemory(proc, mem, back, (UIntPtr)24, out junk)) return true;
                uint flags = BitConverter.ToUInt32(back, 8);
                return (flags & 0x0006) != 0;      // ONITEMICON | ONITEMLABEL，绝不含 NOWHERE(0x1)
            } finally { VirtualFreeEx(proc, mem, UIntPtr.Zero, 0x8000); }
        } finally { CloseHandleSafe(proc); }
    }
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static void CloseHandleSafe(IntPtr h) { CloseHandle(h); }

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
// 自包含的"临时让出桌面"helper：桌面被全屏窗口（IDE/浏览器）盖住时，任何"双击落在桌面空白/图标上"
// 的断言都会失真——命中的其实是别人的窗口，那时"双击没切换"什么也证明不了（这几个脚本就因此误判过）。
// 开跑前临时最小化遮挡窗口，收尾（含抛异常，见 trap）一律还原。只 ShowWindow，不关闭、不杀进程。
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
            System.Text.StringBuilder sb = new StringBuilder(128);
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
# trap 必须响亮地失败。原先写成 continue：异常被咽掉、脚本照常往下跑并打印 PASS ——
# F21 那一条就在一轮吞掉 4 次异常的日志里"通过"过，判据当时是作废的。现在打印异常并 exit 1，窗面照样还原。
trap {
    Write-Host ("   捕获异常：" + $_.Exception.Message) -ForegroundColor Red
    if (Test-Path Function:\Restore-Covering) { Restore-Covering }
    if (Test-Path Variable:\decoy) { try { Stop-Process -Id $decoy.Id -Force } catch { } }
    # 异常路径也不许把桌面留在 hidden：用户下次看桌面才发现图标没了，那是测试造的债。
    try { Start-Process $exe -ArgumentList '--show' -NoNewWindow -Wait } catch { }
    exit 1
}
$coveredWin = [COV]::MinimizeCovering()
if ($coveredWin.Length -gt 0) { Start-Sleep -Milliseconds 1500; Write-Host ("   已临时最小化 {0} 个遮挡窗口（测完自动还原）" -f $coveredWin.Length) }
function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }     # 默认测仓库里这一份；只有"先退掉在场那一份"时才传别的路径
    $outFile = Join-Path $env:TEMP ("gr-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path "$outFile.err") { $text += (Get-Content "$outFile.err" -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

function Get-Stats {
    $s = (Invoke-Exe @('--status')).Text
    $d = [regex]::Match($s, 'diag\s+= ups=(\d+) pairs=(\d+) showwindow=(\d+) dropped=(\d+) toggle_failed=(\d+)')
    $g = [regex]::Match($s, 'gesture\s+= on_icon=(\d+) not_desktop=(\d+)(?: throttled=\d+)? last=(\w+)')
    if (-not ($d.Success -and $g.Success)) { return $null }
    return [pscustomobject]@{ pairs = [int]$d.Groups[2].Value; shown = [int]$d.Groups[3].Value
        onIcon = [int]$g.Groups[1].Value; notDesktop = [int]$g.Groups[2].Value; last = $g.Groups[3].Value }
}

$fails = @()
$notes = @()

# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是活动照样发生在那一份身上，
# 后面每一次 --status 都读不到 diag/gesture 行，那两行整块"凭空消失"。先按进程的 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $null = Invoke-Exe @('--exit') -path $livePath
}
Start-Sleep -Milliseconds 800
if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -eq 0) { Start-Process $exe; Start-Sleep -Milliseconds 1200 }
$null = Invoke-Exe @('--show')

Write-Host "== A) 双击点在「我们自己拥有的」窗口里：应当判 not_desktop 且绝不切换 =="
# 为什么不用记事本当靶子：Win11 的记事本是单进程多标签，而且会把你上一次会话（可能正开着稿子）
# 一起恢复出来——实测就这么把探针文件开进了你已有的 Notepad 进程里，关不干净还会误伤你的标签页。
# 所以靶面改成自建窗口：一个子 powershell 里的 WinForms 窗体，位置/尺寸/生死都完全由本脚本掌握。
$decoyPs = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = New-Object Windows.Forms.Form
$f.Text = 'DesktopIconToggle 落点探针（自动关闭，可忽略）'
$f.FormBorderStyle = 'Fixed3D'
$f.ShowInTaskbar = $false
$f.TopMost = $true
$f.StartPosition = 'Manual'
$f.Location = New-Object System.Drawing.Point(700, 400)
$f.Size = New-Object System.Drawing.Size(500, 360)
$f.BackColor = [System.Drawing.Color]::FromArgb(255, 238, 238, 238)
$f.Show()
$f.TopMost = $true
$f.BringToFront()
$f.Activate()
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
'@
$decoyFile = Join-Path $env:TEMP ("gesture-decoy-" + [Guid]::NewGuid().ToString("N") + ".ps1")
Set-Content -Path $decoyFile -Value $decoyPs -Encoding UTF8
# 子脚本自己先过一遍语法：它要是解析不过，窗口根本不会出现，而 A 组会拿着"落点不在桌面上"去证明一件没发生的事。
$decoyErrs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($decoyFile, [ref]$null, [ref]$decoyErrs)
if ($decoyErrs.Count -gt 0) {
    throw "靶面子脚本自身有 $($decoyErrs.Count) 处语法错误（第 1 条：$($decoyErrs[0].Message)），窗口根本不会出现"
}
# 不要给这个子进程加 -WindowStyle Hidden：实测加了它之后，光标点 (950,560) 命中的根窗口属于 explorer
# 而不是靶面子进程，也就是那个窗体根本没显示出来（原因没查，结论是"别加"）。
# 下面那道哨兵断言就是为了把这种情况当场拦下来，而不是让 A 组拿着桌面落点去证明"落点不在桌面上"。
$decoy = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $decoyFile) -PassThru
$npX = 950; $npY = 560
$owner = 0
for ($try = 0; $try -lt 20; $try++) {          # 靶面窗口要等它真的开到最上层，机器负载高时 3 秒不够
    Start-Sleep -Milliseconds 500
    $owner = [R]::PidAt($npX, $npY)
    if ($owner -eq $decoy.Id) { break }
}
Write-Host ("   靶面窗口子进程 pid = {0}   点 ({1},{2}) 处的顶层窗口属于 pid = {3}（等了 {4} 次）" -f $decoy.Id, $npX, $npY, $owner, ($try + 1))
if ($owner -ne $decoy.Id) {
    Stop-Process -Id $decoy.Id -Force -ErrorAction SilentlyContinue
    throw "靶面没到位：($npX,$npY) 处的窗口属于 pid=$owner 而不是我们的 pid=$($decoy.Id)，A 组证据会失真，直接中止"
}

$before = Get-Stats
if ($before -eq $null) { throw "--status 里没有 diag/gesture 字段，被测程序不对着新版二进制测不了" }
$stateBefore = [R]::IconState()
$recv = [R]::DoubleClickAt($npX, $npY)
Start-Sleep -Milliseconds 900
$after = Get-Stats
$stateAfter = [R]::IconState()
Write-Host ("   注入事件数 = {0}（应为 5）  点在 ({1},{2})" -f $recv, $npX, $npY)
Write-Host ("   pairs {0}->{1}   shown {2}->{3}   not_desktop {4}->{5}   last={6}" -f `
    $before.pairs, $after.pairs, $before.shown, $after.shown, $before.notDesktop, $after.notDesktop, $after.last)
if ($recv -ne 5) { $fails += "注入只被接收 $recv 个事件，A 组证据无效" }
if ($after.pairs -le $before.pairs) { $fails += "pairs 没涨：这两下压根没被配成双击，A 组证据无效" }
if ($after.shown -ne $before.shown) { $fails += "双击别的程序的窗口却切换了桌面图标（shown $($before.shown)->$($after.shown)）" }
if ($stateAfter -ne $stateBefore) { $fails += "桌面图标状态被改了：$stateBefore -> $stateAfter" }
if ($after.notDesktop -le $before.notDesktop) { $fails += "not_desktop 计数没涨：落点判定没被记进自证" }
if ($after.last -ne 'not_desktop') { $fails += "last 报的是 '$($after.last)'，应为 not_desktop" }

# 靶面是本脚本自己生的子 powershell，只收它自己，不碰任何第三方进程。
if (-not $decoy.HasExited) { Stop-Process -Id $decoy.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $decoyFile -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400
$decoyGone = $decoy.HasExited
Write-Host ("   靶面窗口已关闭 = {0}" -f $decoyGone)
if (-not $decoyGone) { $notes += "靶面子进程没关掉，pid=$($decoy.Id)" }

Restore-Covering
Write-Host "`n== B) 双击点在桌面空白：应当判 toggled 且真的切换 =="
$null = Invoke-Exe @('--show')
$before = Get-Stats
$stateBefore = [R]::IconState()
$px0 = 0; $py0 = 0
$list0 = [R]::IconList()
foreach ($cx in @(1700, 1800, 1600, 960, 1400, 620, 120)) {
    foreach ($cy in @(60, 120, 300, 700, 1000)) {
        if (-not [R]::DesktopRootAt($cx, $cy)) { continue }
        $busy = $false
        foreach ($o in @(@(0,0),@(-24,0),@(24,0),@(0,-24),@(0,24))) {
            if ([R]::OverIcon($list0, $cx + $o[0], $cy + $o[1])) { $busy = $true; break }
        }
        if (-not $busy) { $px0 = $cx; $py0 = $cy; break }
    }
    if ($px0 -ne 0) { break }
}
if ($px0 -eq 0) { throw "现扫 35 个点没有一个既在桌面本体上、又不压图标（±24px 内也没图标）—— B 组测不了" }
Write-Host ("   桌面落点现扫 = ($px0,$py0)")
$recv = [R]::DoubleClickAt($px0, $py0)
Start-Sleep -Milliseconds 900
$after = Get-Stats
$stateAfter = [R]::IconState()
Write-Host ("   注入事件数 = {0}  pairs {1}->{2}   shown {3}->{4}   on_icon {5}->{6}   last={7}" -f `
    $recv, $before.pairs, $after.pairs, $before.shown, $after.shown, $before.onIcon, $after.onIcon, $after.last)
Write-Host ("   桌面真实状态（独立探针）：{0} -> {1}" -f $stateBefore, $stateAfter)
if ($after.shown -le $before.shown) { $fails += "桌面空白双击没切换：shown 仍是 $($after.shown)（last=$($after.last)）" }
if ($after.last -ne 'toggled') { $fails += "last 报的是 '$($after.last)'，应为 toggled" }
if ($stateBefore -eq $stateAfter) { $fails += "shown 涨了但独立探针读到的可见性没变（$stateBefore）" }

$null = Invoke-Exe @('--show')
Write-Host ("`n收尾：桌面图标 = {0}" -f [R]::IconState())

Restore-Covering

Write-Host "`n== 结论 =="
foreach ($m in $notes) { Write-Host "   注：$m" -ForegroundColor Cyan }
if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 同一个 last 字段在两条相反路径上分别报出 not_desktop / toggled，自证字段真的在分辨原因" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
