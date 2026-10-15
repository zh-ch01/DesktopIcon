# 跑回归测试前的清场脚本：把"两份身份"的实例都退掉。
# 为什么需要：F28 那条属主校验（正确的安全行为）加上 deploy-local 的双路径部署之后，
# 在 dist\ 路径下敲 --exit 管不到 %LOCALAPPDATA% 那份 —— 两份 exe 是两个身份。
# 所以回归测试必须从同一路径起、并先把两份都清掉；跑完再 deploy-local.ps1 恢复日常自启。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$paths = @(
    "$PWD\dist\DesktopIconToggle.exe",
    (Join-Path $env:LOCALAPPDATA "DesktopIconToggle\DesktopIconToggle.exe")
)

Write-Host "== 清场：逐个路径 --exit，再看还有没有残留 =="
foreach ($p in $paths) {
    if (-not (Test-Path $p)) { Write-Host ("   跳过（不存在）：{0}" -f $p); continue }
    $o = Join-Path $env:TEMP ("prep-" + [Guid]::NewGuid().ToString("N") + ".txt")
    Start-Process $p -ArgumentList '--exit' -NoNewWindow -Wait -RedirectStandardOutput $o -ErrorAction SilentlyContinue | Out-Null
    Write-Host ("   {0} -> {1}" -f (Split-Path -Parent $p), ((Get-Content $o -Raw) -as [string]).Trim())
    Remove-Item $o, "$o.err" -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 1200
$left = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
if ($left.Count -gt 0) {
    Write-Host ("   !! 还有 {0} 个实例没退（pid={1}）—— 它们是强杀都清不掉的僵尸窗口还是别的路径的副本？请手工确认" -f `
        $left.Count, (($left | ForEach-Object { $_.Id }) -join ',')) -ForegroundColor Red
    exit 1
}
Write-Host "   实例数 = 0，可以跑测试了（测试脚本会各自从 dist\ 起一份）"
Write-Host "   跑完记得：powershell -File tools\deploy-local.ps1   # 把日常自启那一份放回去"
