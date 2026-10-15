# 验证 exe 换目录也能跑（自启登记的是绝对路径，移动后 SelfHeal 要能修回来）
$ErrorActionPreference = 'Stop'
$src = "D:\z\workspace\work3\DesktopIconToggle\dist\DesktopIconToggle.exe"
$tmp = Join-Path $env:TEMP "dit-portable"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Copy-Item $src (Join-Path $tmp "DesktopIconToggle.exe") -Force
$exe = Join-Path $tmp "DesktopIconToggle.exe"
function Run([string]$a) {
    $o = Join-Path $env:TEMP ("p-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $exe -ArgumentList $a -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue
    $t = [IO.File]::ReadAllText($o); Remove-Item $o -ErrorAction SilentlyContinue
    return $t
}
"1) 临时目录里跑 --status:"
(Run '--status') -split "`r?`n" | Where-Object { $_ -match 'exe|icons|autostart' } | ForEach-Object { "     $_" }
Start-Process $exe; Start-Sleep -Seconds 2
$t = Run '--status'
$ok = ($t -match 'instance\s+= .*\d+')
"2) 从临时目录启动实例: instance 可见=$ok"
$t2 = Run '--toggle'
"3) --toggle 从临时目录可用: $((($t2 -split "`r?`n") | Where-Object { $_ -match 'icons' }))"
(Run '--exit') | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
"4) 已清理临时目录: $(-not (Test-Path $tmp))"
