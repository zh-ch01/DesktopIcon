# 诊断（不作验收判据）：explorer 反复重启时，托盘图标到底是"没注册上"还是"注册上了但被收进溢出区"。
# UIA 只数屏幕底部那一条会带来一类假 FAIL：Win11 会把新注册/很久没动的图标收进溢出角落，那时按钮不在
# 任务栏带上，UIA 数到 0，可程序侧的注册其实是好的。这里把**整棵树**里叫这个名字的元素全列出来，
# 连类名链和矩形一起打，用"存在但位置不对"和"根本不存在"区分开。
param([int]$Rounds = 2)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = Join-Path (Get-Location) 'dist\DesktopIconToggle.exe'
$errLog = Join-Path (Get-Location) 'run-tray-probe.err'

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class TP {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);

    public static int LayerCount() {
        int n = 0;
        IntPtr p = FindWindowW("Progman", null);
        if (p != IntPtr.Zero && FindWindowExW(p, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero) n++;
        IntPtr w = IntPtr.Zero;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) break;
            if (FindWindowExW(w, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero) n++;
        }
        return n;
    }
    public static string ClassName(IntPtr h) {
        StringBuilder sb = new StringBuilder(128);
        int n = GetClassNameW(h, sb, sb.Capacity);
        return n <= 0 ? "?" : sb.ToString(0, Math.Min(n, sb.Length));
    }
    public static string Rect(IntPtr h) {
        RECT r; if (!GetWindowRect(h, out r)) return "(取不到)";
        return "(" + r.l + "," + r.t + ")-(" + r.r + "," + r.b + ")";
    }
    public static string Chain(IntPtr h) {
        StringBuilder s = new StringBuilder();
        IntPtr cur = h;
        for (int i = 0; i < 6 && cur != IntPtr.Zero; i++) {
            if (i > 0) s.Append(" < ");
            s.Append(ClassName(cur));
            cur = GetParent(cur);
        }
        return s.ToString();
    }
    public static int ShellPid() {
        IntPtr p = FindWindowW("Shell_TrayWnd", null);
        if (p == IntPtr.Zero) return 0;
        uint pid; GetWindowThreadProcessId(p, out pid);
        return (int)pid;
    }
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
    public static int UserObjects(IntPtr h) { return (int)GetGuiResources(h, 0); }
    public static int GdiObjects(IntPtr h) { return (int)GetGuiResources(h, 1); }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase

# 托盘按钮在不在？三种答案，别只数任务栏那一条带：
#   bar      —— 按钮就在任务栏带上（Y>=1130）
#   overflow —— 任务栏带上没有，但用 UIA Invoke 展开「显示隐藏的图标」之后出现了 —— 注册是好的，Win11 只是把它收进溢出区
#   absent   —— 展开溢出区之后仍然没有 —— 这才是"这份 shell 里真的没有我们的注册"
# 为什么必须展开：溢出区收起时它的子元素根本不在 UIA 树里。我一开始拿"整棵树扫不到"当"没注册"的证据，
# 于是把一次摆放变化读成了一次注册丢失（B15 的误判），实测展开后按钮就在 (1610,1081)。
# 副作用：会真的把溢出区展开一次再收回去（只在任务栏带上数不到时才做）。
function Find-OurTrayButtons {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $out = @()
    foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        if ($e.Current.Name -like '桌面图标开关｜*') { $out += $e }
    }
    return ,$out
}
function Show-TrayRow($e) {
    $r = $e.Current.BoundingRectangle
    Write-Host ("      存在：矩形=[{0},{1} {2}x{3}]  离屏={4}  类={5}" -f `
        [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height, $e.Current.IsOffscreen, $e.Current.ClassName)
}
function Get-TrayState([string]$label) {
    $onBar = @(Find-OurTrayButtons | Where-Object { $_.Current.BoundingRectangle.Y -ge 1130 })
    foreach ($e in $onBar) { Show-TrayRow $e }
    if ($onBar.Count -gt 0) { Write-Host ("   [{0}] 判定 = bar（任务栏带上 {1} 个）" -f $label, $onBar.Count); return 'bar' }
    $all = @(Find-OurTrayButtons)
    if ($all.Count -gt 0) { foreach ($e in $all) { Show-TrayRow $e }; Write-Host ("   [{0}] 判定 = overflow（未展开就可见，更好）" -f $label); return 'overflow' }
    # 展开溢出区再数一次
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $chev = $null
    foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        if ($e.Current.Name -like '显示隐藏的图标*') { $chev = $e; break }
    }
    if ($null -eq $chev) { Write-Host ("   [{0}] 判定 = unknown（找不到「显示隐藏的图标」按钮，无法排除溢出区）" -f $label); return 'unknown' }
    try {
        $inv = $chev.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $inv.Invoke()
    } catch { Write-Host ("   [{0}] 判定 = unknown（展开溢出区失败：{1}）" -f $label, $_.Exception.Message); return 'unknown' }
    Start-Sleep -Milliseconds 1500
    $found = @(Find-OurTrayButtons)
    foreach ($e in $found) { Show-TrayRow $e }
    try { $inv.Invoke() } catch { }          # 收回去，别把用户的溢出区留在展开状态
    Start-Sleep -Milliseconds 300
    if ($found.Count -gt 0) { Write-Host ("   [{0}] 判定 = overflow（注册在，被 Win11 收进溢出区）" -f $label); return 'overflow' }
    Write-Host ("   [{0}] 判定 = absent（展开溢出区之后仍然没有 => 这份 shell 里真的没有我们的注册）" -f $label)
    return 'absent'
}

function Snap-Counters([int]$pid_, [string]$label) {
    $pr = Get-Process -Id $pid_
    $pr.Refresh()
    $u = [TP]::UserObjects($pr.Handle)
    $g = [TP]::GdiObjects($pr.Handle)
    $v = @{ user = $u; gdi = $g; handles = $pr.HandleCount; threads = $pr.Threads.Count
            priv = $pr.PrivateMemorySize64; ws = $pr.WorkingSet64 }
    Write-Host ("   [{0}] USER={1} GDI={2} 句柄={3} 线程={4} 私有={5:N2} MB 工作集={6:N1} MB" -f `
        $label, $u, $g, $v.handles, $v.threads, ($v.priv / 1MB), ($v.ws / 1MB))
    return $v
}


