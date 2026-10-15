# F27：图标保护（双击落在图标上 => 不许切换）在**已发布二进制**上的端到端断言。
#
# 为什么走 IPC 而不是真鼠标：在图标可见的状态下真的双击一个桌面快捷方式，就会把它启动起来——
# 测试无权在用户机器上随手打开一堆程序。而钩子那条路（真/注入鼠标）已经由 F1 F2 F17 F21 用真实点击验过，
# 它喂给 StartGesture 的参数与本脚本投的完全同构（同一个打包格式、同一个 fromRealMouse=1）。
# 本脚本要单独钉住的只有一件事：**命中测试说"压在图标上"时，那条链必须停手**。
#
# 实验设计：输入通道固定不变（同一个 WM_APP_GESTURE），唯一变量是落点压不压图标 —— 两条断言互为对照。
# 反向对照（落空白必须切换）也在这里做一遍，否则"没切换"可能只是因为整条链根本没跑。
#
# 判据一律用独立探针：自己的 LVM_SUBITEMHITTEST 决定"这一点压没压图标"，自己的 IsWindowVisible(SysListView32)
# 决定"图标在不在"；被测程序的 gesture/showwindow 只作为交叉验证和"是哪一步拦下的"的署名。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = Join-Path (Get-Location) 'dist\DesktopIconToggle.exe'

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class IG {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }

    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint g);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint to, out IntPtr r);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int idx);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, UIntPtr s, uint t, uint pr);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, UIntPtr s, uint f);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr b, byte[] d, UIntPtr s, out UIntPtr w);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr b, byte[] d, UIntPtr s, out UIntPtr r);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint LVM_GETITEMCOUNT = 0x1004;
    // 0x1010 = LVM_FIRST+16；写错时消息不生效、读回全零，锚点会假称 (0,0)
    const uint LVM_GETITEMPOSITION = 0x1010;
    const uint LVM_SUBITEMHITTEST = 0x1039;      // B3 的教训：这条消息号写错过一次，整条保护空转
    const uint LVHT_NOWHERE = 0x1;
    const uint LVHT_ONITEMICON = 0x2;
    const uint LVHT_ONITEMLABEL = 0x4;
    const uint PROCESS_RW = 0x0008 | 0x0010 | 0x0020 | 0x0400;   // VM_OPERATION|VM_READ|VM_WRITE|QUERY_LIMITED

    // 实例的消息窗口：类名 + 标题一起匹配（B11），只按标题会把 WM_APP_GESTURE 投给陌生程序
    public static IntPtr Ipc() {
        return FindWindowExW(IntPtr.Zero, IntPtr.Zero, "DesktopIconToggle.MessageWindow.v1", "DesktopIconToggle.Ipc.v1");
    }

    public static IntPtr IconList() {
        IntPtr p = FindWindowW("Progman", null);
        IntPtr d = FindWindowExW(p, IntPtr.Zero, "SHELLDLL_DefView", null);
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

    // 独立探针：图标层本身可见吗（只信 SysListView32，壁纸层另说）
    public static bool IconsShown(IntPtr l) { return l != IntPtr.Zero && IsWindowVisible(l); }

    public static int Items(IntPtr l) {
        IntPtr r;
        if (!SendMessageTimeoutW(l, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero, 0x0002, 400, out r)) return -1;
        return (int)r.ToInt64();
    }

    // 命中测试：自己分配内存、自己读写目标进程，返回值 = LVHT_* 位；测不出来返回 -1（调用方必须放弃而不是猜）
    public static long HitFlags(IntPtr l, int sx, int sy) {
        POINT pt = new POINT(); pt.X = sx; pt.Y = sy;
        ClientToScreen(l, ref pt);
        uint pid; GetWindowThreadProcessId(l, out pid);
        IntPtr proc = OpenProcess(PROCESS_RW, false, pid);
        if (proc == IntPtr.Zero) return -1;
        try {
            IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, (UIntPtr)24, 0x3000, 0x04);
            if (mem == IntPtr.Zero) return -1;
            try {
                byte[] payload = new byte[24];
                BitConverter.GetBytes(pt.X).CopyTo(payload, 0);
                BitConverter.GetBytes(pt.Y).CopyTo(payload, 4);
                UIntPtr junk;
                if (!WriteProcessMemory(proc, mem, payload, (UIntPtr)24, out junk)) return -1;
                IntPtr res;
                if (!SendMessageTimeoutW(l, LVM_SUBITEMHITTEST, IntPtr.Zero, mem, 0x0002, 400, out res)) return -1;
                byte[] back = new byte[24];
                if (!ReadProcessMemory(proc, mem, back, (UIntPtr)24, out junk)) return -1;
                return (long)BitConverter.ToUInt32(back, 8);
            } finally { VirtualFreeEx(proc, mem, UIntPtr.Zero, 0x8000); }
        } finally { CloseHandle(proc); }
    }

    public static bool OnIcon(IntPtr l, int x, int y) {
        long f = HitFlags(l, x, y);
        return f > 0 && (f & (LVHT_ONITEMICON | LVHT_ONITEMLABEL)) != 0;
    }

    public static bool OnDesktop(int x, int y) {
        POINT p = new POINT(); p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p); if (h == IntPtr.Zero) return false;
        IntPtr root = GetAncestor(h, 2); if (root == IntPtr.Zero) return false;
        StringBuilder sb = new StringBuilder(64);
        int n = GetClassNameW(root, sb, sb.Capacity);
        if (n <= 0) return false;
        string c = sb.ToString(0, Math.Min(n, sb.Length));
        return c == "Progman" || c == "WorkerW";
    }

    // 图标锚点：LVM_GETITEMPOSITION 给的是条目左上角（客户区），真正的图标格子在它右下方一片，
    // 所以拿到锚点后在附近小范围试，用**自己的**命中测试确认压上了才认。
    public static string IconPoint(out int ox, out int oy) {
        ox = 0; oy = 0;
        IntPtr l = IconList();
        if (l == IntPtr.Zero) return "(图标层不在)";
        int n = Items(l);
        if (n <= 0) return "(桌面没有图标项，条数=" + n + ")";
        uint pid; GetWindowThreadProcessId(l, out pid);
        IntPtr proc = OpenProcess(PROCESS_RW, false, pid);
        if (proc == IntPtr.Zero) return "(打不开 explorer 进程)";
        try {
            IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, (UIntPtr)24, 0x3000, 0x04);
            if (mem == IntPtr.Zero) return "(VirtualAllocEx 失败)";
            try {
                int[] dxs = new int[] { 24, 24, 24, 12, 36, 12, 36, 48, 12, 48 };
                int[] dys = new int[] { 20, 32, 44, 20, 20, 32, 32, 32, 44, 44 };
                UIntPtr junk;
                for (int i = 0; i < n; i++) {
                    byte[] payload = new byte[24];
                    if (!WriteProcessMemory(proc, mem, payload, (UIntPtr)24, out junk)) continue;
                    IntPtr res;
                    if (!SendMessageTimeoutW(l, LVM_GETITEMPOSITION, (IntPtr)i, mem, 0x0002, 400, out res)) continue;
                    if (res == IntPtr.Zero) continue;                  // 返回 FALSE = 这一项取不到位置
                    byte[] back = new byte[24];
                    if (!ReadProcessMemory(proc, mem, back, (UIntPtr)24, out junk)) continue;
                    POINT a = new POINT();
                    a.X = BitConverter.ToInt32(back, 0);
                    a.Y = BitConverter.ToInt32(back, 4);
                    ClientToScreen(l, ref a);
                    for (int k = 0; k < dxs.Length; k++) {
                        int x = a.X + dxs[k], y = a.Y + dys[k];
                        if (!OnDesktop(x, y)) continue;               // 被别的窗口盖住了，落点不算桌面
                        if (!OnIcon(l, x, y)) continue;
                        ox = x; oy = y;
                        return "第" + i + "项 锚点=(" + a.X + "," + a.Y + ") 命中=(" + x + "," + y + ") flags=0x" + HitFlags(l, x, y).ToString("X");
                    }
                }
                return "(遍历 " + n + " 项都没找到压在图标上的点)";
            } finally { VirtualFreeEx(proc, mem, UIntPtr.Zero, 0x8000); }
        } finally { CloseHandle(proc); }
    }

    public static string BlankPoint(out int ox, out int oy) {
        ox = 0; oy = 0;
        IntPtr l = IconList();
        if (l == IntPtr.Zero) return "(图标层不在)";
        int right = GetSystemMetrics(0), bottom = GetSystemMetrics(1);
        for (int y = 60; y < bottom - 60; y += 120) {
            for (int x = 60; x < right - 60; x += 160) {
                if (!OnDesktop(x, y)) continue;
                bool busy = false;
                int[] off = new int[] { 0, 24, -24 };
                foreach (int dx in off) {
                    foreach (int dy in off) {
                        if (OnIcon(l, x + dx, y + dy)) { busy = true; break; }
                    }
                    if (busy) break;
                }
                if (busy) continue;
                ox = x; oy = y;
                return "(" + x + "," + y + ") flags=0x" + HitFlags(l, x, y).ToString("X");
            }
        }
        return "(找不到既在桌面上又不压图标的点)";
    }

    public static bool PostGesture(IntPtr hwnd, int x, int y) {
        long packed = ((long)x & 0xFFFFL) | (((long)y & 0xFFFFL) << 16);
        return PostMessageW(hwnd, 0x8004, new IntPtr(packed), new IntPtr(1));   // lParam=1：按真实鼠标处理，绕开注入开关
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
# 出错也要还原，但绝不"继续跑"：曾因此把 C# 侧抛的编译/运行异常咽成一个空消息、伪装成 SKIP 结论。
# 夹具必须响亮地失败（exit 1），不能把异常留在流程里。
trap {
    Write-Host ("   捕获异常：" + $_.Exception.Message) -ForegroundColor Red
    if (Test-Path Function:\Restore-Covering) { Restore-Covering }
    # 异常路径也不许把桌面留在 hidden：用户下次看桌面才发现图标没了，那是测试造的债。
    try { Start-Process $exe -ArgumentList '--show' -NoNewWindow -Wait } catch { }
    exit 1
}

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
    public static void RestoreAll(IntPtr[] hs) { if (hs == null) return; foreach (IntPtr h in hs) { ShowWindow(h, 9); if (_zoomed.Contains(h)) ShowWindow(h, 3); } }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Get-StatusText {
    $o = Join-Path $env:TEMP ("ig-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $exe -ArgumentList "--status" -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o); Remove-Item $o, "$o.err" -ErrorAction SilentlyContinue
    return $t
}
function Read-Counters {
    $t = Get-StatusText
    $d = [regex]::Match($t, 'diag\s+= ups=(\d+) pairs=(\d+) showwindow=(\d+) dropped=(\d+) toggle_failed=(\d+)')
    $g = [regex]::Match($t, 'gesture\s+= on_icon=(\d+) not_desktop=(\d+)(?: throttled=(\d+))? last=(\S+)')
    $r = [regex]::Match($t, 'instance\s+= 运行中 pid=(\d+)')
    if (-not $d.Success -or -not $g.Success) { throw "--status 里没解析到 diag/gesture 行：$t" }
    return @{
        shown   = [int]$d.Groups[3].Value
        onIcon  = [int]$g.Groups[1].Value
        notDesk = [int]$g.Groups[2].Value
        last    = $g.Groups[4].Value
        pid     = [int]$r.Groups[1].Value
        raw     = $t
    }
}

Write-Host "== 0. 前置 =="
# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是活动照样发生在那一份身上，
# 后面每一次 --status 都读不到 diag/gesture 行，Read-Counters 只会报"没解析到"。先按进程 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $eo = Join-Path $env:TEMP ("ig-exit-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $livePath -ArgumentList '--exit' -NoNewWindow -Wait -RedirectStandardOutput $eo -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $eo, "$eo.err" -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 800
if ((@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count) -eq 0) { Start-Process $exe; Start-Sleep 2 }
$coveredWin = [COV]::MinimizeCovering()
if ($coveredWin.Length -gt 0) { Start-Sleep -Milliseconds 1500; Write-Host ("   已临时最小化 {0} 个遮挡窗口（测完自动还原）" -f $coveredWin.Length) }

$ipc = [IG]::Ipc()
if ($ipc -eq [IntPtr]::Zero) { Restore-Covering; Write-Host "VERDICT: FAIL - 找不到实例的消息窗口（类名+标题都没配上）" -ForegroundColor Red; exit 1 }
$list = [IG]::IconList()
if ($list -eq [IntPtr]::Zero) { Restore-Covering; Write-Host "VERDICT: FAIL - 图标层不在，测不了" -ForegroundColor Red; exit 1 }
Start-Process $exe -ArgumentList "--show" -NoNewWindow -Wait | Out-Null
Start-Sleep -Milliseconds 700
Write-Host ("   实例 IPC 窗口 = {0}   SysListView32 = {1}   桌面图标项数 = {2}" -f $ipc, $list, [IG]::Items($list))

[int]$ix = 0; [int]$iy = 0
$iconDesc = [IG]::IconPoint([ref]$ix, [ref]$iy)
if ($ix -eq 0 -and $iy -eq 0) {
    Restore-Covering
    Write-Host "VERDICT: SKIP - 没造出「压在图标上」的落点：$iconDesc" -ForegroundColor Yellow
    Write-Host "   （不降级、不猜：找不到图标就不做这条断言。桌面被覆盖/图标为空都会走到这里）"
    exit 4
}
[int]$bx = 0; [int]$by = 0
$blankDesc = [IG]::BlankPoint([ref]$bx, [ref]$by)
if ($bx -eq 0 -and $by -eq 0) { Restore-Covering; Write-Host "VERDICT: SKIP - 找不到桌面空白落点：$blankDesc" -ForegroundColor Yellow; exit 4 }
Write-Host ("   压在图标上的落点   ：$iconDesc")
Write-Host ("   不压图标的桌面落点 ：$blankDesc")

$fails = @()

Write-Host "`n== A. 同一个输入通道，落点压在图标上 => 必须停手 =="
$a0 = Read-Counters
$shownStart = [IG]::IconsShown($list)
Write-Host ("   投之前：showwindow={0} on_icon={1} last={2} 独立探针={3}" -f $a0.shown, $a0.onIcon, $a0.last, $(if ($shownStart) { 'visible' } else { 'hidden' }))
[void][IG]::PostGesture($ipc, $ix, $iy)
Start-Sleep -Milliseconds 900
$a1 = Read-Counters
$shownAfter = [IG]::IconsShown($list)
Write-Host ("   投之后：showwindow={0} on_icon={1} last={2} 独立探针={3}" -f $a1.shown, $a1.onIcon, $a1.last, $(if ($shownAfter) { 'visible' } else { 'hidden' }))
if ($a1.onIcon -le $a0.onIcon) { $fails += "on_icon 没涨：命中测试这条分支根本没跑到（last=$($a1.last)）" }
if ($a1.shown -ne $a0.shown) { $fails += "压在图标上的双击仍然执行了 ShowWindow（$($a0.shown) -> $($a1.shown)）——会抢走用户启动程序的点击" }
if ($shownAfter -ne $shownStart) { $fails += "独立探针看到图标可见性被改了，但 showwindow 计数没动，前后不自洽" }
if ($a1.last -ne 'on_icon') { $fails += "last 不是 on_icon（实为 $($a1.last)）：拦下它的不是图标保护，而是别的分支，这条断言不算数" }

Write-Host "`n== B. 对照组：落点不压图标 => 同一个通道必须切换 =="
Start-Sleep -Milliseconds 400
$b1 = Read-Counters
Write-Host ("   投之前：showwindow={0} last={1} 独立探针={2}" -f $b1.shown, $b1.last, $(if ([IG]::IconsShown($list)) { 'visible' } else { 'hidden' }))
[void][IG]::PostGesture($ipc, $bx, $by)
Start-Sleep -Milliseconds 900
$b2 = Read-Counters
Write-Host ("   投之后：showwindow={0} last={1} 独立探针={2}" -f $b2.shown, $b2.last, $(if ([IG]::IconsShown($list)) { 'visible' } else { 'hidden' }))
if ($b2.shown -le $b1.shown) { $fails += "对照组也没切换（showwindow $($b1.shown) -> $($b2.shown)）：说明 A 的「没动」是整条链不通，不是保护生效" }
if ($b2.last -ne 'toggled') { $fails += "对照组 last 不是 toggled（实为 $($b2.last)）" }
if (([IG]::IconsShown($list)) -eq $shownStart) { $fails += "对照组的可见性没被独立探针看到变化：可能只是巧合回到原值，断言作废" }

Write-Host "`n== C. 收尾：把桌面还给用户 =="
Start-Process $exe -ArgumentList "--show" -NoNewWindow -Wait | Out-Null
Start-Sleep -Milliseconds 700
Write-Host ("   独立探针最终看到图标 = {0}   实例 pid = {1}" -f $(if ([IG]::IconsShown($list)) { 'visible' } else { 'hidden' }), $b2.pid)
Restore-Covering

Write-Host "`n== 结论 =="
if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 压在图标上的双击被命中测试挡下（不切换、可见性不动），同一通道落在空白处则切换" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
