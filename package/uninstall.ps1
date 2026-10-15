# 桌面图标开关 DesktopIconToggle —— 卸载脚本
# 顺序很重要：**先验明"这确实是本程序的安装目录"，再动手**。
# 第一版不是这个顺序，实测出两个真缺陷：它会直接执行目标目录里那个叫 DesktopIconToggle.exe 的文件
# （喂它一份改名复制来的 notepad，它就真的把 notepad 启动了），而且先无条件删掉 HKCU 的 Run 键、
# 之后才发现目录根本不是我们的 —— 指错路径就会把一个正常工作的自启项删掉。现在这些都堵住了。
param(
    [string]$TargetDir = (Join-Path $env:LOCALAPPDATA 'DesktopIconToggle'),
    [switch]$RemoveSettings = $false
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $TargetDir 'DesktopIconToggle.exe'

function Test-OurExe([string]$path) {
    # 判身份用文件元数据，绝不"跑一下看看"：ProductName 来自我们的程序集名。
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path $path)) { return $false }
    try { return (Get-Item $path).VersionInfo.ProductName -eq 'DesktopIconToggle' } catch { return $false }
}
function Invoke-OurExe([string]$path, [string[]]$arguments) {
    $o = Join-Path $env:TEMP ("unin-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $null = Start-Process -FilePath $path -ArgumentList $arguments -PassThru -Wait -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError "$o.err"
    Remove-Item $o, "$o.err" -ErrorAction SilentlyContinue
}

Write-Host "== 0. 验明身份（不通过就什么都不动）=="
if (-not (Test-OurExe $exe)) {
    Write-Host ("   拒绝执行：{0} 不是本程序（ProductName 对不上，或文件不存在）。本次未改动任何东西。" -f $exe) -ForegroundColor Red
    Write-Host '   要卸载请先确认安装目录；默认是 %LOCALAPPDATA%\DesktopIconToggle'
    exit 4
}
Write-Host ("   确认是本程序：{0}" -f $exe)
$foreign = @(Get-ChildItem $TargetDir -Filter '*.exe' -EA SilentlyContinue | Where-Object { -not (Test-OurExe $_.FullName) })

Write-Host "`n== 1. 把桌面图标放回显示，再正常退出实例（只退认得出是我们产品的那些）=="
$paths = @($exe)
$paths += @(Get-Process DesktopIconToggle -EA SilentlyContinue | Select-Object -ExpandProperty Path -Unique | Where-Object { Test-OurExe $_ })
foreach ($p in ($paths | Select-Object -Unique)) {
    Write-Host ("   收尾：{0}" -f $p)
    $null = Invoke-OurExe $p @('--show')
    $null = Invoke-OurExe $p @('--exit')
}
Start-Sleep -Milliseconds 800
$left = @(Get-Process DesktopIconToggle -EA SilentlyContinue | Where-Object { Test-OurExe $_.Path })
if ($left.Count -gt 0) { throw ("还有 {0} 个本程序实例没退（pid={1}），不敢继续删" -f $left.Count, (($left | ForEach-Object Id) -join ',')) }

Write-Host "`n== 2. 清自启项（只有它确实指向这一份才动它）=="
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$v = (Get-ItemProperty $runKey -EA SilentlyContinue).DesktopIconToggle
if ($null -eq $v) {
    Write-Host "   没有这一项，跳过"
} elseif ($v -like ('*' + $exe + '*')) {
    Remove-ItemProperty $runKey -Name DesktopIconToggle
    Write-Host "   已删除：$v"
    if ((Get-ItemProperty $runKey -EA SilentlyContinue).DesktopIconToggle) { throw "自启项没删掉" }
} else {
    Write-Host ("   保留不动：这一项指向别处的安装 {0}" -f $v) -ForegroundColor Yellow
}

Write-Host "`n== 3. 删安装目录 =="
if ($foreign.Count -gt 0) {
    Write-Host ("   不删目录：{0} 里还有不是本程序的 exe（{1}）。请你自己看过再删。" -f $TargetDir, (($foreign | ForEach-Object Name) -join ', ')) -ForegroundColor Yellow
    $refused = $true
} else {
    Remove-Item $TargetDir -Recurse -Force
    Write-Host "   已删除 $TargetDir"
}

if ($RemoveSettings) {
    $sk = 'HKCU:\Software\DesktopIconToggle'
    if (Test-Path $sk) { Remove-Item $sk -Recurse -Force; Write-Host "   设置项已清除（恢复默认）" }
} else {
    Write-Host "   设置项保留在 HKCU\Software\DesktopIconToggle（要一起清就加 -RemoveSettings）"
}

if ($refused) {
    Write-Host "`n卸载部分完成：程序已停止、自启已清（若确实指向本目录），但目录里有别家的 exe，我没删。" -ForegroundColor Yellow
    exit 4
}
Write-Host "`n卸载完成。系统侧兜底：右键桌面 → 查看 → 显示桌面图标。"
