# 验收 P0：隐藏状态要活过"重启"（用重启实例模拟开机自启）。
# 步骤：显示 -> 隐藏 -> 杀掉实例 -> 再起实例 -> 应当仍是隐藏 -> 恢复显示。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

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

function Status([string]$arg) {
    $o = Join-Path $env:TEMP ("st-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process "dist\DesktopIconToggle.exe" -ArgumentList $arg -NoNewWindow -Wait -RedirectStandardOutput $o
    $t = [IO.File]::ReadAllText($o); Remove-Item $o -ErrorAction SilentlyContinue
    return $t
}
function Icons { ([regex]::Match((Status '--status'), 'icons\s+= (\w+)')).Groups[1].Value }
function Alive { @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count }

$fails = @()      # 逐条 PASS/FAIL 汇总到这里，结尾统一给退出码

# B19：场里可能已经有**另一条路径**的实例在跑（日常那份装在 %LOCALAPPDATA%，见 deploy-local + F28 属主校验）。
# 在 dist\ 下敲 --exit 退不掉它，而 mutex 又会让我们起的这份自己退出 —— 于是后面每一步读的都是**那一份**的状态。
# 所以第一步先按进程的 Path 用它自己的 exe 把在场的全退干净，之后本脚本才只对 dist 这一份负责。
foreach ($livePath in @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    Write-Host ("   先退掉在场的那一份：{0}" -f $livePath)
    $eo = Join-Path $env:TEMP ("rb-exit-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $livePath -ArgumentList '--exit' -NoNewWindow -Wait -RedirectStandardOutput $eo -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $eo, "$eo.err" -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 800

Stop-Instance
Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--boot"
Start-Sleep -Seconds 3
"1) 以 --boot 起实例（模拟开机自启）：icons=$(Icons) 实例=$(Alive)"

$null = (Status '--hide')
Start-Sleep -Milliseconds 400
"2) --hide 之后：icons=$(Icons)"

Stop-Instance
"3) 杀掉实例（模拟注销/重启）：icons=$(Icons)"

Start-Process "dist\DesktopIconToggle.exe" -ArgumentList "--boot"
Start-Sleep -Seconds 3
$after = Icons
$ok4 = ($after -eq 'hidden')
"4) 重新起实例：icons=$after  期望=hidden  $(if ($ok4) { 'PASS' } else { 'FAIL' })"
if (-not $ok4) { $fails += "第 4 步：--boot 起实例后图标不是 hidden（实测 $after）—— 隐藏状态没活过这次重启" }
"   实例自述: $((Status '--status') -split "`r?`n" | Where-Object { $_ -match 'flags|diag' })"

$null = (Status '--show')
Start-Sleep -Milliseconds 400
"5) 收尾恢复：icons=$(Icons)"

# 反向用例：先把状态记成"隐藏"，再用普通方式启动实例，不应动 explorer 的图标
$null = (Status '--hide')
Start-Sleep -Milliseconds 400
Stop-Instance
$null = (Status '--show')          # 手动改成显示，模拟"用户自己又点回来了"
Start-Sleep -Milliseconds 300
Start-Process "dist\DesktopIconToggle.exe"
Start-Sleep -Seconds 3
$noBoot = Icons
$ok6 = ($noBoot -eq 'visible')
"6) 不带 --boot 启动、且注册表记的是 hidden：icons=$noBoot 期望=visible  $(if ($ok6) { 'PASS（没抢方向盘）' } else { 'FAIL' })"
$null = (Status '--show')

# 打印过 FAIL 就必须给非零退出码，否则自动化把整轮当成功（原先结尾没有 exit）。
if (-not $ok6) { $fails += "第 6 步：不带 --boot 启动却抢了方向盘，或反向用例没保住 visible（实测 icons=$noBoot）" }
if ($fails.Count -gt 0) {
    foreach ($f in $fails) { "   FAIL: $f" }
    "VERDICT: FAIL"
    exit 1
}
"VERDICT: PASS"
exit 0
