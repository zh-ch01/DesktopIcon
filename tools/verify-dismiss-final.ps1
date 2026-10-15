# 精确确认：点外部那一刻，TrackPopupMenu 才返回。
# 读两次 menu 统计：一次在菜单开着的时候，一次在点外部之后。期望 tracks +1 且 last_ms 约等于中间等待的时间。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class C4 {
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public uint pad; public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte s, uint f, IntPtr e);
    static INPUT Mk(uint f) { INPUT i = new INPUT(); i.type = 0; i.dwFlags = f; return i; }
    public static IntPtr Ipc() { return FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1"); }
    /// 真右键：让 explorer 走完整链路转发通知（直接 PostMessage 会绕过 explorer，
    /// 拿不到它授予的"可以置前"权限，菜单就永远不随点击外部关闭 —— 那是假故障）。
    public static void OpenMenu(int x, int y) {
        SetCursorPos(x, y); Thread.Sleep(250);
        INPUT[] a = new INPUT[] { Mk(0x0008), Mk(0x0010) };
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Click(int x, int y) { SetCursorPos(x, y); Thread.Sleep(250);
        INPUT[] a = new INPUT[] { Mk(0x0002), Mk(0x0004) }; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
    public static void Esc() { keybd_event(0x1B,0,0,IntPtr.Zero); keybd_event(0x1B,0,2,IntPtr.Zero); }
}
'@
function Stat {
    $o = Join-Path $env:TEMP ("s-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--status" -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o); Remove-Item $o -ErrorAction SilentlyContinue
    $m = [regex]::Match($t, 'menu\s+= tracks=(\d+) last_track_ms=(\d+)')
    return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
}
# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是菜单跟踪发生在那一份身上，
# 这里 --status 读回来的 menu/diag 行却是空的（字段"凭空没了"）。先按进程的 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $eo = Join-Path $env:TEMP ("df-exit-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $livePath -ArgumentList '--exit' -NoNewWindow -Wait -RedirectStandardOutput $eo -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $eo, "$eo.err" -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 800
if ((@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count) -eq 0) { Start-Process "dist\DesktopIconToggle.exe"; Start-Sleep 2 }
$t0 = Stat
"C0 base            tracks=$($t0[0]) last_ms=$($t0[1])"

# 右键落点必须现取：托盘按钮的 x 会随旁边图标增减而移动。写死 (1642,1173) 在一次 explorer 重启之后就偏出
# 37px —— 右键落到别人身上，菜单根本没弹，tracks 与 last_ms 全是 0，于是报一条假 FAIL。
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
$uiRoot = [System.Windows.Automation.AutomationElement]::RootElement
$uiCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
$btn = $null
foreach ($e in $uiRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants, $uiCond)) {
    if ($e.Current.Name -notlike '桌面图标开关｜*') { continue }
    $rr = $e.Current.BoundingRectangle
    if ($rr.Y -le 1130) { continue }          # 只认任务栏带上那一条，溢出区里的坐标不能点
    $btn = $e; break
}
if ($null -eq $btn) {
    "VERDICT: SKIP - 任务栏带上找不到我们的托盘按钮（可能被 Win11 收进溢出区），不拿「右键落在别人身上」的结果当判据"
    exit 4
}
$rc = $btn.Current.BoundingRectangle
$tx = [int]($rc.X + $rc.Width / 2)
$ty = [int]($rc.Y + $rc.Height / 2)
Write-Host ("   托盘按钮现取于 ({0},{1})  矩形=[{2},{3} {4}x{5}]" -f $tx, $ty, [int]$rc.X, [int]$rc.Y, [int]$rc.Width, [int]$rc.Height)
[C4]::OpenMenu($tx, $ty)
Start-Sleep -Milliseconds 500
$t1 = Stat
"C1 menu is open    tracks=$($t1[0]) last_ms=$($t1[1])   (tracks 未增加 = 仍卡在模态循环里)"
$waitStart = Get-Date
[C4]::Click(700, 500)
Start-Sleep -Milliseconds 1000
$t2 = Stat
$elapsed = [int]((Get-Date) - $waitStart).TotalMilliseconds
"C2 after outside   tracks=$($t2[0]) last_ms=$($t2[1])   (等待约 $elapsed ms)"
# 主判据用"最后一次跟踪时长"：幽灵图标会让 tracks 计数虚增（每个空注册都会瞬时返回一次），
# 但 last_ms 只能来自一次真实的模态跟踪，且它应当约等于"弹出到点外部"的等待时间。
$ms = $t2[1]
$code = 0
$verdict = ""
if ($ms -ge 300 -and $ms -le ($elapsed + 1500)) {
    $verdict = "VERDICT: PASS - 菜单一直开着，直到点击外部才返回（跟踪 $ms ms ~ 等待 $elapsed ms）"
} elseif ($ms -lt 300) {
    $verdict = "VERDICT: FAIL - 跟踪时长 $ms ms 太短，菜单没真正停留（可能被立刻取消，或右键根本没落在我们图标上）"
    $code = 1
} else {
    $verdict = "VERDICT: FAIL - 跟踪时长 $ms ms 远大于等待 $elapsed ms，说明点外部并没有让它返回"
    $code = 1
}
[C4]::Esc()
Write-Host $verdict
exit $code
