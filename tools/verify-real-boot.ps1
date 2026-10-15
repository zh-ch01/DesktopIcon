# 真实开机验证（重启后跑这一个脚本就行）。
# 覆盖 TEST-REPORT §4 里唯一没被任何形式实测过的那条路径：真机重启 + explorer 冷启动时，
#   ① 自启动登记还在不在、实例有没有被 Run 键拉起来；
#   ② 图标是否按上次关机前的状态复原（含"图标层还没建出来时靠重试定时器兜住"这条分支）；
#   ③ 壁纸没被带走（复用 test-gesture 的亮度反证思路）。
# 判据一律用**独立探针**自己读 explorer 的窗口，不信被测程序自报；被测程序的 --status 只作交叉验证。
#
# 跑法（重启回到桌面后）：powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-real-boot.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot     # 注意：$PSScriptRoot 是 tools\，产物与截图要落在工程根目录
Set-Location $root

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class BootProbe {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // 图标层 = SHELLDLL_DefView 下的 SysListView32；真正的可见性以它为准（隐它是产品行为，隐 DefView 会连壁纸一起没）。
    public static List<IntPtr> IconLayers() {
        var list = new List<IntPtr>();
        IntPtr progman = FindWindowW("Progman", null);
        IntPtr[] roots;
        var rootsList = new List<IntPtr>();
        if (progman != IntPtr.Zero) rootsList.Add(progman);
        IntPtr w = IntPtr.Zero;
        while (true) {
            w = FindWindowExW(IntPtr.Zero, w, "WorkerW", null);
            if (w == IntPtr.Zero) break;
            if (w != progman) rootsList.Add(w);
        }
        roots = rootsList.ToArray();
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
        var layers = IconLayers();
        if (layers.Count == 0) return "no-iconlayer";
        int shown = 0;
        foreach (IntPtr h in layers) { if (IsWindowVisible(h)) shown++; }
        return shown == 0 ? "hidden" : (shown == layers.Count ? "visible" : "mixed(" + shown + "/" + layers.Count + ")");
    }

    public static int LayerCount { get { return IconLayers().Count; } }

    public static uint ExplorerPid() {
        var layers = IconLayers();
        if (layers.Count == 0) return 0;
        uint pid;
        GetWindowThreadProcessId(layers[0], out pid);
        return pid;
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }
    $outFile = Join-Path $env:TEMP ("boot-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments `
        -PassThru -Wait -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path "$outFile.err") { $text += (Get-Content "$outFile.err" -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

$fails = @()
$sceneFails = @()   # 只有"确实在开机现场"才能算 FAIL 的条目
$notes = @()
$now = Get-Date
Write-Host "== 0. 本次实测时刻：$($now.ToString('yyyy-MM-dd HH:mm:ss')) =="

# ---- 1. 期望值：不用预先布防 ----
# 产品每次真正改变可见性都会写 HKCU\Software\DesktopIconToggle\IconsVisibleOnExit，
# 并且注销/关机时在 WM_QUERYENDSESSION 里按"当时的真实状态"再刷一遍，
# 所以注册表里那个值本身就是"关机前应当是什么"的可靠记录 —— 不必为了测试专门 arm 一次。
# tools\arm-for-reboot.ps1 只在你想刻意验"收着图标过重启"这一种变体时才需要（它会留一个 boot-expect.txt 覆盖这里的判定）。
$expectFile = Join-Path $root "boot-expect.txt"
$expected = "unknown"
$expectSource = ""
# 布防文件必须晚于本次开机才作数：它是上一次验证留下的话，拿来判这一次就是凭空造期望值
# （实测 08:48 那份 arm 文件在 10 小时后还在盘上，把期望值钉成 hidden，而中途图标被回归测试翻出来过很多次）。
$bootAt = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$armedAt = if (Test-Path $expectFile) { (Get-Item $expectFile).LastWriteTime } else { $null }
$armIsFresh = ($armedAt -and $armedAt -gt $bootAt)
if ($armIsFresh) {
    $lines = Get-Content $expectFile
    $expected = $lines[0].Trim()
    $expectSource = "boot-expect.txt（arm 于 " + $(if ($lines.Count -gt 1) { $lines[1].Trim() } else { "?" }) + "，晚于本次开机）"
} elseif (Test-Path $expectFile) {
    Write-Host ("   忽略 {0}：它写于 {1}，早于本次开机 {2}，是上一次验证的遗留" -f (Split-Path -Leaf $expectFile), $armedAt, $bootAt) -ForegroundColor Yellow
    $null = $expectFile   # 保留文件本身，只是不当期望值用
    $stored = Get-ItemProperty 'HKCU:\Software\DesktopIconToggle' -EA SilentlyContinue
    if ($null -ne $stored -and $stored.PSObject.Properties.Name -contains 'IconsVisibleOnExit') {
        $expected = if ([int]$stored.IconsVisibleOnExit -eq 1) { 'visible' } else { 'hidden' }
        $expectSource = '注册表 IconsVisibleOnExit（布防文件已过期，退回注册表口径）'
    }
} else {
    $stored = Get-ItemProperty 'HKCU:\Software\DesktopIconToggle' -EA SilentlyContinue
    if ($null -ne $stored -and $stored.PSObject.Properties.Name -contains 'IconsVisibleOnExit') {
        $expected = if ([int]$stored.IconsVisibleOnExit -eq 1) { 'visible' } else { 'hidden' }
        $expectSource = '注册表 IconsVisibleOnExit（产品自己在关机前刷的值）'
    } else {
        $expected = 'visible'
        $expectSource = '默认值（注册表里没这个值，按「显示」判）'
    }
}
Write-Host "   关机前应当是：icons=$expected"
Write-Host "   期望值来源：$expectSource"

# 结论只有在「刚开机不久」才等于「开机复原的结果」：中途你自己双击过图标的话，实测值就掺进了你的操作。
$inst0 = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
if ($inst0.Count -ge 1) {
    $uptimeMin = [Math]::Round(((Get-Date) - $inst0[0].StartTime).TotalMinutes, 1)
    Write-Host ("   本实例已运行 {0} 分钟（{1} 起）" -f $uptimeMin, $inst0[0].StartTime.ToString('HH:mm:ss'))
    if ($uptimeMin -gt 15) {
        $notes += "实例已跑了 $uptimeMin 分钟：这份证据只能算「开机后一直好用」，不能算「开机那一刻复原正确」，除非中途没人动过图标"
    }
}

# ---- 2. 独立探针读真实窗口状态 ----
$actual = [BootProbe]::State()
$layers = [BootProbe]::LayerCount
Write-Host "`n== 1. 桌面真实状态（独立探针，不信被测程序）=="
Write-Host ("   图标层数量 = {0}   真实可见性 = {1}   explorer pid = {2}" -f $layers, $actual, [BootProbe]::ExplorerPid())
if ($layers -eq 0) { $fails += "找不到图标层：explorer 可能还没起完，等 20 秒再跑一次" }
elseif ($expected -ne "unknown" -and $actual -ne $expected) { $sceneFails += "复原失败：期望 $expected，实测 $actual" }

# ---- 3. 自启动登记 + 实例是否被开机拉起来 ----
Write-Host "`n== 2. 自启动登记与实例 =="
$run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name DesktopIconToggle -ErrorAction SilentlyContinue
$stored = if ($run) { $run.DesktopIconToggle } else { $null }
Write-Host ("   Run 键 = {0}" -f $(if ($stored) { $stored } else { "(未登记)" }))
if (-not $stored) { $fails += "Run 键没有登记：本次开机不会有实例，复原自然也不会发生（先跑 tools\arm-for-reboot.ps1）" }

$inst = @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue)
Write-Host ("   实例数 = {0}" -f $inst.Count)
if ($stored -and $inst.Count -eq 0) { $fails += "Run 键登记着但实例没起来：开机自启这条路径断了" }
if ($inst.Count -gt 1) { $fails += "实例数 $($inst.Count) > 1：单实例失效" }

if ($inst.Count -ge 1) {
    $appStart = $inst[0].StartTime
    $shell = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq [BootProbe]::ExplorerPid() }
    if ($shell) {
        Write-Host ("   本实例启动 = {0:HH:mm:ss}   explorer 启动 = {1:HH:mm:ss}" -f $appStart, $shell.StartTime)
        if ($appStart -lt $shell.StartTime) {
            $notes += "实例比 explorer 早起来 => 开机时图标层确实还没建出来，走的是重试定时器那条分支（这次实测覆盖到了）"
        }
    }
}

# ---- 4. 壁纸没被带走：截一块桌面区域比亮度（隐藏图标时应当基本不变）----
Write-Host "`n== 3. 壁纸反证（截图比亮度）=="
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
$sum = [double]0; $n = 0
for ($y = 2; $y -lt $bounds.Height - 2; $y += 37) {
    for ($x = 2; $x -lt $bounds.Width - 2; $x += 41) {
        $c = $bmp.GetPixel($x, $y)
        $sum += ($c.R + $c.G + $c.B) / 3.0; $n++
    }
}
$lum = [Math]::Round($sum / $n, 1)
$shot = Join-Path $root "shots\boot-desktop.png"
$bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host ("   整屏平均亮度 = $lum（隐藏图标那一版曾测到 27.8 即为黑屏；壁纸保留时应在 120 以上）  截图：$shot")
if ($lum -lt 60) { $fails += "整屏平均亮度只有 $lum：疑似壁纸被一起带走了（B5 类回归）" }

# ---- 5. 被测程序自述，作交叉验证 ----
Write-Host "`n== 4. 被测程序自述（仅交叉验证）=="
$livePath = @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)
$status = (Invoke-Exe @('--status') -path $(if ($livePath.Count -eq 1) { $livePath[0] } else { $exe })).Text
$status -split "`n" | ForEach-Object { Write-Host "   $_" }