Write-Host "== 0. 用可捕获 stderr 的方式起一份实例 =="
# 先决定"测哪一份"：如果已经有实例在跑（可能是另一个路径的那一份，比如 %LOCALAPPDATA% 下的日常副本），
# 从 dist 路径发 --exit 是不会认它的（F28 的属主校验），此时再 Start-Process 只会让第二个实例自己退出，
# 然后我们拿着一个已经死掉的 pid 去采样。所以：按进程的 Path 找到在场那一份，用它自己的路径去退、再用它起。
$live = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
$target = if ($live.Count -gt 0) { ($live[0].Path) } else { $exe }
Write-Host ("   测的是这一份：{0}" -f $target)
if ($live.Count -gt 0) {
    $null = Start-Process $target -ArgumentList '--exit' -NoNewWindow -Wait
    Start-Sleep -Milliseconds 1200
}
if (Test-Path $errLog) { Remove-Item $errLog }
$p = Start-Process $target -PassThru -RedirectStandardError $errLog
Start-Sleep -Seconds 3
Write-Host ("   实例 pid = {0}   shell pid = {1}" -f $p.Id, [TP]::ShellPid())
$base = Get-TrayState '起点'
$u0 = Snap-Counters $p.Id '起点'



for ($i = 1; $i -le $Rounds; $i++) {
    Write-Host ("`n== 第 {0} 轮：停 explorer 再起回来 ==" -f $i)
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and [TP]::LayerCount() -gt 0) { Start-Sleep -Milliseconds 200 }
    Write-Host ("   停了：图标层={0} shell pid={1}" -f [TP]::LayerCount(), [TP]::ShellPid())
    Start-Process explorer.exe -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and [TP]::LayerCount() -eq 0) { Start-Sleep -Milliseconds 200 }
    Write-Host ("   起来了：图标层={0} shell pid={1}" -f [TP]::LayerCount(), [TP]::ShellPid())
    Start-Sleep -Seconds 6
    $n = Get-TrayState ("第 $i 轮起来后")
    if ($n -eq 'absent') { $absentRounds += $i }
    if ($n -eq 'unknown') { $unknownRounds += $i }
    Write-Host ("   实例还活着 = {0}" -f (-not $p.HasExited))
    $null = Snap-Counters $p.Id "第 $i 轮之后"
}

$uEnd = Snap-Counters $p.Id '收尾'
Write-Host ("   增量（{0} 次 shell 重启之后）：USER {1}  GDI {2}  句柄 {3}  线程 {4}  私有内存 {5:N2} MB  工作集 {6:N1} MB" -f `
    $Rounds, ($uEnd.user - $u0.user), ($uEnd.gdi - $u0.gdi), ($uEnd.handles - $u0.handles), ($uEnd.threads - $u0.threads), `
    (($uEnd.priv - $u0.priv) / 1MB), (($uEnd.ws - $u0.ws) / 1MB))

Write-Host "`n== 实例自己怎么说（stderr 全文）=="
if (Test-Path $errLog) { Get-Content $errLog | ForEach-Object { Write-Host "   $_" } } else { Write-Host "   （没有 stderr 文件）" }
Write-Host ("   起点判定 = {0}" -f $base)
Write-Host ("   判 absent 的轮次 = {0}   判 unknown 的轮次 = {1}" -f (@($absentRounds) -join ','), (@($unknownRounds) -join ','))
