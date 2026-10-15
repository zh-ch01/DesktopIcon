# 确认那个"可见的 0×0 顶层窗口"不会出现在任务栏 / Alt+Tab / 任何用户可见的地方
function Stop-Instance {
    # 用 --exit 正常退出：Stop-Process 强杀会让 explorer 留下幽灵托盘图标（点不到的空位），
    # 而且会污染后续所有基于托盘的测试。强杀只作为兜底。
    $o = Join-Path $env:TEMP ("x-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--exit" -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue
    Remove-Item $o -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline -and @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Start-Sleep -Milliseconds 150 }
    if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { Get-Process DesktopIconToggle -EA SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
}

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class H {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint g);
    [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; }
    public static string Describe() {
        IntPtr w = FindWindowExW(IntPtr.Zero, IntPtr.Zero, null, "DesktopIconToggle.Ipc.v1");
        if (w == IntPtr.Zero) { return "(找不到窗口)"; }
        RC r; GetWindowRect(w, out r);
        IntPtr root = GetAncestor(w, 0);   // GA_ROOT
        return "句柄=" + w + " 可见=" + IsWindowVisible(w) + " 矩形=(" + r.l + "," + r.t + ")-(" + r.r + "," + r.b + ") 尺寸=" + (r.r - r.l) + "x" + (r.b - r.t) + " 根=" + root;
    }
}
'@
[H]::Describe()
# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是上面量到的是"那一份"的窗口，
# 结尾 Stop-Instance 也收不掉它，后台就多留一个实例。先按进程的 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $eo = Join-Path $env:TEMP ("hy-exit-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $livePath -ArgumentList '--exit' -NoNewWindow -Wait -RedirectStandardOutput $eo -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $eo, "$eo.err" -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 800
if ((@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count) -eq 0) { Start-Process "dist\DesktopIconToggle.exe"; Start-Sleep 2 }
[H]::Describe()
# 任务栏上有没有多出我们的按钮
$root = [System.Windows.Automation.AutomationElement]::RootElement
$c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$taskbar = 0; $tray = 0
foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c)) {
    if ($b.Current.Name -like '桌面图标开关｜*') {
        $r = $b.Current.BoundingRectangle
        if ($r.Y -lt 1140) { $taskbar++; "  任务栏按钮: [$($b.Current.Name)] $($r.X),$($r.Y)" } else { $tray++ }
    }
}
"任务栏上的按钮数=$taskbar（应为 0）  托盘区按钮数=$tray（应为 1）"
$fails = @()
$skips = @()
if ($taskbar -gt 0) { $fails += "任务栏上出现了 $taskbar 个我们的按钮（应为 0）—— 那个可见的 0x0 顶层窗口漏进了用户看得见的地方" }
# 托盘数到 0 不给 FAIL：这里只数任务栏那一条带（Y>=1140），Win11 把图标收进「显示隐藏的图标」溢出区时
# 这一格本来就是 0 —— 分不清"没注册"还是"被收起"（B18），只能记 SKIP，不拿它当 PASS 也不当 FAIL。
if ($tray -lt 1) { $skips += "托盘区按钮数 = $tray：只数任务栏带，分不清是没注册还是被收进溢出区" }
Stop-Instance   # 本脚本为了测量会自己起一份实例，量完必须收掉，不能把后台实例留给用户

# 打印过 FAIL 就必须给非零退出码，否则自动化把整轮当成功（原先结尾没有 exit）。
if ($fails.Count -gt 0) {
    foreach ($f in $fails) { "   FAIL: $f" }
    "VERDICT: FAIL"
    exit 1
}
if ($skips.Count -gt 0) {
    foreach ($m in $skips) { "   SKIP: $m" }
    "VERDICT: SKIP - 任务栏干净这条过了，但托盘那一格判不了"
    exit 4
}
"VERDICT: PASS - 任务栏 0 个按钮、托盘 1 个"
exit 0