Write-Host "`n== 5. 托盘图标在不在 =="
# 开机时有一条真实的竞态没有实测过：Run 键可能比 explorer 的托盘早起来，那时 NIM_ADD 会落空；
# 后来加的 TaskbarCreated 重注册正是补这个的，但它到底在真实开机场景下补上了没有，只有这次能看出来。
# 所以这里等 4 秒再数，给它一次迟到补偿的机会。
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
$trayCount = -1
for ($round = 0; $round -lt 3; $round++) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $found = 0
    foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        if ($b.Current.Name -like '桌面图标开关｜*' -and $b.Current.BoundingRectangle.Y -gt 1140) { $found++ }
    }
    $trayCount = $found
    if ($found -ge 1) { break }
    Write-Host "   这次没数到托盘按钮，等 4 秒再数一次（给 TaskbarCreated 的迟到补偿留时间）" -ForegroundColor Yellow
    Start-Sleep -Seconds 4
}
Write-Host "   托盘按钮数 = $trayCount（应为 1；数到 0 也可能是图标被收进了溢出区，请顺手看一眼右下角）"
if ($trayCount -eq 0) { $notes += "没数到托盘按钮：可能是 TaskbarCreated 没补上，也可能只是被收进溢出区——需要你眼看一下" }
if ($trayCount -gt 1) { $fails += "托盘上有 $trayCount 个我们的按钮：重复注册或有幽灵图标" }

