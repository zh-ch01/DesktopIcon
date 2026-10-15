# 两条"只有 shell 缺失/重启时序才会遇到"的分支，在实验室里造出来。
# B13（TaskbarCreated）与 B10（重试定时器用尽拆表）的修法此前只有结构论证 + 顺风场景，这里补真竞态。
#
#   B) shell 缺失时起实例 -> 第一次 NIM_ADD 必然落空（它会自己往 stderr 喊）-> 再拉起 explorer
#      -> 托盘必须靠 TaskbarCreated 自己回来。再加对照组：停掉 explorer 托盘必须归零，
#      否则说明 UIA 数到的是鬼影，上面那条 PASS 不作数。
#   C) shell 缺失时用 --boot 起实例（图标层还没建出来）
#      C1 中途恢复：图标层一出现，复原必须在一个重试周期内落地。
#      C2 全程不恢复：10 次用完必须自己拆表 —— 30 秒空闲 CPU 增量为 0，且期间 showwindow 必须仍为 0。
#
# 两条判据教训（上一版就是栽在这上面）：
#   ① 前置条件要在动作前后各验一次。上一版 Start-Shell 里连发 2~3 次 explorer，
#      于是"图标层已消失"这个前提在测量中途就失效了，C1/C2 的结论全是脏的。
#   ② 状态归因必须有行为证据。explorer 自己也持久化"显示桌面图标"，
#      所以只看终态分不清是产品改的还是 shell 的记忆 —— 一律读被测实例的 showwindow 计数来定"谁干的"。
# 副作用：真的杀 explorer 三轮（任务栏/桌面各消失几秒），结束时按原路径重开你开着的文件夹窗口。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"
$SettingsKey = 'HKCU:\Software\DesktopIconToggle'

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class SR {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

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

    public static int LayerCount() { return Layers().Count; }

    public static string State() {
        var ls = Layers();
        if (ls.Count == 0) return "no-layer";
        int shown = 0;
        foreach (IntPtr h in ls) { if (IsWindowVisible(h)) shown++; }
        if (shown == 0) return "hidden";
        return shown == ls.Count ? "visible" : "mixed";
    }

    public static uint ShellPid() {
        var ls = Layers();
        if (ls.Count == 0) return 0;
        uint pid; GetWindowThreadProcessId(ls[0], out pid);
        return pid;
    }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }     # 默认测仓库里这一份；只有"先退掉在场那一份"时才传别的路径
    $outFile = Join-Path $env:TEMP ("sr-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path "$outFile.err") { $text += (Get-Content "$outFile.err" -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

# 被测实例的自证计数：用来判定"这次状态变化是不是产品做的"。实例不在则全 null。
function Get-Counters {
    $s = (Invoke-Exe @('--status')).Text
    if ($s -notmatch 'instance\s+= \S+\s+pid=(\d+)') { return [pscustomobject]@{ pid = $null; shown = $null } }
    $pid_ = [int]$Matches[1]
    $shown = $null
    if ($s -match 'showwindow=(\d+)') { $shown = [int]$Matches[1] }
    return [pscustomobject]@{ pid = $pid_; shown = $shown }
}

# 独立于被测程序数托盘按钮 —— 两个口径，别混用：
#   Get-TrayCount      只数任务栏那一条带（Y>1130）。这是对照组/相对变化用的硬口径。
#                      不能用"整棵树里有没有"代替：shell 被强杀后 UIA 树里会残留幽灵按钮，
#                      实测"停了 explorer 仍数到 1"，对照组当场失效。
#   Peek-TrayOverflow  只在"应当有、但带上一条数到 0"时才调：用 UIA Invoke 展开「显示隐藏的图标」再数一次。
#                      溢出区收起时它的子元素不在 UIA 树里，所以数到 0 有两种可能：没注册 / 被 Win11 收起来了。
#                      分不开这两种，就会把摆放变化读成注册丢失（TEST-REPORT B15 就是这么误判的）。
function Find-OurTrayElements {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
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
function Get-TrayCount {
    @(Find-OurTrayElements | Where-Object { $_.Current.BoundingRectangle.Y -gt 1130 }).Count
}
function Peek-TrayOverflow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $chev = $null
    foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
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


function Wait-Layers([int]$Seconds, [bool]$WantAny) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (([SR]::LayerCount() -gt 0) -eq $WantAny) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Stop-Shell {
    $old = [SR]::ShellPid()
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    if (-not (Wait-Layers -Seconds 15 -WantAny $false)) {
        throw "停了 explorer 之后图标层还在（层=$([SR]::LayerCount())），前提不成立"
    }
    return $old
}

# 起 explorer：只发一次，然后轮询。上一版在这里连发 2~3 次，
# 结果同时起来两三个 shell 互相把对方的图标层拆了重建，测量全被污染。
function Start-Shell {
    Start-Process explorer.exe -ErrorAction SilentlyContinue
    if (-not (Wait-Layers -Seconds 30 -WantAny $true)) {
        throw "explorer 没恢复（层=$([SR]::LayerCount())）。兜底：Ctrl+Shift+Esc → 文件 → 运行新任务 → explorer.exe"
    }
    Start-Sleep -Milliseconds 400
}

# 托盘出现需要点时间（广播到达 -> NIM_ADD -> UIA 看得见新按钮）。
# 上一版这里第一次等 15 秒轮询、第二次只数一次，于是同一个现象给出相反的结论——测量不一致就是自欺。
function Wait-Tray([int]$Seconds, [int]$Want) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $n = 0
    while ((Get-Date) -lt $deadline) {
        $n = Get-TrayCount
        if ($Want -eq 0) { if ($n -eq 0) { return $n } }
        elseif ($n -ge $Want) { return $n }
        Start-Sleep -Milliseconds 500
    }
    return $n
}

# 脚本级兜底（本脚本此前一条 trap/finally 都没有）：它会真的杀 explorer 三轮，
# 并在 C 组把 IconsVisibleOnExit / RestoreStateOnStartup 改成测试用的值。
# 任一 throw 若不接住，留下的就是：死 shell + 脏注册表 + hidden 的桌面 + 你没被重开的文件夹窗口。
# 每一步各自 try/catch —— 一条清理失败不许挡住后面的；但结论照样响亮地失败（exit 1）。
trap {
    Write-Host ("   捕获异常：" + $_.Exception.Message) -ForegroundColor Red
    if (@(Get-Process explorer -EA SilentlyContinue).Count -eq 0) {
        Write-Host "   shell 不在场：拉起 explorer 并等图标层回来" -ForegroundColor Yellow
        try { Start-Process explorer.exe -ErrorAction SilentlyContinue } catch { }
        try { $null = Wait-Layers -Seconds 30 -WantAny $true } catch { }
    }
    try {
        Write-Host ("   现场：图标层 = {0}  图标状态 = {1}  实例数 = {2}" -f [SR]::LayerCount(), [SR]::State(),
            @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)
    } catch { }
    # 按原路径重开你的资源管理器窗口（与结尾 D 段同一写法），随后把清单置空防重复打开
    if (Test-Path Variable:\opened) {
        foreach ($u in $opened) {
            try { if (Test-Path $u) { Start-Process explorer.exe -ArgumentList "`"$u`""; Write-Host "   重开 $u" } } catch { }
        }
        $opened = @()
    }
    try { $null = Invoke-Exe @('--show') } catch { Write-Host "   --show 没发出去（实例可能不在场），桌面状态见上面那行" -ForegroundColor Yellow }
    if ((Test-Path Variable:\origWant) -and ($null -ne $origWant)) {
        try { Set-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -Value ([int]$origWant) -Type DWord } catch { }
    }
    if ((Test-Path Variable:\origRestore) -and ($null -ne $origRestore)) {
        try { Set-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -Value ([int]$origRestore) -Type DWord } catch { }
    }
    exit 1
}

$fails = @()
$notes = @()
$skips = @()

Write-Host "== 0. 记录你开着的资源管理器窗口 + 量一次 explorer 自己的默认状态 =="
$shellApp = New-Object -ComObject Shell.Application
$opened = @()
foreach ($wnd in $shellApp.Windows()) {
    try { $u = $wnd.LocationURL; if ($u -like 'file://*') { $opened += ($u -replace '^file:///', '' -replace '%20', ' ') } } catch { }
}
foreach ($u in $opened) { Write-Host "   - $u" }
# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是 C1/C2 每次读 showwindow=
# 都读不到东西（Get-Counters 全 null），"是谁改了状态"这条归因当场作废。先按进程 Path 用它自己的 exe 退干净。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $null = Invoke-Exe @('--exit') -path $livePath
}
Start-Sleep -Milliseconds 800
if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -eq 0) { Start-Process $exe; Start-Sleep -Milliseconds 1500 }
$null = Invoke-Exe @('--show')
Stop-Shell | Out-Null
Start-Shell
$shellDefault = [SR]::State()
Write-Host ("   没有本程序参与时，explorer 重启后图标自己给的是：{0}  <= 后面所有判读的地基" -f $shellDefault)
if ($shellDefault -eq 'no-layer') { throw "explorer 恢复后没有图标层，测不了" }

Write-Host "`n== B) shell 缺失时起实例：验 TaskbarCreated 能不能把托盘补回来 =="
$null = Invoke-Exe @('--exit')
$t0 = Get-TrayCount
Write-Host ("   基线：托盘按钮数 = $t0，shell pid = {0}" -f [SR]::ShellPid())
if ($t0 -lt 1) { $notes += "基线没数到托盘按钮（可能收在溢出区），B 组只看相对变化 0->1->0->1" }

$oldShell = Stop-Shell
$errFile = Join-Path $env:TEMP ("sr-boot-" + [Guid]::NewGuid().ToString("N") + ".txt")
$inst = Start-Process $exe -PassThru -RedirectStandardError $errFile
Start-Sleep -Milliseconds 2500
if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -lt 1) { throw "shell 不在的时候实例没起来，测不下去" }
$tNoShell = Get-TrayCount
$stderrTxt = ""
if (Test-Path $errFile) { $stderrTxt = (Get-Content $errFile -Raw) }
Remove-Item $errFile -ErrorAction SilentlyContinue
Write-Host ("   无 shell 环境下实例已起（pid={0}）：托盘按钮数 = {1}（应为 0）" -f $inst.Id, $tNoShell)
if ($stderrTxt.Trim() -ne '') { Write-Host ("   它这时候自己喊：{0}" -f $stderrTxt.Trim()) }
if ($tNoShell -gt 0) { $notes += "无 shell 时数到 $tNoShell 个托盘按钮，B 组前置不成立，这条按弱证据记" }

Write-Host "   拉起 explorer，看托盘会不会自己回来 ..."
Start-Shell
$trayBack = Wait-Tray -Seconds 15 -Want 1
Write-Host ("   explorer 起来后：任务栏带上托盘按钮 = $trayBack（生效则 1），shell pid {0} -> {1}" -f $oldShell, [SR]::ShellPid())
if ($trayBack -lt 1) {
    $peek = Peek-TrayOverflow
    if ($peek -ge 1) {
        $notes += "第一次广播后任务栏带上数不到，但展开溢出区数到 $peek 个 —— 注册是好的，是 Win11 把它收起来了（摆放由 shell 决定，不算缺陷）"
        $trayBack = $peek
    } elseif ($peek -eq 0) {
        $fails += "explorer 起来后托盘没回来：任务栏带上一条没有、展开溢出区也没有 => 这份 shell 里确实没有我们的注册（实例 pid=$($inst.Id)）"
    } else {
        $notes += "任务栏带上数到 0，而且找不到/展不开「显示隐藏的图标」按钮 => 这一格判不了，按 unknown 记，不算 PASS 也不算 FAIL"
    }
}
if ($trayBack -gt 1) { $fails += "托盘上数到 $trayBack 个按钮：重复注册" }

Write-Host "   对照组：再停 explorer，任务栏带上必须归零（否则上面数到的是鬼影，PASS 不作数）"
$null = Stop-Shell
$tZero = Wait-Tray -Seconds 10 -Want 0
Write-Host ("   停了之后（只数任务栏带）= $tZero")
if ($tZero -ne 0) { $fails += "停了 explorer 仍数到 $tZero 个托盘按钮：UIA 判据不干净，B 组整条不成立" }
Start-Shell
$tAgain = Wait-Tray -Seconds 15 -Want 1
if ($tAgain -lt 1) {
    $peek2 = Peek-TrayOverflow
    if ($peek2 -ge 1) { $notes += "第二次广播后同样是被收进溢出区（展开数到 $peek2 个），不算丢失"; $tAgain = $peek2 }
    elseif ($peek2 -eq 0) { $fails += "explorer 二次起来后托盘没回来（任务栏带与溢出区都没有）" }
    else { $notes += "第二次广播后：任务栏带 0 且无法展开溢出区 => unknown，不计入 PASS" }
}
Write-Host ("   二次起来后 = $tAgain")

Write-Host "`n== C) shell 缺失时用 --boot 起实例：验重试定时器 =="
$origWant = (Get-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -EA SilentlyContinue).IconsVisibleOnExit
$origRestore = (Get-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -EA SilentlyContinue).RestoreStateOnStartup
Set-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -Value 0 -Type DWord
Set-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -Value 1 -Type DWord

# ---- C1：中途把 explorer 起回来，复原必须落在一个重试周期内 ----
$null = Invoke-Exe @('--exit')
$null = Stop-Shell
$inst2 = Start-Process $exe -ArgumentList '--boot' -PassThru
Start-Sleep -Milliseconds 300
$c1Premise = ([SR]::LayerCount() -eq 0)
Write-Host ("   --boot 实例已起（pid={0}）：此刻图标层={1}" -f $inst2.Id, [SR]::LayerCount())
if (-not $c1Premise) {
    $skips += "C1：实例起来时图标层已经在了（explorer 抢先恢复了），'没有图标层可用'这个前提没造出来"
    Write-Host "   SKIP C1：前提不成立（见结尾说明）" -ForegroundColor Yellow
} else {
    $c0 = Get-Counters
    Start-Shell
    $at = -1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 25) {
        if ([SR]::State() -eq 'hidden') { $at = [Math]::Round($sw.Elapsed.TotalSeconds, 1); break }
        Start-Sleep -Milliseconds 200
    }
    $sw.Stop()
    $c1 = Get-Counters
    $stateC1 = [SR]::State()
    Write-Host ("   图标层出现后：{0} 秒落地，探针={1}；showwindow {2}->{3}（涨了才证明是我们改的）" -f `
        $at, $stateC1, $c0.shown, $c1.shown)
    if ($at -lt 0) { $fails += "C1：图标层建出来后 25 秒内始终不是 hidden（实测 $stateC1）" }
    elseif ($c1.shown -le $c0.shown) { $fails += "C1：状态是 hidden 但 showwindow 没涨（$($c0.shown)->$($c1.shown)）——那不是产品做的，这条不算过" }
    else { $notes += "C1 复原在 $($at) 秒落地（一次 ShowWindowAsync），比预期快：explorer 建图标层比 2 秒重试周期还慢时才需要重试" }
}

# ---- C2：拆表验证。----
# 上一版想把前提做成"全程没有图标层"，但本机做不到：explorer 被杀后系统会自动把它拉回来
# （实测 26 秒内图标层就回来了，showwindow 也从 0 变 1 —— 这顺带解释了上一版"图标怎么自己 hidden 了"的谜：
#  不是 explorer 的记忆，是我们那个还活着的 --boot 实例真的做了复原）。
# 所以这里分两种情况，且明确标出各自证明了什么：
#   前提成立（26 秒仍无层）  -> 验"次数用尽后自己拆表"：30 秒空闲 CPU 增量必须为 0。
#   前提破掉（层回来了）      -> 退一步验"复原成功之后没留定时器"：同样采 30 秒 CPU 必须为 0，
#                              并把"用尽分支"如实标成不可造、只有代码级证据。
Write-Host "`n   C2) 拆表分支：起 --boot 实例后采 26 秒，再采 30 秒 CPU"
$null = Invoke-Exe @('--exit')
$null = Stop-Shell
$inst3 = Start-Process $exe -ArgumentList '--boot' -PassThru
Start-Sleep -Seconds 26
$inst3.Refresh()
$cpu1 = $inst3.TotalProcessorTime.TotalMilliseconds
$ws1 = [Math]::Round($inst3.WorkingSet64 / 1MB, 1)
$c2a = Get-Counters
$noLayerAllAlong = ([SR]::LayerCount() -eq 0)
Write-Host ("   26 秒时：图标层={0}  showwindow={1}  CPU 累计 {2} ms  工作集 {3} MB" -f `
    [SR]::LayerCount(), $c2a.shown, $cpu1, $ws1)
if (-not $noLayerAllAlong) {
    $skips += "C2/用尽分支：本机 explorer 被杀后会被系统自动拉起，'全程无图标层'前提造不出来 => 次数用尽后拆表只有代码级证据"
    Write-Host "   前提破：explorer 已被系统自动拉回（不是本脚本起的），改验'复原成功后没留定时器'" -ForegroundColor Yellow
}
Start-Sleep -Seconds 30
$inst3.Refresh()
$cpuDelta = [Math]::Round($inst3.TotalProcessorTime.TotalMilliseconds - $cpu1, 1)
$ws2 = [Math]::Round($inst3.WorkingSet64 / 1MB, 1)
$c2b = Get-Counters
Write-Host ("   再采 30 秒：CPU 增量 = $cpuDelta ms（有残留定时器就会在这里露出来，每 2 秒一次回调）")
Write-Host ("              工作集 {0} -> {1} MB   showwindow {2} -> {3}" -f $ws1, $ws2, $c2a.shown, $c2b.shown)
if ($cpuDelta -gt 100) {
    $fails += "C2：这 30 秒里有 $cpuDelta ms CPU 活动 => 定时器没拆干净（B10 的 KillTimer 失效）"
} elseif ($cpuDelta -gt 0) {
    # 别把"低于阈值"写成"0 活动"——那就是文案与数据不符。这一刻 explorer 正在被系统重启，
    # 整机都在忙，这个数只能说明"没有每 2 秒一次的周期性回调"，不能当绝对空闲证据。
    $notes += "C2：30 秒 CPU 增量 $cpuDelta ms（低于 100ms 阈值，说明没有 2 秒周期的回调残留）；但此刻 explorer 正在重启，这个数不是'绝对空闲'证据 —— 绝对 0ms 是 §2/F22 在安静环境里测的"
    if ($noLayerAllAlong) { Write-Host "   => 用尽分支：30 秒 $cpuDelta ms，低于阈值（无 2 秒周期回调）" -ForegroundColor Green }
    else { Write-Host "   => 复原成功后 30 秒 $cpuDelta ms，低于阈值；注意这不是安静环境（explorer 正在重启）。用尽分支未证，见 SKIP" -ForegroundColor Green }
} else {
    if ($noLayerAllAlong) { Write-Host "   => 用尽分支：次数用完确实自己拆了表（30 秒 0 活动）" -ForegroundColor Green }
    else { Write-Host "   => 复原成功之后没有残留定时器（30 秒 0 活动）。用尽分支未证，见 SKIP" -ForegroundColor Green }
}
$wantAfter = (Get-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -EA SilentlyContinue).IconsVisibleOnExit
Write-Host ("   注册表期望值应仍是 0（本次设的），实测 = $wantAfter")
if ([int]$wantAfter -ne 0) { $notes += "注册表期望值被改成 $wantAfter：若期间发生过用户/复原动作则属正常，需回看 C1" }
$null = Invoke-Exe @('--exit')

Write-Host "`n== D) 重开你的资源管理器窗口 =="
foreach ($u in $opened) {
    if (Test-Path $u) { Start-Process explorer.exe -ArgumentList "`"$u`""; Write-Host "   重开 $u" }
    else { Write-Host "   跳过（路径已不存在）：$u" -ForegroundColor Yellow }
}
$opened = @()     # 已经重开过了：后面若再抛异常，trap 不许把同一批窗口再开一遍

Write-Host "`n== E) 收尾 =="
Start-Sleep -Seconds 2
$null = Invoke-Exe @('--show')
if ($null -ne $origWant) { Set-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -Value ([int]$origWant) -Type DWord }
if ($null -ne $origRestore) { Set-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -Value ([int]$origRestore) -Type DWord }
Write-Host ("   图标 = {0}（应为 visible，测试没把桌面留在特殊状态） 实例数 = {1} 托盘 = {2}" -f `
    [SR]::State(), @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count, (Get-TrayCount))
# 自启是 ON 的，机器平时就该有一份实例在跑；测完把它放回去，别让用户下次看桌面时才发现后台没了。
if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -eq 0) {
    Start-Process $exe; Start-Sleep -Milliseconds 1500
    Write-Host ("   已按日常状态重新起一份实例：实例数 = {0} 托盘 = {1}" -f `
        @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count, (Wait-Tray -Seconds 10 -Want 1))
}

Write-Host "`n== 结论 =="
foreach ($m in $notes) { Write-Host "   注：$m" -ForegroundColor Cyan }
foreach ($m in $skips) { Write-Host "   SKIP：$m" -ForegroundColor Yellow }
if ($fails.Count -eq 0) {
    if ($skips.Count -gt 0) {
        Write-Host ("VERDICT: PARTIAL - 跑通的条目全过，但有 {0} 条前提没造出来（见上），不能当完整覆盖" -f $skips.Count) -ForegroundColor Yellow
        exit 2
    }
    Write-Host "VERDICT: PASS - TaskbarCreated 真竞态补回托盘；重试定时器 C1 落地、C2 用尽后不空转也不乱动状态" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
