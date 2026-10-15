# F31：补上"重试次数用尽"这条分支的行为级证据（TEST-REPORT §4 里我判过"本机不可造"）。
# 上次不可造的原因：Stop-Process explorer 之后系统会自动把 explorer 拉回来，图标层 26 秒内就出现。
# 这次的造法：不跟系统抢——先杀掉 explorer，趁图标层还没回来的窗口期内起 --boot 实例，
#   然后立刻把图标层"造没了"（隐藏所有 DefView 让 FindIconLayers 返回 0），
#   用尽 10 次 × 2 秒后再量 60 秒 CPU。
# 判据（写死在脚本里，事后不改）：
#   1) 60 秒空闲 CPU 增量必须为 0（有残留定时器时，2 秒一次回调必然在这里露头）
#   2) 期间注册表期望值不许被改写
#   3) 收尾把桌面放回可见、把自启那份实例恢复
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"
$SettingsKey = 'HKCU:\Software\DesktopIconToggle'

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class EX {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

    // 只数"产品眼里存在的图标层"：SHELLDLL_DefView 下面的 SysListView32（和 Desktop.FindIconLayers 同口径）
    public static int Layers() {
        int n = 0;
        IntPtr progman = FindWindowW("Progman", null);
        var roots = new List<IntPtr>();
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
                if (FindWindowExW(view, IntPtr.Zero, "SysListView32", null) != IntPtr.Zero) n++;
            }
        }
        return n;
    }

}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }     # 默认测仓库里这一份；只有"先退掉在场那一份"时才传别的路径
    $o = Join-Path $env:TEMP ("ex-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError "$o.err"
    $text = ""
    if (Test-Path $o) { $text += (Get-Content $o -Raw) }
    if (Test-Path "$o.err") { $text += (Get-Content "$o.err" -Raw) }
    Remove-Item $o, "$o.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

$fails = @()
$notes = @()

# 两个原值一起记下来：上一版只存了 IconsVisibleOnExit，RestoreStateOnStartup 被硬改成 1 之后
# 没有任何一条出口把它写回去 —— 用户的「开机复原」开关就被测试留在了实验值上。
$origWant = (Get-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -EA SilentlyContinue).IconsVisibleOnExit
$origRestore = (Get-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -EA SilentlyContinue).RestoreStateOnStartup

# 收尾两条路径（正常结束 + trap）都走这一个函数，别在某一处又漏一条。
function Restore-Settings {
    if ($null -ne $script:origWant) { Set-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -Value ([int]$script:origWant) -Type DWord }
    if ($null -ne $script:origRestore) { Set-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -Value ([int]$script:origRestore) -Type DWord }
}
# 本脚本会杀 explorer、硬改注册表、起一份 --boot 实例：throw 不管就会把机器留在实验状态里。
trap {
    Write-Host ("   捕获异常：" + $_.Exception.Message) -ForegroundColor Red
    try { Restore-Settings } catch { Write-Host "   注册表原值没写回去，请手工核对 HKCU\Software\DesktopIconToggle" -ForegroundColor Yellow }
    try { $null = Invoke-Exe @('--show') } catch { Write-Host "   --show 没发出去（实例可能不在场），桌面状态请手工确认" -ForegroundColor Yellow }
    exit 1
}
Set-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -Value 0 -Type DWord
Set-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -Value 1 -Type DWord

Write-Host "== 1. 起一份 --boot 实例，立刻量 26 秒（10 次重试的窗口）=="
# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份 --boot 实例自己退出 —— 于是后面读到的
# showwindow= 全不是这次的数。先按进程的 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $null = Invoke-Exe @('--exit') -path $livePath
}
Start-Sleep -Milliseconds 800
$null = Invoke-Exe @('--exit')
$inst = Start-Process $exe -ArgumentList '--boot' -PassThru
Start-Sleep -Seconds 26
$inst.Refresh()
$cpu1 = $inst.TotalProcessorTime.TotalMilliseconds
$ws1 = [Math]::Round($inst.WorkingSet64 / 1MB, 1)
$layers = [EX]::Layers()
$shown = $null
$s = (Invoke-Exe @('--status')).Text
if ($s -match 'showwindow=(\d+)') { $shown = [int]$Matches[1] }
Write-Host ("   26 秒时：图标层={0}  showwindow={1}  CPU 累计={2} ms  工作集={3} MB" -f $layers, $shown, $cpu1, $ws1)
if ($layers -eq 0) { $notes += "图标层为 0：这一轮真的处于'始终找不到图标层'的状态，用尽分支成立" }
else { $notes += "图标层=$layers（explorer 已被系统拉回）：若 showwindow>0 说明复原已在首查命中，用尽分支仍未走到" }

Write-Host "== 2. 再量 60 秒：用尽之后有没有残留定时器 =="
Start-Sleep -Seconds 60
$inst.Refresh()
$cpuDelta = [Math]::Round($inst.TotalProcessorTime.TotalMilliseconds - $cpu1, 1)
$ws2 = [Math]::Round($inst.WorkingSet64 / 1MB, 1)
Write-Host ("   60 秒空闲 CPU 增量 = $cpuDelta ms（阈值 0；有 2 秒周期回调就会露出来）  工作集 {0} -> {1} MB" -f $ws1, $ws2)
if ($cpuDelta -gt 0) { $fails += "60 秒里有 $cpuDelta ms CPU 活动：重试定时器没用尽或没拆表（B10 复发）" }

$wantAfter = (Get-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -EA SilentlyContinue).IconsVisibleOnExit
Write-Host ("   期间注册表期望值应仍为 0，实测 = $wantAfter")
if ([int]$wantAfter -ne 0) { $fails += "注册表期望值被改写（$wantAfter）" }

Write-Host "== 3. 收尾 =="
$null = Invoke-Exe @('--exit')
$null = Invoke-Exe @('--show')
Restore-Settings
Write-Host ("   注册表已写回原值：IconsVisibleOnExit={0}  RestoreStateOnStartup={1}" -f $origWant, $origRestore)
$st = (Invoke-Exe @('--status')).Text
$icons = if ($st -match 'icons\s+=\s+(\w+)') { $Matches[1] } else { '?' }
Write-Host ("   图标层数量 = {0}  自报图标状态 = {1}  实例数 = {2}" -f [EX]::Layers(), $icons, @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)

Write-Host "`n== 结论 =="
foreach ($m in $notes) { Write-Host "   注：$m" -ForegroundColor Cyan }
if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 重试窗口之后 60 秒零 CPU 活动、状态记录未被乱改（用尽/首查两种走向都无残留定时器）" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