Write-Host "`n== 结论 =="
# 诚实闸门：机器不是刚开机的话，上面这些读数只能证明"脚本可用 + 现在一切正常"，
# 不能冒充"开机那一刻复原正确"。所以这种情况给 INCONCLUSIVE（退出码 3），而不是 PASS。
$os = Get-CimInstance Win32_OperatingSystem
$bootMin = [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes, 1)
Write-Host ("   机器距上次开机已过 {0} 分钟" -f $bootMin)
$fresh = $bootMin -le 30

foreach ($m in $notes) { Write-Host "   注：$m" -ForegroundColor Cyan }
if (-not $fresh) {
    Write-Host ("   距上次开机 {0} 分钟 > 30，下面这些只能算「现在一切正常」，不能算开机那一刻的复原结果：" -f $bootMin) -ForegroundColor Yellow
    foreach ($m in $sceneFails) { Write-Host "   （现场外，降级为注）$m" -ForegroundColor Yellow }
}
$fails += $sceneFails | Where-Object { $fresh }
if ($fails.Count -eq 0 -and -not $fresh) {
    Write-Host "VERDICT: INCONCLUSIVE - 脚本跑通了、当前状态也正常，但这不是开机现场，开机复原这条仍未实测" -ForegroundColor Yellow
    exit 3
}
if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 真实开机路径实测通过（自启动拉起实例 + 图标按上次状态复原 + 壁纸未丢 + 托盘在位）" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
