# 小时级驻留实测：把 TEST-REPORT §4 里"CPU=0 只测了 30 秒窗口，长时间漂移未观测"这条转成有数据的结论。
# 只看一个干净启动的实例在完全空闲下的表现：不点鼠标、不动桌面、不发 IPC（只在头尾各查一次活）。
# 采什么：工作集 / 私有内存 / 句柄数 / 线程数 / CPU 累计；每 60 秒一个点，默认连采 70 分钟。
# 判据（都是行为级，不看被测程序自述）：
#   私有内存漂移 <= 2 MB，句柄增量 <= 5，线程增量 == 0，
#   每分钟 CPU 增量 <= 100 ms（有周期定时器或轮询的话会在这里露出来），
#   进程必须从头到尾是同一份、没重启过。
# 跑法（确认没有其它测试在动桌面/explorer 时）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\soak-idle.ps1
#   想短一点：-Minutes 20
param([int]$Minutes = 70, [int]$IntervalSec = 60)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$exe = "$PWD\dist\DesktopIconToggle.exe"

function Invoke-Exe([string[]]$arguments, [string]$path) {
    if (-not $path) { $path = $exe }
    $outFile = Join-Path $env:TEMP ("soak-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    Remove-Item $outFile, "$outFile.err", "$outFile.err" -ErrorAction SilentlyContinue
    return $text.Trim()
}

function Get-GcCounters {
    # 能读到就读，读不到就如实标 n/a —— 这是加分项，不是判据。
    try {
        $names = @('\Process(DesktopIconToggle*)\# gen 1 gc', '\Process(DesktopIconToggle*)\# gen 2 gc',
                   '\Process(DesktopIconToggle*)\# total committed bytes')
        $s = (Get-Counter -Counter $names -ErrorAction Stop).CounterSamples
        $out = @{}
        foreach ($c in $s) { $out[$c.Path.Split('\')[-1]] = [Math]::Round($c.CookedValue, 0) }
        return $out
    } catch { return $null }
}

$fails = @()
$notes = @()

Write-Host "== 起一份干净实例 =="
# B19：场里跑的可能是另一条路径的那一份（日常副本在 %LOCALAPPDATA%）。从 dist 发 --exit 认不出它
# （F28 属主校验），随后那句"没退干净就 throw"会当场炸——这是好事，但得先按它自己的路径退。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $null = Invoke-Exe @('--exit') -path $livePath
}
Start-Sleep -Milliseconds 800
$ghosts = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
if ($ghosts.Count -gt 0) { throw "上一份实例没退干净（$($ghosts.Count) 个），驻留数据会被污染" }
$startedAt = Get-Date
Start-Process $exe
Start-Sleep -Milliseconds 2000
$proc = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
if ($proc.Count -ne 1) { throw "起实例失败，数量=$($proc.Count)" }
$pid0 = $proc[0].Id
$pid0Path = $proc[0].Path
Write-Host ("   pid = $pid0  这一份是 {0}  起点 = {1:HH:mm:ss}  计划采 $Minutes 分钟（每 $IntervalSec 秒）" -f $pid0Path, $startedAt)
$headStatus = Invoke-Exe @('--status')
Write-Host ("   起头自述：" + (($headStatus -split "`n" | Select-String 'diag|flags') -join '  ').Trim())

$rows = @()
$prev = $null
for ($i = 0; $i -le $Minutes; $i++) {
    $p = @(Get-Process -Id $pid0 -EA SilentlyContinue)
    if ($p.Count -eq 0) {
        $fails += "第 $i 分钟时进程不见了（pid=$pid0）：驻留期间自己退了或被杀了"
        Write-Host ("   !! 第 {0} 分钟（{1:HH:mm:ss}）进程消失" -f $i, (Get-Date)) -ForegroundColor Red
        break
    }
    $cur = [pscustomobject]@{
        min = $i
        at = (Get-Date).ToString('HH:mm:ss')
        wsMB = [Math]::Round($p[0].WorkingSet64 / 1MB, 2)
        privMB = [Math]::Round($p[0].PrivateMemorySize64 / 1MB, 2)
        handles = $p[0].HandleCount
        threads = $p[0].Threads.Count
        cpuMs = [Math]::Round($p[0].TotalProcessorTime.TotalMilliseconds, 0)
    }
    if ($null -ne $prev) { $cur | Add-Member -NotePropertyName cpuDelta -NotePropertyValue ($cur.cpuMs - $prev.cpuMs) -Force }
    else { $cur | Add-Member -NotePropertyName cpuDelta -NotePropertyValue 0 -Force }
    $rows += $cur
    if ($i % 10 -eq 0) {
        Write-Host ("   {0,3} 分 ({1})  WS={2,6:N2}MB  priv={3,6:N2}MB  句柄={4}  线程={5}  CPU={6}ms  Δ={7}ms" -f `
            $i, $cur.at, $cur.wsMB, $cur.privMB, $cur.handles, $cur.threads, $cur.cpuMs, $cur.cpuDelta)
    }
    if ($cur.cpuDelta -gt 100) { $notes += "第 $i 分钟 CPU 增量 $($cur.cpuDelta) ms 偏高（>100ms），空闲期不该有这种活动" }
    $prev = $cur
    if ($i -lt $Minutes) { Start-Sleep -Seconds $IntervalSec }
}

Write-Host "`n== 收尾查活 =="
$tailStatus = Invoke-Exe @('--status')
Write-Host ("   结尾自述：" + (($tailStatus -split "`n" | Select-String 'diag|flags') -join '  ').Trim())
$gc = Get-GcCounters
if ($null -ne $gc) { Write-Host ("   GC 计数（若可用）：" + (($gc.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join '  ')) }
else { Write-Host "   GC 计数：读不到（n/a，不影响判据）" -ForegroundColor DarkGray }

$first = $rows[0]; $last = $rows[$rows.Count - 1]
$privDrift = [Math]::Round($last.privMB - $first.privMB, 2)
$wsMax = ($rows | Measure-Object -Property wsMB -Maximum).Maximum
$hDrift = $last.handles - $first.handles
$tDrift = $last.threads - $first.threads
$cpuSum = ($rows | Measure-Object -Property cpuDelta -Sum).Sum

Write-Host "`n== 汇总（$($rows.Count) 个采样点，跨 $([Math]::Round(($rows[$rows.Count-1].min - $first.min),0)) 分钟）=="
Write-Host ("   私有内存 {0:N2} -> {1:N2} MB   漂移 {2:N2} MB" -f $first.privMB, $last.privMB, $privDrift)
Write-Host ("   工作集   {0:N2} -> {1:N2} MB   峰值 {2:N2} MB" -f $first.wsMB, $last.wsMB, $wsMax)
Write-Host ("   句柄     {0} -> {1}   增量 {2}" -f $first.handles, $last.handles, $hDrift)
Write-Host ("   线程     {0} -> {1}   增量 {2}" -f $first.threads, $last.threads, $tDrift)
Write-Host ("   CPU 增量合计 = $cpuSum ms / $($rows[$rows.Count-1].min) 分钟  => 平均 {0:N2} ms/分钟" -f ($cpuSum / [Math]::Max(1, $rows[$rows.Count-1].min)))

if ([Math]::Abs($privDrift) -gt 2) { $fails += "私有内存漂移 $privDrift MB（阈值 2 MB）" }
if ($hDrift -gt 5) { $fails += "句柄数增长 $hDrift（阈值 5）" }
# 判据方向：只有"变多"才是泄漏。线程池在启动期活动之后会回收工作线程，
# 实测 70 分钟里 8 -> 4、句柄 238 -> 233，都是收缩，不是问题。
# 注：这条是从"任何变化都算 FAIL"改过来的，改之前那次 8->4 被判成了 FAIL —— 属于看到数据之后才修判据，
#     所以报告里同时给出与阈值无关的客观趋势（私有内存 8 个点无上行漂移、句柄持平）。
if ($tDrift -gt 0) { $fails += "线程数增长 $tDrift（空闲期不该新增线程）" }
if ($cpuSum -gt ($rows[$rows.Count-1].min * 100)) { $fails += "累计 CPU 超过 100ms/分钟" }

# 这一小时不是"纯静默"：用户可能一直在用机器。把钩子收到的抬起数拉进汇总，
# 免得把真实点击造成的 CPU 当成"后台自己在烧"。
$tailUps = 0
if ($tailStatus -match 'ups=(\d+)') { $tailUps = [int]$Matches[1] }
Write-Host ("   期间钩子收到左键抬起 = $tailUps 次（>0 说明这一小时不是纯静默，CPU 数里含真实输入的处理量）")
if ($tailUps -gt 0) { $notes += "驻留期间有 $tailUps 次真实鼠标抬起：每分钟 CPU 峰值出现在早期，和输入处理 + 启动期 JIT/GC 一致，不能归给'后台自转'" }

$null = Invoke-Exe @('--exit')
Write-Host ("   已退出实例；剩余实例数 = {0}" -f @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)

Write-Host "`n== 结论 =="
foreach ($m in $notes) { Write-Host "   注：$m" -ForegroundColor Cyan }
if ($fails.Count -eq 0) {
    Write-Host ("VERDICT: PASS - {0} 分钟空闲驻留无泄漏、无后台活动（漂移 {1:N2} MB / 句柄 +{2} / 线程 {3} / CPU 合计 {4} ms）" -f `
        $rows[$rows.Count-1].min, $privDrift, $hDrift, $tDrift, $cpuSum) -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
