. "$PSScriptRoot\_load.ps1"
$exe = 'D:\z\workspace\work3\DesktopIconToggle\dist\DesktopIconToggle.exe'
$out = Join-Path $PSScriptRoot 'diag-chain.txt'
$sb = New-Object Text.StringBuilder
function S($s) { [void]$sb.AppendLine((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $s); Write-Line $s }
$shell = New-Object -ComObject Shell.Application

try {
    Get-Process DesktopIconToggle -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    S ("X0 ping_before=" + [Qa.Win]::Ping())
    Start-Process -FilePath $exe
    Start-Sleep -Seconds 2
    S ("X1 instances=" + (@(Get-Process DesktopIconToggle -EA SilentlyContinue).Count) + " ping=" + [Qa.Win]::Ping())
    $shell.MinimizeAll()
    Start-Sleep -Milliseconds 1200
    [void][Qa.Win]::OpenDesktopListView()
    $bp = [Qa.Win]::BlankPoint(40, 20)
    S ("X2 blank_point found=" + $bp[0] + " " + $bp[1] + ',' + $bp[2] + " report=" + ([Qa.Win]::PointReport($bp[1], $bp[2], [IntPtr]::Zero)))
    S ("X2 subhit " + ([Qa.Win]::HitCompare($bp[1], $bp[2])))
    $icons = [Qa.Win]::CollectIcons()
    $firstLine = $icons[1].Split('|')
    $ic = $firstLine[3]
    S ("X2 first_icon name=" + $firstLine[1] + " rect=" + $firstLine[2] + " " + $ic)

    $spy = [Qa.Win]::StartMouseSpy()
    S ("X3 own_hook_installed=" + $spy)
    [void][Qa.Win]::PumpPeek(400)
    S ("X3 quiet 400ms window: " + [Qa.Win]::SpySummary())

    [void][Qa.Win]::SetCursorPos($bp[1], $bp[2])
    S ("X4 injected A: DOWN/UP + 40ms + DOWN/UP at " + $bp[1] + ',' + $bp[2] + " visibility_before=" + (Probe-Icons))
    [void][Qa.Win]::InjectDoubleClick(40)
    [void][Qa.Win]::PumpPeek(1000)
    S ("X4   visibility_after=" + (Probe-Icons) + " ping=" + [Qa.Win]::Ping())
    S ("X4   " + [Qa.Win]::SpySummary())
    foreach ($e in ([Qa.Win]::SpyEvents())) { S ("       " + $e) }

    [void][Qa.Win]::SetCursorPos($bp[1], $bp[2])
    S ("X5 injected B: 4 events in ONE SendInput call")
    [void][Qa.Win]::InjectDoubleClickBurst()
    [void][Qa.Win]::PumpPeek(1000)
    S ("X5   visibility_after=" + (Probe-Icons) + " ping=" + [Qa.Win]::Ping())
    S ("X5   " + [Qa.Win]::SpySummary())
    $ev = [Qa.Win]::SpyEvents()
    foreach ($e in ($ev | Select-Object -Skip 20)) { S ("       " + $e) }

    [void][Qa.Win]::SetCursorPos($bp[1], $bp[2])
    S ("X6 injected C: gap 10ms")
    [void][Qa.Win]::InjectDoubleClick(10)
    [void][Qa.Win]::PumpPeek(1500)
    S ("X6   visibility_after=" + (Probe-Icons))
    S ("X6   " + [Qa.Win]::SpySummary())
}
finally {
    [void][Qa.Win]::StopMouseSpy()
    foreach ($v in [Qa.Win]::DefViews()) { [void][Qa.Win]::ShowWindow($v, 5) }
    [Qa.Win]::CloseDesktopListView()
    S ("X9 probe_after_cleanup=" + (Probe-Icons))
    Get-Process DesktopIconToggle -ErrorAction SilentlyContinue | Stop-Process -Force
    $shell.UndoMinimizeAll()
    $sb.ToString() | Out-File -Encoding utf8 $out
}
