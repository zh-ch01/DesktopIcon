# 撤销布防：关掉开机自启、把桌面图标恢复显示、清掉期望值文件，并退出后台实例。
# 跑法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\disarm-for-reboot.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Invoke-Exe([string[]]$arguments) {
    $outFile = Join-Path $env:TEMP ("dis-arm-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $p = Start-Process -FilePath "$PWD\dist\DesktopIconToggle.exe" -ArgumentList $arguments `
        -PassThru -Wait -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $text = ""
    if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw) }
    if (Test-Path "$outFile.err") { $text += (Get-Content "$outFile.err" -Raw) }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

Write-Host "== 1. 恢复显示桌面图标 =="
if (@(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count -eq 0) {
    Start-Process "$PWD\dist\DesktopIconToggle.exe"; Start-Sleep -Milliseconds 900
}
Write-Host ("   {0}" -f (Invoke-Exe @('--show')).Text)

Write-Host "`n== 2. 关闭开机自启 =="
Write-Host ("   {0}" -f (Invoke-Exe @('--no-autostart')).Text)
$run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name DesktopIconToggle -ErrorAction SilentlyContinue
Write-Host ("   独立回读 Run 键 = {0}" -f $(if ($run) { $run.DesktopIconToggle } else { '(已清除)' }))
if ($run) { throw "Run 键没清掉，自启仍会生效" }

Write-Host "`n== 3. 清掉期望值文件并退出实例 =="
Remove-Item (Join-Path $root "boot-expect.txt") -ErrorAction SilentlyContinue
Write-Host ("   {0}" -f (Invoke-Exe @('--exit')).Text)
Start-Sleep -Milliseconds 800
Write-Host ("   剩余实例数 = {0}" -f @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue).Count)
Write-Host "`n机器已回到「没布防」的状态：自启 off、图标 visible、无常驻实例。"
