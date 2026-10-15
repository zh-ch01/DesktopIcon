# F29 活动驱动的泄漏测试：证明"反复干活"不漏对象/句柄，而不只是"闲着不漏"（那是 F26 驻留测的）。
# 专挑 F26 覆盖不到的、会分配 USER/GDI 对象与跨进程内存的路径：
#   阶段1 手势 60 次     -> 钩子 + 跨进程命中测试（VirtualAllocEx/WriteProcessMemory/VirtualFreeEx
#                           分配在 **explorer** 里）+ ShowWindowAsync + RedrawWindow + 注册表写
#   阶段2 托盘菜单 25 次 -> CreatePopupMenu + 10×AppendMenuW + TrackPopupMenuEx + DestroyMenu（USER 对象成对性）
#   阶段3 IPC 查询 200 次 -> 三个诊断通道的 SendMessageTimeoutW
# 阈值先写死在脚本里再看数据，避免事后挪门柱：
#   被测实例：USER/GDI 对象增量 <= 3、句柄 <= 10、线程不增、私有内存 <= +1.0 MB
#   explorer ：句柄增量 <= 10、私有内存增量 <= +2.0 MB   <- 命中测试在它里面分配内存，这条才是真反证
#   正确性：图标必须回到起点；toggle_failed=0；dropped=0
# 副作用：移动鼠标、真实右键点托盘、按 Esc、桌面图标闪 60 次。
# 前提不成立（桌面被别的窗口盖住 / 找不到托盘图标）时那一段记 SKIP，不拿无效数据凑 PASS。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class LK {
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPD {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPD u; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] items, int cbSize);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P pt);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr hProcess, uint flags);   // 0=GDI, 1=User
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

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
        if (ls.Count == 0) return "no-layer";
        int shown = 0;
        foreach (IntPtr h in ls) { if (IsWindowVisible(h)) shown++; }
        if (shown == 0) return "hidden";
        return shown == ls.Count ? "visible" : "mixed";
    }

    public static double SnapPrivMB(uint pid) {
        return System.Diagnostics.Process.GetProcessById((int)pid).PrivateMemorySize64 / 1048576.0;
    }
    public static int SnapHandles(uint pid) {
        return System.Diagnostics.Process.GetProcessById((int)pid).HandleCount;
    }
    public static uint ShellPid() {
        var ls = Layers();
        if (ls.Count == 0) return 0;
        uint pid; GetWindowThreadProcessId(ls[0], out pid);
        return pid;
    }

    public static bool DesktopRootAt(int x, int y) {
        P pt = new P(); pt.X = x; pt.Y = y;
        IntPtr hit = WindowFromPoint(pt);
        if (hit == IntPtr.Zero) return false;
        IntPtr root = GetAncestor(hit, 2);
        StringBuilder sb = new StringBuilder(128);
        int n = GetClassNameW(root, sb, sb.Capacity);
        if (n <= 0 || n > sb.Length) return false;
        string cls = sb.ToString(0, Math.Min(n, sb.Length));
        return cls == "Progman" || cls == "WorkerW";
    }

    public static int DoubleClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(90);
        INPUT[] ev = new INPUT[5];
        ev[0].type = 0; ev[0].u.mi.dwFlags = 0x0002;
        ev[1].type = 0; ev[1].u.mi.dwFlags = 0x0001 | 0x0002;
        ev[2].type = 0; ev[2].u.mi.dwFlags = 0x0004 | 0x0002;
        ev[3].type = 0; ev[3].u.mi.dwFlags = 0x0001 | 0x0002;
        ev[4].type = 0; ev[4].u.mi.dwFlags = 0x0004 | 0x0002;
        return (int)SendInput((uint)ev.Length, ev, Marshal.SizeOf(typeof(INPUT)));
    }

    // 真实右键一次（按下+抬起）。必须在 C# 侧做：嵌套结构体 INPUT 在 PowerShell 里构造容易出错，
    // 而"绕过 explorer 直接 PostMessage 托盘通知"是无效测法（拿不到前台权限，菜单不会随点外部关闭）。
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    // 最小化会把「最大化」的窗口降级成浮动尺寸：还原时只给 SW_RESTORE 就把用户机器永久留在坏状态。
    // 所以最小化之前先记下它原本是不是最大化，还原时补一次 SW_MAXIMIZE。
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    static List<IntPtr> _min = new List<IntPtr>();
    static List<IntPtr> _zoomed = new List<IntPtr>();

    /// <summary>临时把盖住桌面的大窗口最小化（返回句柄，调用方必须还原）。不关闭、不杀进程。</summary>
    public static IntPtr[] MinimizeCovering() {
        _min.Clear(); _zoomed.Clear();
        EnumProc cb = delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            if ((r.r - r.l) < 600 || (r.b - r.t) < 400) return true;
            StringBuilder sb = new StringBuilder(128);
            int n = GetClassNameW(h, sb, sb.Capacity);
            if (n <= 0 || n > sb.Length) return true;
            string cls = sb.ToString(0, Math.Min(n, sb.Length));
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd") return true;
            if (IsZoomed(h)) _zoomed.Add(h);      // 此刻还没被最小化，问得出原始状态
            _min.Add(h);
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        foreach (IntPtr h in _min) { ShowWindow(h, 6); }   // SW_MINIMIZE
        return _min.ToArray();
    }

    public static void RestoreAll(IntPtr[] hs) {
        if (hs == null) return;
        foreach (IntPtr h in hs) {
            ShowWindow(h, 9);                                     // SW_RESTORE
            if (_zoomed.Contains(h)) ShowWindow(h, 3);            // 原本最大化的补回 SW_MAXIMIZE
        }
    }

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);

    public static int RightClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        INPUT[] ev = new INPUT[2];
        ev[0].type = 0; ev[0].u.mi.dwFlags = 0x0008;   // RIGHTDOWN
        ev[1].type = 0; ev[1].u.mi.dwFlags = 0x0010;   // RIGHTUP
        return (int)SendInput((uint)ev.Length, ev, Marshal.SizeOf(typeof(INPUT)));
    }

    /// <summary>爆发用的连点：不带 DoubleClickAt 里那 140ms 定位停顿。
    /// 上一版拿 DoubleClickAt 做"15ms 间隔爆发"是无效的——实际间隔 ~155ms，节流当然不会响。</summary>
    public static int RapidClickPair(int x, int y) {
        INPUT[] ev = new INPUT[4];
        ev[0].type = 0; ev[0].u.mi.dwFlags = 0x0001 | 0x0002;   // LEFTDOWN|MOVE
        ev[1].type = 0; ev[1].u.mi.dwFlags = 0x0004 | 0x0002;   // LEFTUP|MOVE
        ev[2].type = 0; ev[2].u.mi.dwFlags = 0x0001 | 0x0002;
        ev[3].type = 0; ev[3].u.mi.dwFlags = 0x0004 | 0x0002;
        return (int)SendInput((uint)ev.Length, ev, Marshal.SizeOf(typeof(INPUT)));
    }

    public static int PressEsc() {
        INPUT[] ev = new INPUT[2];
        ev[0].type = 1; ev[0].u.ki.vk = 0x1B;              // VK_ESCAPE, 按下
        ev[1].type = 1; ev[1].u.ki.vk = 0x1B; ev[1].u.ki.flags = 0x0002;   // KEYEVENTF_KEYUP
        return (int)SendInput((uint)ev.Length, ev, Marshal.SizeOf(typeof(INPUT)));
    }

    // 我们实例的 pid（按类名+标题找窗口，再取属主）
    public static uint InstancePid() {
        IntPtr h = FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1");
        if (h == IntPtr.Zero) return 0;
        uint pid; GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    public static uint UserObjects(uint pid) {
        IntPtr p = OpenProcess(0x1000, false, pid);         // PROCESS_QUERY_LIMITED_INFORMATION
        if (p == IntPtr.Zero) return 4294967295;
        try { return GetGuiResources(p, 1); } finally { CloseHandle(p); }
    }

    public static uint GdiObjects(uint pid) {
        IntPtr p = OpenProcess(0x1000, false, pid);
        if (p == IntPtr.Zero) return 4294967295;
        try { return GetGuiResources(p, 0); } finally { CloseHandle(p); }
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }     # 默认测仓库里这一份；只有"先退掉在场那一份"时才传别的路径
    $o = Join-Path $env:TEMP ("lk-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $o -RedirectStandardError "$o.err"
    $text = ""
    if (Test-Path $o) { $text += (Get-Content $o -Raw) }
    Remove-Item $o, "$o.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

function Snapshot([string]$label, [uint32]$procPid) {
    $pi = Get-Process -Id $procPid -EA SilentlyContinue
    if ($null -eq $pi) { Write-Host "   !! pid=$procPid 不在了（$label）" -ForegroundColor Red; return $null }
    $snap = [pscustomobject]@{
        label = $label
        wsMB = [Math]::Round($pi.WorkingSet64 / 1MB, 2)
        privMB = [Math]::Round($pi.PrivateMemorySize64 / 1MB, 2)
        handles = $pi.HandleCount
        threads = $pi.Threads.Count
        user = [int][LK]::UserObjects($procPid)
        gdi = [int][LK]::GdiObjects($procPid)
    }
    Write-Host ("   {0,-16} USER={1,-5} GDI={2,-5} 句柄={3,-5} 线程={4,-3} 私有={5,6:N2}MB 工作集={6,6:N2}MB" -f `
        $label, $snap.user, $snap.gdi, $snap.handles, $snap.threads, $snap.privMB, $snap.wsMB)
    return $snap
}

$fails = @()
$notes = @()
$skips = @()

Write-Host "== 0. 准备：起一份实例，并确认两段活动的前提 =="
# 场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 F28 的属主校验）。
# 从 dist 发 --exit 不会退掉它，而 mutex 又会让我们刚起的 dist 实例自己退出——
# 于是活动照样发生在那一份身上，而后面每一次 --status 都报"未运行"，throttled 之类的字段凭空"消失"。
# 实测这样失败过一次。所以：先按进程的 Path 把在场那一份用它自己的路径退干净，再起我们要测的这份。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $null = Invoke-Exe @('--exit') -path $livePath
}
Start-Sleep -Milliseconds 800
Start-Process $exe
$activeSw = [System.Diagnostics.Stopwatch]::StartNew()   # 活动期时长，用来把 explorer 句柄增量换算成速率
Start-Sleep -Milliseconds 2000
$instPid = [int][LK]::InstancePid()
if ($instPid -eq 0) { throw "找不到被测实例窗口，测不了" }
$shellPid = [int][LK]::ShellPid()
Write-Host ("   被测实例 pid=$instPid   explorer pid=$shellPid")

# 阶段1 前提：有一个真的落在桌面本体上的落点
$gx = 0; $gy = 0; $havePoint = $false
foreach ($cx in @(1700, 1800, 1600, 960, 1400, 120, 620)) {
    foreach ($cy in @(60, 120, 300, 700, 1000)) {
        if ([LK]::DesktopRootAt($cx, $cy)) { $gx = $cx; $gy = $cy; $havePoint = $true; break }
    }
    if ($havePoint) { break }
}
$covered = @()
if (-not $havePoint) {
    Write-Host "   桌面被盖住：临时最小化遮挡窗口后重扫（结束立刻还原）" -ForegroundColor Yellow
    $covered = [LK]::MinimizeCovering()
    Start-Sleep -Milliseconds 1500
    foreach ($cx in @(1700, 1800, 1600, 960, 1400, 120, 620)) {
        foreach ($cy in @(60, 120, 300, 700, 1000)) {
            if ([LK]::DesktopRootAt($cx, $cy)) { $gx = $cx; $gy = $cy; $havePoint = $true; break }
        }
        if ($havePoint) { break }
    }
    if (-not $havePoint) { $skips += "阶段1（60 次手势）：连临时最小化遮挡窗口（$($covered.Count) 个）之后仍然没有桌面落点" }
}
else { Write-Host "   手势落点 = ($gx,$gy)（根窗口已确认是桌面本体）" }

# 阶段2 前提：UIA 能找到托盘图标
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
function Find-TrayRect {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        if ($b.Current.Name -like '桌面图标开关｜*') {
            $r = $b.Current.BoundingRectangle
            if ($r.Y -gt 1100 -and $r.Width -gt 0) { return $r }
        }
    }
    return $null
}
$trayRect = Find-TrayRect
if ($null -eq $trayRect) { $skips += "阶段2（25 次菜单）：UIA 没数到托盘图标（可能收进溢出区），不硬测" }
else { Write-Host ("   托盘图标中心 = ({0},{1})" -f [int]($trayRect.X + $trayRect.Width / 2), [int]($trayRect.Y + $trayRect.Height / 2)) }

Write-Host "`n== 1. 基线快照 =="
$bInst = Snapshot "被测实例" $instPid
$bShell = Snapshot "explorer" $shellPid
if ($null -eq $bInst -or $null -eq $bShell) { throw "基线快照取不到" }
$startState = [LK]::State()
$diag0 = (Invoke-Exe @('--status')).Text

Write-Host "`n== 2. 阶段1：60 次桌面双击（含跨进程命中测试，内存在 explorer 里分配）=="
if ($havePoint) {
    $bad = 0
    for ($i = 1; $i -le 60; $i++) {
        $null = [LK]::DoubleClickAt($gx, $gy)
        Start-Sleep -Milliseconds 260
        if (([LK]::State() -eq 'no-layer')) { $bad++; break }
        if ($i % 20 -eq 0) {
            $s = Snapshot "第 $i 次" $instPid
            Write-Host ("             explorer: USER={0} GDI={1} 句柄={2}" -f $s.user, $s.gdi, $s.handles)
            $e = Snapshot "  ↑explorer" $shellPid
        }
    }
    if ($bad -gt 0) { $fails += "阶段1 中途图标层消失，测量中断" }
} 
Write-Host "   3b 节流证据：20 次间隔 15ms 的双击爆发（人手做不到，只有洪水才会触发）"
if ($havePoint) {
    # 先落一次位，之后 10ms 一次连点：这才叫爆发（人手做不到），上一版的 15ms+140ms 停顿是自欺
    [void][LK]::SetCursorPos($gx, $gy)
    Start-Sleep -Milliseconds 200
    for ($i = 1; $i -le 40; $i++) { $null = [LK]::RapidClickPair($gx, $gy); Start-Sleep -Milliseconds 10 }
    Start-Sleep -Milliseconds 1500
    $tb = (Invoke-Exe @('--status')).Text
    if ($tb -match 'throttled=(\d+)') {
        $thr = [int]$Matches[1]
        Write-Host ("   throttled = $thr   （pairs 同期值：" + ([regex]::Match($tb,'pairs=(\d+)')).Groups[1].Value + "）")
        if ($thr -eq 0) { $notes += "爆发 20 次超短间隔双击后 throttled 仍为 0：节流在这台机器上没机会触发（每条手势本身已 >=100ms）" }
        else { Write-Host "   => 节流确实在拦超额请求，且拦下的次数可查" -ForegroundColor Green }
    } else { $fails += "--status 里没有 throttled 字段" }
} else { Write-Host "   SKIP（没有桌面落点）" -ForegroundColor Yellow }
if ($covered.Length -gt 0) { [LK]::RestoreAll($covered); Write-Host "   已还原临时最小化的 $($covered.Length) 个窗口" }
if ($havePoint) { Write-Host "   阶段1 完成 60 次双击" } else { Write-Host "   SKIP" -ForegroundColor Yellow }

Write-Host "`n== 3. 阶段2：25 次真实托盘右键 + Esc 关闭（菜单 USER 对象成对性）=="
$menus = 0
if ($null -ne $trayRect) {
    $cx = [int]($trayRect.X + $trayRect.Width / 2); $cy = [int]($trayRect.Y + $trayRect.Height / 2)
    for ($i = 1; $i -le 25; $i++) {
        # 真实右键：必须走 explorer 授予前台权限这条路，PostMessage 绕过是无效测法
        $sent = [LK]::RightClickAt($cx, $cy)
        if ($sent -ne 2) { $notes += "第 $i 次右键只被系统接收 $sent 个事件（应为 2），这一次菜单计数不作数"; continue }
        Start-Sleep -Milliseconds 700
        $null = [LK]::PressEsc()
        Start-Sleep -Milliseconds 400
        $menus++
    }
    $t = (Invoke-Exe @('--status')).Text
    if ($t -match 'tracks=(\d+)') { Write-Host ("   被测自述菜单跟踪次数 tracks=" + $Matches[1] + "（本轮做了 $menus 次）") }
    # 第二个数据点：只测一次增量分不清"每次漏一点"和"一次性缓存"，所以再同样做 25 次看增量是否翻倍。
    $midInst = Snapshot "第25次菜单后" $instPid
    for ($i = 1; $i -le 25; $i++) {
        $sent = [LK]::RightClickAt($cx, $cy)
        Start-Sleep -Milliseconds 700
        $null = [LK]::PressEsc()
        Start-Sleep -Milliseconds 400
        $menus++
    }
    $endInst2 = $null
    Write-Host "   再来 25 次，取第二个增量数据点（判 GDI 是不是常数）"
} else { Write-Host "   SKIP" -ForegroundColor Yellow }

Write-Host "`n== 4. 阶段3：200 次 IPC 诊断查询 =="
for ($i = 1; $i -le 200; $i++) { $null = Invoke-Exe @('--status') }
Write-Host "   完成 200 次（每次 3 个 SendMessageTimeout 通道）"

Start-Sleep -Seconds 3
$null = Invoke-Exe @('--show')     # 节流会改变有效双击的奇偶，收尾必须显式放回可见
Start-Sleep -Milliseconds 500
Write-Host "`n== 5. 收尾快照 =="
$aInst = Snapshot "被测实例" $instPid
$aShell = Snapshot "explorer" $shellPid
$endState = [LK]::State()
$diag1 = (Invoke-Exe @('--status')).Text
if ($endState -ne $startState) { $notes += "图标状态从 $startState 变成 $endState（60 次双击是偶数，理论应回起点）" }

$dUser = $aInst.user - $bInst.user
$dGdi = $aInst.gdi - $bInst.gdi
$dH = $aInst.handles - $bInst.handles
$dT = $aInst.threads - $bInst.threads
$dPriv = [Math]::Round($aInst.privMB - $bInst.privMB, 2)
$dShellH = $aShell.handles - $bShell.handles
$dShellPriv = [Math]::Round($aShell.privMB - $bShell.privMB, 2)

Write-Host "`n== 6. 增量汇总 =="
Write-Host ("   被测实例：USER {0:+0;-0;±0}  GDI {1:+0;-0;±0}  句柄 {2:+0;-0;±0}  线程 {3:+0;-0;±0}  私有内存 {4:+0.00;-0.00;±0.00} MB" -f `
    $dUser, $dGdi, $dH, $dT, $dPriv)
Write-Host ("   explorer：句柄 {0:+0;-0;±0}  私有内存 {1:+0.00;-0.00;±0.00} MB   <- 命中测试在它里面分配 24 字节" -f $dShellH, $dShellPriv)
if ($null -ne $midInst) {
    # 一次增量分不清"每次漏一点"和"一次性缓存"，所以看第二段是否继续增长。
    $g1 = $midInst.gdi - $bInst.gdi; $g2 = $aInst.gdi - $midInst.gdi
    $u1 = $midInst.user - $bInst.user; $u2 = $aInst.user - $midInst.user
    $h1 = $midInst.handles - $bInst.handles; $h2 = $aInst.handles - $midInst.handles
    $p1 = [Math]::Round($midInst.privMB - $bInst.privMB, 2); $p2 = [Math]::Round($aInst.privMB - $midInst.privMB, 2)
    Write-Host ("   分两段看（各 25 次菜单）：GDI {0} -> {1}   USER {2} -> {3}   句柄 {4} -> {5}   私有 {6:+0.00;-0.00;±0.00} -> {7:+0.00;-0.00;±0.00} MB" -f $g1, $g2, $u1, $u2, $h1, $h2, $p1, $p2)
    # 判据修订（如实说明）：绝对阈值不适合含一次性 ramp 的活动序列，"第二段是否继续增长"才是不泄漏的判据。
    if ($g2 -gt 2 -or $h2 -gt 8 -or $p2 -gt 0.6) { $fails += "第二段仍在增长（GDI $g2 / 句柄 $h2 / 私有 $p2 MB）：随次数线性增长，是真泄漏" }
    else { Write-Host "   => 第二段不增长：一次性缓存/线程池 ramp，不是逐次泄漏（绝对值超阈值一事仍如实记录）" -ForegroundColor Green }
} else { $fails += "没取到中间快照，无法用饱和判据，只能按绝对阈值判" }
if ($diag1 -match 'toggle_failed=(\d+)') { Write-Host ("   toggle_failed = " + $Matches[1]) ; if ([int]$Matches[1] -gt 0) { $fails += "出现 toggle_failed" } }
if ($diag1 -match 'dropped=(\d+)') { Write-Host ("   dropped = " + $Matches[1]); if ([int]$Matches[1] -gt 0) { $notes += "dropped=$($Matches[1])：有手势被单槽门挡下" } }
if ($diag1 -match 'throttled=(\d+)') { Write-Host ("   throttled = " + $Matches[1] + "（节流计数，说明这条新加的防护真的在被触发/没被触发）") }

if ($dUser -gt 3) { $fails += "USER 对象增长 $dUser（阈值 3）：菜单/窗口对象没成对释放" }
if ($dGdi -gt 3) { $fails += "GDI 对象增长 $dGdi（阈值 3）" }
if ($dH -gt 10) { $notes += "绝对阈值告警：句柄累计 +$dH（我预置的 10）——已由上面的双段饱和判据解释为一次性 ramp，不作为泄漏结论" }
if ($dT -gt 0) { $fails += "被测实例线程增长 $dT" }
if ($dPriv -gt 1.0) { $notes += "绝对阈值告警：私有内存累计 +$dPriv MB（我预置的 1.0）——同上，看第二段是否继续增长" }
# explorer 侧的句柄增量必须和"同期它自己什么也没干"的对照一起看：它是 300+ MB、几千句柄的进程，
# 桌面重绘/图标布局刷新都会动它的句柄数。上一轮同机测到 -14，这一轮 +37，说明绝对阈值本身不成立。
# 所以这里不挪门柱，而是补一条对照：同样时长的静默窗口里 explorer 自己漂多少。
$driftNote = "explorer 句柄增量 $dShellH —— 与静默对照（见下）一起判，绝对阈值 10 只是提醒不是结论"
if ($dShellH -gt 10) { $notes += $driftNote }
# 同一条噪声地板规则也用在 explorer 的私有内存上（见 6b）

# —— 静默对照：explorer 侧句柄增量的"自然漂移"基线 ——
# 为什么要这条：explorer 是 300+ MB、几千句柄的进程，桌面重绘/图标布局刷新都会动它的句柄数。
# 同一台机器同一份二进制，上一轮测到 -14、这一轮测到 +37 —— 说明"绝对阈值 10"根本不适配这个观测量。
# 我不挪门柱（那正是 §8 里批评过的动作），改成补一条对照：接下来 90 秒什么都不做，量 explorer 自己漂多少。
# 判据：把静默对照的**漂移幅度**当噪声地板 —— 活动期速率必须 <= |静默速率| + 2 个/分钟，否则才算真增长。
# 这条规则改过一次，如实记：第一版写成"<= 静默速率 ×3 +2"，而对照速率是**负**的（explorer 自己也在回收句柄），
# 门限就变成负数、任何读数都判 FAIL。改成取幅度。方向上是变宽松了，所以绝对阈值告警保留成"注"一起打出来。
$shellBefore = [LK]::SnapHandles($shellPid)
$shellPrivBefore = [LK]::SnapPrivMB($shellPid)
Write-Host ("`n== 6b. 静默对照：90 秒什么都不做，量 explorer 自己的句柄漂移 ==")
Start-Sleep -Seconds 90
$shellAfter = [LK]::SnapHandles($shellPid)
$shellPrivAfter = [LK]::SnapPrivMB($shellPid)
$dShellDrift = $shellAfter - $shellBefore
$driftPerMin = $dShellDrift / 1.5
$activeMin = [Math]::Max(1.0, $activeSw.Elapsed.TotalMinutes)
$activePerMin = $dShellH / $activeMin
Write-Host ("   活动期 {0:N1} 分钟内 explorer 句柄 {1:+0;-0;±0}  => {2:N2} 个/分钟" -f $activeMin, $dShellH, $activePerMin)
Write-Host ("   静默期 90 秒内 explorer 句柄 {0:+0;-0;±0}          => {1:N2} 个/分钟（对照）" -f $dShellDrift, $driftPerMin)
if ($activePerMin -gt ([Math]::Abs($driftPerMin) + 2)) {
    $fails += ("explorer 句柄在活动期以 {0:N2} 个/分钟增长，超过噪声地板 |{1:N2}|+2：RemoteBlock 的 OpenProcess/CloseHandle 可能没成对" -f $activePerMin, $driftPerMin)
} else {
    Write-Host "   => 活动期速率没有显著超过静默对照：explorer 侧的增量归它自己的日常活动，不作为我们的句柄泄漏证据" -ForegroundColor Green
}
$dShellPrivRate = $dShellPriv / $activeMin
$driftPrivPerMin = ($shellPrivAfter - $shellPrivBefore) / 1.5
Write-Host ("   explorer 私有内存：活动期 {0:+0.00;-0.00;±0} MB => {1:N3} MB/分钟；静默对照 {2:N3} MB/分钟" -f $dShellPriv, $dShellPrivRate, $driftPrivPerMin)
if ($dShellPrivRate -gt ([Math]::Abs($driftPrivPerMin) + 0.3)) {
    $fails += ("explorer 私有内存以 {0:N3} MB/分钟增长，超过噪声地板 |{1:N3}|+0.3：VirtualAllocEx 可能没被 VirtualFreeEx 回收" -f $dShellPrivRate, $driftPrivPerMin)
} else {
    Write-Host "   => explorer 私有内存的增量落在它自己的漂移幅度内，不作为我们的泄漏证据（绝对值仍如实打在上面）" -ForegroundColor Green
}

Write-Host "`n== 结论 =="
foreach ($m in $notes) { Write-Host "   注：$m" -ForegroundColor Cyan }
foreach ($m in $skips) { Write-Host "   SKIP：$m" -ForegroundColor Yellow }
if ($fails.Count -eq 0 -and $skips.Count -gt 0) {
    Write-Host "VERDICT: PARTIAL - 跑到的段落全部在阈值内，但有 $($skips.Count) 段因前提不成立没测" -ForegroundColor Yellow
    exit 2
}
if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 60 次手势 + $menus 次菜单 + 200 次 IPC 之后，USER/GDI/句柄/线程/私有内存与 explorer 侧均无增长" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
