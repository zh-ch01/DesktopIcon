# 分步诊断：--boot 的复原到底是"谁做的、哪一步丢的"。
# 动机：verify-shell-race.ps1 的 C1 报"复原没落地"、C2 报"用尽之后图标却是 hidden"，
# 两条合起来说明我分不清"我们改的"和"explorer 自己持久化的显示/隐藏设置"。
# 手段：在每个时刻变化点都读一次被测程序的自述计数（showwindow / toggle_failed）+ 独立探针的真实可见性。
#   showwindow 涨了 = 我们做的；没涨而状态变了 = explorer 自己的记忆；都没动 = 复原没执行。
# 只测不改配置默认值之外的东西，跑完把两个注册表值恢复原状。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"
$SettingsKey = 'HKCU:\Software\DesktopIconToggle'

Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class DB {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

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

    public static int Count() { return Layers().Count; }
}
'@ -ReferencedAssemblies System.Runtime.InteropServices

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }     # 默认测仓库里这一份；只有"先退掉在场那一份"时才传别的路径
    $outFile = Join-Path $env:TEMP ("db-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process -FilePath $path -ArgumentList $arguments -NoNewWindow -Wait `
        -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err" | Out-Null
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return $text.Trim()
}

# 一次采样：独立探针 + 被测实例自述计数。instance 不在时返回 n/a。
function Show([string]$label) {
    $s = Invoke-Exe @('--status')
    $inst = if ($s -match 'instance\s+= \S+\s+pid=(\d+)') { $Matches[1] } else { '-' }
    $shown = if ($s -match 'showwindow=(\d+)') { $Matches[1] } else { '-' }
    $pairs = if ($s -match 'pairs=(\d+)') { $Matches[1] } else { '-' }
    $failed = if ($s -match 'toggle_failed=(\d+)') { $Matches[1] } else { '-' }
    Write-Host ("   {0,-34} 层={1} 探针={2,-8} pid={3,-6} showwindow={4,-3} pairs={5,-3} failed={6}" -f `
        $label, [DB]::Count(), [DB]::State(), $inst, $shown, $pairs, $failed)
    return [pscustomobject]@{ state = [DB]::State(); shown = $shown; pid0 = $inst }
}

function Wait-Layers([int]$Seconds, [bool]$WantAny) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (([DB]::Count() -gt 0) -eq $WantAny) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

$orig = @{ }
foreach ($k in @('IconsVisibleOnExit', 'RestoreStateOnStartup')) {
    $v = (Get-ItemProperty -Path $SettingsKey -Name $k -EA SilentlyContinue).$k
    $orig[$k] = $v
}

try {
    Write-Host "== 1. 先量一次「explorer 自己的记忆」：不启动被测程序，只杀/起 explorer =="
    # B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
    # 在 dist\ 下敲 --exit 退不掉它 —— 那这一步量到的"explorer 自己的记忆"其实是那份实例改的，地基全错。
    # 先按进程的 Path 用它自己的 exe 把在场的退干净。
    foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
        Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
        $null = Invoke-Exe @('--exit') -path $livePath
    }
    Start-Sleep -Milliseconds 800
    $null = Invoke-Exe @('--exit')
    $null = Invoke-Exe @('--show')
    Show "基线（我们刚 --show）" | Out-Null
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    $null = Wait-Layers -Seconds 15 -WantAny $false
    Write-Host ("   explorer 已停：层={0}" -f [DB]::Count())
    Start-Process explorer.exe -ErrorAction SilentlyContinue
    $null = Wait-Layers -Seconds 30 -WantAny $true
    Start-Sleep -Seconds 8
    $shellOnly = Show "explorer 独自重启后（无被测实例）"
    Write-Host ("   => explorer 自己的默认是 {0}。这一步是后面所有判读的地基" -f $shellOnly.state)

    Write-Host "`n== 2. 期望 hidden，趁 explorer 还在初始化时起 --boot 实例 =="
    Set-ItemProperty -Path $SettingsKey -Name IconsVisibleOnExit -Value 0 -Type DWord
    Set-ItemProperty -Path $SettingsKey -Name RestoreStateOnStartup -Value 1 -Type DWord
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    $null = Wait-Layers -Seconds 15 -WantAny $false
    Write-Host ("   explorer 已停：层={0}" -f [DB]::Count())
    $inst = Start-Process $exe -ArgumentList '--boot' -PassThru
    Start-Sleep -Milliseconds 300
    Show "+0.3s 实例刚起（层应该还没有）" | Out-Null
    Start-Process explorer.exe -ErrorAction SilentlyContinue
    $null = Wait-Layers -Seconds 30 -WantAny $true
    Show "+层刚出现" | Out-Null
    Start-Sleep -Seconds 2
    Show "+2s（第 1~2 次重试之间）" | Out-Null
    Start-Sleep -Seconds 3
    Show "+5s" | Out-Null
    Start-Sleep -Seconds 5
    Show "+10s" | Out-Null
    Start-Sleep -Seconds 10
    $end = Show "+20s"
    Write-Host ""
    if ($end.state -eq 'hidden') { Write-Host "   结论：复原落地了（hidden）" -ForegroundColor Green }
    else { Write-Host "   结论：20 秒后仍是 $($end.state) —— 复原没落地" -ForegroundColor Red }
    Write-Host ("   对照地基：explorer 独自重启会给 {0}；本步终态 {1}" -f $shellOnly.state, $end.state)
}
finally {
    $null = Invoke-Exe @('--show')
    foreach ($k in $orig.Keys) {
        if ($null -ne $orig[$k]) { Set-ItemProperty -Path $SettingsKey -Name $k -Value ([int]$orig[$k]) -Type DWord }
        else { Remove-ItemProperty -Path $SettingsKey -Name $k -ErrorAction SilentlyContinue }
    }
    Write-Host "`n   已把两个注册表值恢复原状；图标 = $([DB]::State())"
}
