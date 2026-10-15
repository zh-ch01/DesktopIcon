# F28 反证：实例发现必须确认"属主 exe 是同一个文件"，不能被同类名+同标题的窗口骗过去。
# 为什么要单独一条：F18 测的是"同标题、不同类名"，但类名字符串在别的进程里也能重复注册
# （我们的 RegisterClassExW 没带 CS_GLOBALCLASS，所以类名是进程局部的），只按类名+标题匹配仍然可被冒充。
# 造诱饵不需要手写 Win32：把我们自己的 exe 复制到另一个路径改名跑 ——
#   类名、标题都是硬编码常量 => 和真实例一模一样；可执行文件路径不同 => 正好是这条判据要分辨的那一类。
# 双向断言：
#   负向：从原路径问 --status，必须说"未运行"；--exit 不许把那份副本退掉。
#   正向：从副本路径问 --status，必须认得它（否则"永远返回 null"也能蒙过负向断言）。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$real = "$PWD\dist\DesktopIconToggle.exe"

function Invoke-PathExe([string]$path, [string[]]$arguments) {
    $o = Join-Path $env:TEMP ("os-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $e = Join-Path $env:TEMP ("os-err-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
    $text = ""
    if (Test-Path $o) { $text += (Get-Content $o -Raw) }
    if (Test-Path $e) { $text += (Get-Content $e -Raw) }
    Remove-Item $o, $e -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

$fails = @()
$spool = Join-Path $env:TEMP ("dit-owner-spoof-" + [Guid]::NewGuid().ToString("N"))
$copy = Join-Path $spool "DesktopIconToggle.exe"

Write-Host "== 0. 清场 =="
$null = Invoke-PathExe $real @('--exit')
Start-Sleep -Milliseconds 800
if (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count -gt 0) { throw "清场失败，还有实例在跑" }

Write-Host "== 1. 造一个'同类名+同标题、但不同文件'的实例 =="
New-Item -ItemType Directory -Force -Path $spool | Out-Null
Copy-Item $real $copy -Force
$copyPid = (Start-Process $copy -PassThru).Id
Start-Sleep -Milliseconds 2000
$alive = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
Write-Host ("   副本 pid={0}，当前同名进程数={1}" -f $copyPid, $alive.Count)
if ($alive.Count -ne 1) { throw "副本没起来或起多了（count=$($alive.Count)），后面断言无意义" }

Write-Host "`n== 2. 正向对照：从副本自己的路径问，必须认得 =="
$fromCopy = (Invoke-PathExe $copy @('--status')).Text
$seesSelf = $fromCopy -match "pid=$copyPid"
Write-Host ("   副本视角 instance 行 = " + (($fromCopy -split "`n" | Select-String 'instance') -join '').Trim())
if (-not $seesSelf) { $fails += "正向对照失败：副本都认不出自己 => 属主校验写死了永远不匹配，负向断言也就毫无意义" }

Write-Host "`n== 3. 负向：从原路径问，不许把副本当实例 =="
$fromReal = (Invoke-PathExe $real @('--status')).Text
$realLines = $fromReal -split "`n"
Write-Host ("   " + (($realLines | Select-String 'instance|icons|autostart') -join "`n   ").Trim())
if ($fromReal -match "pid=$copyPid") { $fails += "原路径把副本当成了自己的实例（instance 报出了副本 pid=$copyPid）" }
if ($fromReal -notmatch '未运行') { $fails += "原路径没有报'未运行'，说明它认到了某个实例：属主校验没生效" }

Write-Host "`n== 4. 负向：从原路径 --exit，不许把退出指令投给副本 =="
$null = Invoke-PathExe $real @('--exit')
Start-Sleep -Milliseconds 1500
$stillThere = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
Write-Host ("   --exit 之后同名进程数 = {0}（期望 1：副本必须还活着，我们没资格退它）" -f $stillThere.Count)
if ($stillThere.Count -ne 1) { $fails += "副本被原路径的 --exit 影响到了（进程数=$($stillThere.Count)）" }

Write-Host "`n== 5. 收尾：用副本自己的路径把它退掉，并删除临时目录 =="
$null = Invoke-PathExe $copy @('--exit')
Start-Sleep -Milliseconds 1200
$left = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
if ($left.Count -gt 0) { $fails += "副本没退干净，剩 $($left.Count) 个（pid=$(($left | ForEach-Object { $_.Id }) -join ','))" }
Remove-Item $spool -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("   临时目录已删 = {0}，剩余同名进程 = {1}" -f (-not (Test-Path $spool)), @(Get-Process DesktopIconToggle -EA SilentlyContinue).Count)

Write-Host "`n== 结论 =="
if ($fails.Count -eq 0) {
    Write-Host "VERDICT: PASS - 实例发现按'类名+标题+属主exe'三重确认：同类名同标题的陌生文件既不被认错、也不被误退" -ForegroundColor Green
    exit 0
}
foreach ($f in $fails) { Write-Host "   FAIL: $f" -ForegroundColor Red }
Write-Host "VERDICT: FAIL" -ForegroundColor Red
exit 1
