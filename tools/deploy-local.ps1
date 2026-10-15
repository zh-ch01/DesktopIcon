# 把"日常自启的那一份"放到只有本人可写的目录，绕开 D: 卷 ACL 的继承问题（详见 TEST-REPORT §9）。
# 为什么需要：D:\ 根给 NT AUTHORITY\Authenticated Users:(M) 且 (OI)(CI) 继承，
#   所以 dist\DesktopIconToggle.exe 的有效 ACL 允许本机任意登录账号原地改写；
#   而 HKCU\...\Run 正指向它 —— 不提权，但会变成"用户自己批准、路径与 --status 输出都正常"的开机执行体。
# 这个脚本只做加法：复制一份到 %LOCALAPPDATA%\DesktopIconToggle\，由**那一份**去登记自启并常驻。
# 仓库里的 dist\ 保持不动，仍然是构建与回归测试用的那一份字节。
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$src = "$PWD\dist\DesktopIconToggle.exe"
$dstDir = Join-Path $env:LOCALAPPDATA "DesktopIconToggle"
$dst = Join-Path $dstDir "DesktopIconToggle.exe"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Invoke-PathExe([string]$path, [string[]]$arguments) {
    $o = Join-Path $env:TEMP ("dep-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError "$o.err"
    $text = ""
    if (Test-Path $o) { $text += (Get-Content $o -Raw) }
    if (Test-Path "$o.err") { $text += (Get-Content "$o.err" -Raw) }
    Remove-Item $o, "$o.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

Write-Host "== 1. 产物 ACL 对照（这就是要换目录的原因）=="
foreach ($p in @($src, $dstDir)) {
    if (Test-Path $p) { Write-Host ("   {0}" -f $p); (icacls $p 2>&1) | ForEach-Object { Write-Host "      $_" } }
}

Write-Host "`n== 2. 复制并核对哈希 =="
if (-not (Test-Path $src)) { throw "没有 $src，先跑 build.ps1" }
New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
$null = Invoke-PathExe $src @('--exit')
Copy-Item $src $dst -Force
$h1 = (Get-FileHash -Path $src -Algorithm SHA256).Hash
$h2 = (Get-FileHash -Path $dst -Algorithm SHA256).Hash
Write-Host ("   dist   SHA256 = {0}" -f $h1)
Write-Host ("   部署副本 SHA256 = {0}   一致 = {1}" -f $h2, ($h1 -eq $h2))
if ($h1 -ne $h2) { throw "复制后哈希不一致，别登记一个来路不明的启动项" }

Write-Host "`n== 3. 由部署副本登记自启（Run 键写的就是它自己的绝对路径）=="
Write-Host ("   {0}" -f (Invoke-PathExe $dst @('--autostart')).Text)
$stored = (Get-ItemProperty $runKey -Name DesktopIconToggle -EA SilentlyContinue).DesktopIconToggle
Write-Host ("   独立回读 Run 键 = {0}" -f $(if ($stored) { $stored } else { '(空)' }))
if ($stored -notlike ('"*' + $dst.Replace('\','\\') + '"*') -and $stored -notlike ('"*' + $dst + '"*')) {
    throw "Run 键没有指向部署副本（实际 $stored），自启仍指向旧路径"
}

Write-Host "`n== 4. 起一份常驻实例 =="
Start-Process $dst
Start-Sleep -Milliseconds 1500
$live = @(Get-Process DesktopIconToggle -EA SilentlyContinue)
Write-Host ("   实例数 = {0}" -f $live.Count)
if ($live.Count -ne 1) { throw "实例数不对（$($live.Count)）" }
$st = (Invoke-PathExe $dst @('--status')).Text
($st -split "`n" | Select-String 'instance|icons|autostart|flags') | ForEach-Object { Write-Host ("   " + $_.ToString().Trim()) }

Write-Host @"

完成。要点：
  * 开机自启现在指向 $dst（只有本人/SYSTEM/Admins 可写），下次开机会起那一份。
  * 仓库里的 dist\ 仍然是构建与回归测试用的同一份字节；两份 exe 是"两个身份"，
    所以在 dist 路径下敲 --status 会如实报「未运行」——那是 F28 那条属主校验应有的行为，不是坏了。
  * 回退：powershell -File tools\disarm-for-reboot.ps1（关自启 + 恢复显示图标），或删掉 $dstDir。
"@
