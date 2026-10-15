# explorer 重启容错实测（TEST-REPORT §4 里第 2 条"结构上安全但没实测"的补齐）。
# 判据仍然只用独立探针：本脚本自己枚举 explorer 的窗口树读真实可见性，被测程序的自述只作交叉验证。
# 会真的 taskkill explorer（任务栏/桌面消失几秒），结束时把开跑前记录的每个资源管理器窗口按原路径重开。
# 跑法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-explorer-restart.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class E {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out P p);
    [DllImport("user32.dll")] static extern void SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] items, int cbSize);
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPD { [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPD u; }

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

    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);

    /// <summary>这一点的根窗口是不是桌面本体（Progman/WorkerW）。落点必须现扫：
    /// 桌面上叠着浏览器/IDE 时，写死的 (1700,60) 命中的是别人，那时"双击没切换"什么也证明不了。</summary>
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

    public static uint ShellPid() {
        var ls = Layers();
        if (ls.Count == 0) return 0;
        uint pid; GetWindowThreadProcessId(ls[0], out pid);
        return pid;
    }

    // 一次物理左键双击 = 5 个事件（先移动，再按下/抬起两轮）。返回系统实际接收数，0 说明注入没生效。
    public static int DoubleClickFull(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
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
# trap 必须响亮地失败：continue 会把异常咽掉、脚本照常往下跑并打印 PASS（同一族夹具在 F21 那轮吞过 4 次异常）。
# 这条脚本会真的杀 explorer，所以异常路径上还得自己把 shell 和用户开着的文件夹收回来。
trap {
    Write-Host ("   捕获异常：" + $_.Exception.Message) -ForegroundColor Red
    if (Test-Path Function:\Restore-Covering) { Restore-Covering }
    if ((@(Get-Process explorer -EA SilentlyContinue).Count) -eq 0) { Start-Process explorer.exe; Start-Sleep 3 }
    if (Test-Path Variable:\opened) {
        foreach ($u in $opened) { if (Test-Path $u) { Start-Process explorer.exe -ArgumentList "`"$u`"" } }
    }
    # 异常路径也不许把桌面留在 hidden：图标层回来了才 --show（所以放在拉起 explorer 之后）。
    try { Start-Process $exe -ArgumentList '--show' -NoNewWindow -Wait } catch { }
    exit 1
}
$coveredWin = [COV]::MinimizeCovering()
if ($coveredWin.Length -gt 0) { Start-Sleep -Milliseconds 1500; Write-Host ("   已临时最小化 {0} 个遮挡窗口（测完自动还原）" -f $coveredWin.Length) }
function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }     # 默认测仓库里这一份；只有"先退掉在场那一份"时才传别的路径
    $outFile = Join-Path $env:TEMP ("ex-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path "$outFile.err") { $text += (Get-Content "$outFile.err" -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

function Get-Diag {
    $s = (Invoke-Exe @('--status')).Text
    $m = [regex]::Match($s, 'diag\s+= ups=(\d+) pairs=(\d+) showwindow=(\d+) dropped=(\d+) toggle_failed=(\d+)')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{ ups = [int]$m.Groups[1].Value; pairs = [int]$m.Groups[2].Value
        shown = [int]$m.Groups[3].Value; dropped = [int]$m.Groups[4].Value; failed = [int]$m.Groups[5].Value }
}

# 托盘：两层口径，逐字搬 verify-shell-race 的那一套，别自创第三层。
#   Get-TrayCount      硬口径 —— 只数 Y>1130 的任务栏那一条带。本脚本刚强杀过 explorer，
#                      整棵 UIA 树里会残留点不到的幽灵按钮（实测"停了 explorer 仍数到 1"），
#                      所以"树里有没有"绝不能当判据（B18 的教训）。
#   Peek-TrayOverflow  只在硬口径数到 0 时才调：UIA Invoke 展开「显示隐藏的图标」再数一次；
#                      找不到/展不开那个按钮返回 -1 —— 那是"判不了"，不是"没有"。
#   Probe-Tray         合起来给可判读的种类：bar / overflow / absent / unknown。
function Find-OurTrayElements {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $out = @()
    foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)) {
        if ($b.Current.Name -like '桌面图标开关｜*') { $out += $b }
    }
    return ,$out
}
function Get-TrayCount {
    @(Find-OurTrayElements | Where-Object { $_.Current.BoundingRectangle.Y -gt 1130 }).Count
}
function Peek-TrayOverflow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $chev = $null
    foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)) {
        if ($e.Current.Name -like '显示隐藏的图标*') { $chev = $e; break }
    }
    if ($null -eq $chev) { return -1 }
    try {
        $inv = $chev.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $inv.Invoke()
        Start-Sleep -Milliseconds 1200
        $m = @(Find-OurTrayElements)
        try { $inv.Invoke() } catch { }
        Start-Sleep -Milliseconds 250
        return $m.Count
    } catch { return -1 }
}
function Probe-Tray {
    $bar = Get-TrayCount
    if ($bar -gt 0) { return [pscustomobject]@{ Kind = 'bar'; Bar = $bar; Overflow = $null } }
    $peek = Peek-TrayOverflow
    if ($peek -gt 0) { return [pscustomobject]@{ Kind = 'overflow'; Bar = 0; Overflow = $peek } }
    if ($peek -eq 0) { return [pscustomobject]@{ Kind = 'absent'; Bar = 0; Overflow = 0 } }
    return [pscustomobject]@{ Kind = 'unknown'; Bar = 0; Overflow = -1 }
}

$fails = @()
$notes = @()

Write-Host "== 0. 记录你开着的资源管理器窗口（结束时按原路径重开）=="
$shellApp = New-Object -ComObject Shell.Application
$opened = @()
foreach ($wnd in $shellApp.Windows()) {
    try {
        $url = $wnd.LocationURL
        if ($url -like 'file://*') { $opened += ($url -replace '^file:///', '' -replace '%20', ' ') }
    } catch { }
}
if ($opened.Count -eq 0) { Write-Host "   （没有资源管理器窗口）" }
foreach ($u in $opened) { Write-Host "   - $u" }

Write-Host "`n== 1. 基线：起实例、确认三件事在 explorer 重启前都好用 =="
# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是活动照样发生在那一份身上，
# 后面每一次 --status 都读不到 diag/gesture 行，Get-Diag/Get-GestureLine 全成 null。先按 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $null = Invoke-Exe @('--exit') -path $livePath
}
Start-Sleep -Milliseconds 800
$null = Invoke-Exe @('--exit')
Start-Process $exe
Start-Sleep -Milliseconds 1200
$inst0 = @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count
Write-Host ("   实例数 = {0}   图标层 = {1}   真实状态 = {2}   shell pid = {3}" -f $inst0, [E]::Layers().Count, [E]::State(), [E]::ShellPid())
if ($inst0 -lt 1) { throw "实例没起来，测不下去" }
$trayBefore = Probe-Tray
Write-Host ("   托盘（重启前）：判读 = {0}   任务栏带上 = {1}   溢出区 = {2}" -f $trayBefore.Kind, $trayBefore.Bar, $trayBefore.Overflow)
if ($trayBefore.Kind -eq 'overflow') { $notes += "重启前任务栏带上数不到、展开溢出区才数到 $($trayBefore.Overflow) 个：摆放是 shell 决定的，重启后仍用同一套两层口径判" }
if ($trayBefore.Kind -eq 'absent') { $notes += "重启前两层口径都数不到（任务栏带 0、溢出区 0）：基线本身就没注册上，重启后那条判据只看 bar/overflow 是否成立" }
if ($trayBefore.Kind -eq 'unknown') { $notes += "重启前：任务栏带 0 且展不开「显示隐藏的图标」=> 基线记 unknown" }

# 找一个确定压在桌面空白上的点：从屏幕右上角往里挪，避开图标区
$px = 0; $py = 0
foreach ($cx in @(1700, 1800, 1600, 960, 1400, 620, 120)) {
    foreach ($cy in @(60, 120, 300, 700, 1000)) {
        if ([E]::DesktopRootAt($cx, $cy)) { $px = $cx; $py = $cy; break }
    }
    if ($px -ne 0) { break }
}
if ($px -eq 0) { throw "现扫 35 个点没有一个落在桌面本体上（桌面被窗口盖住）—— 中止，不拿命中别人窗口的点当桌面落点" }
Write-Host ("   桌面落点现扫 = ($px,$py)")
$null = Invoke-Exe @('--show')
$base = [E]::State()
$null = [E]::DoubleClickFull($px, $py)
Start-Sleep -Milliseconds 700
$afterToggle = [E]::State()
Write-Host "   双击空白 ($px,$py) : $base -> $afterToggle"
if ($afterToggle -eq $base) { throw "重启前双击就不生效，后面的对比没有意义" }
$null = [E]::DoubleClickFull($px, $py)
Start-Sleep -Milliseconds 700
$null = Invoke-Exe @('--show')
$diagBefore = Get-Diag
Write-Host ("   重启前自述：pairs={0} shown={1}" -f $diagBefore.pairs, $diagBefore.shown)

Write-Host "`n== 2. 杀掉 explorer（任务栏/桌面会短暂消失）=="
$oldShell = [E]::ShellPid()
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
$deadline = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $deadline -and [E]::Layers().Count -gt 0) { Start-Sleep -Milliseconds 200 }
Write-Host ("   已杀：图标层数量 = {0}" -f [E]::Layers().Count)

Write-Host "== 3. 拉起 explorer 并等图标层重建 =="
$started = $false
for ($try = 1; $try -le 3; $try++) {
    if ([E]::Layers().Count -gt 0) { $started = $true; break }
    Start-Process explorer.exe -ErrorAction SilentlyContinue
    $wait = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $wait -and [E]::Layers().Count -eq 0) { Start-Sleep -Milliseconds 300 }
}
$newShell = [E]::ShellPid()
Write-Host ("   图标层 = {0}   shell pid {1} -> {2}（换进程 = {3}）" -f [E]::Layers().Count, $oldShell, $newShell, ($oldShell -ne $newShell))
if ([E]::Layers().Count -eq 0) {
    Write-Host "   !!! explorer 没恢复。手动兜底：Ctrl+Shift+Esc → 文件 → 运行新任务 → 输入 explorer.exe" -ForegroundColor Red
    throw "explorer 未恢复，测试中止（本脚本已把实例留在运行状态，不要手动退出）"
}
Start-Sleep -Seconds 3

Write-Host "`n== 4. 重启后复测：切换 / 双击 / 托盘 / 自述计数 =="
$null = Invoke-Exe @('--hide')
$hid = [E]::State()
$null = Invoke-Exe @('--show')
$vis = [E]::State()
Write-Host ("   --hide/--show : hidden? {0}   visible? {1}" -f $hid, $vis)
if ($hid -ne 'hidden') { $fails += "--hide 之后独立探针读到 $hid（新窗口句柄没被认出来）" }
if ($vis -ne 'visible') { $fails += "--show 之后独立探针读到 $vis" }

$diagMid = Get-Diag
$null = Invoke-Exe @('--show')
function Get-GestureLine {
    $s = (Invoke-Exe @('--status')).Text
    $m = [regex]::Match($s, 'gesture\s+= on_icon=(\d+) not_desktop=(\d+)(?: throttled=\d+)? last=(\w+)')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{ onIcon = [int]$m.Groups[1].Value; notDesktop = [int]$m.Groups[2].Value; last = $m.Groups[3].Value }
}

# 双击要能切换。但产品对"判不准"的口径本来就是保守不切（宁可让位也不抢用户启动程序的点击），
# explorer 刚重启那几秒正是最容易判不准的时候 —— 所以允许一次"settling 后重试"，并把原因报出来。
$reason = ""
$toggled = $false
for ($try = 1; $try -le 2; $try++) {
    $before = Get-Diag
    $gBefore = Get-GestureLine
    $null = [E]::DoubleClickFull($px, $py)
    Start-Sleep -Milliseconds 900
    $after = Get-Diag
    $gAfter = Get-GestureLine
    $st = [E]::State()
    Write-Host ("   第 {0} 次双击空白 ($px,$py) : 现在 {1}   pairs {2}->{3}  shown {4}->{5}  last={6}" -f `
        $try, $st, $before.pairs, $after.pairs, $before.shown, $after.shown, $gAfter.last)
    if ($after.shown -gt $before.shown) { $toggled = $true; break }
    $reason = $gAfter.last
    if ($gAfter.onIcon -gt $gBefore.onIcon) { $reason = "on_icon（命中测试判定点在图标上，按设计让位）" }
    elseif ($gAfter.notDesktop -gt $gBefore.notDesktop) { $reason = "not_desktop（落点被判为不在桌面本体上）" }
    elseif ($after.pairs -eq $before.pairs) { $reason = "没配出双击（pairs 未涨）" }
    Write-Host "   -> 这一轮没切，原因：$reason；等 explorer  settling 6 秒后重试一次"
    $null = Invoke-Exe @('--show')
    Start-Sleep -Seconds 6
}
if (-not $toggled) { $fails += "explorer 重启后双击始终不切换（最后原因：$reason）" }
$null = Invoke-Exe @('--show')

$trayAfter = Probe-Tray
Write-Host ("   托盘：重启前 {0}（带={1} 溢出={2}） -> 重启后 {3}（带={4} 溢出={5}）" -f `
    $trayBefore.Kind, $trayBefore.Bar, $trayBefore.Overflow, $trayAfter.Kind, $trayAfter.Bar, $trayAfter.Overflow)
# 判据与重启前数到几个无关（本脚本刚强杀过 explorer，before 那个值本身就可能来自幽灵按钮）：
# 只看「重启之后 bar 或 overflow 至少成立一个」。absent 才是 FAIL；unknown 只能记 notes。
if ($trayAfter.Kind -eq 'absent') {
    $fails += "explorer 重启后托盘图标确实没了：任务栏带上一条没有、展开溢出区也没有 => 这份 shell 里没有我们的注册（与重启前数到几个无关）"
} elseif ($trayAfter.Kind -eq 'unknown') {
    $notes += "explorer 重启后：任务栏带上 0 个，而且找不到/展不开「显示隐藏的图标」=> 这一格判不了，按 unknown 记，不算 PASS 也不算 FAIL"
}

Restore-Covering
Write-Host "`n== 5. 重开你的资源管理器窗口 =="
foreach ($u in $opened) {
    if (Test-Path $u) { Start-Process explorer.exe -ArgumentList "`"$u`"" ; Write-Host "   重开 $u" }
    else { Write-Host "   跳过（路径已不存在）：$u" -ForegroundColor Yellow }
}
$opened = @()     # 已经重开过了：后面若再抛异常，trap 不许把同一批窗口再开一遍

Write-Host "`n== 6. 收尾 =="
$null = Invoke-Exe @('--show')
Write-Host ("   剩余实例数 = {0}   真实状态 = {1}" -f @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count, [E]::State())

Write-Host "`n== 结论 =="
foreach ($m in $notes) { Write-Host "   注：$m" -ForegroundColor Cyan }
if ($fails.Count -eq 0) {
    if ($trayAfter.Kind -eq 'unknown') {
        Write-Host "VERDICT: PARTIAL - 切换/双击两条活着；托盘那条是 unknown（任务栏带 0 且展不开「显示隐藏的图标」），按 unknown 记，不给 PASS" -ForegroundColor Yellow
        exit 2
    }
    Write-Host "VERDICT: PASS - explorer 重启后切换/双击/托盘三条都活着（零缓存句柄这一设计成立）" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
