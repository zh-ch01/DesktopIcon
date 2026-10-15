. "$PSScriptRoot\_load.ps1"
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'case-a.txt'
$sb = New-Object Text.StringBuilder
function S($s) { [void]$sb.AppendLine((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $s); Write-Line $s }
$exe = 'D:\z\workspace\work3\DesktopIconToggle\dist\DesktopIconToggle.exe'
$shell = New-Object -ComObject Shell.Application
$c0 = Get-Cursor

function Stop-Instances {
    Get-Process DesktopIconToggle -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400
}

try {
    Stop-Instances
    S ("A0 exe=" + $exe)
    S ("A0 sha256=" + (Get-FileHash $exe -Algorithm SHA256).Hash)
    Start-Process -FilePath $exe
    Start-Sleep -Seconds 2
    $procs = @(Get-Process DesktopIconToggle -ErrorAction SilentlyContinue)
    S ("A1 instances=" + $procs.Count + " pid=" + ($procs.Id -join ','))
    S ("A1 status_before=" + ((& $exe --status 2>&1) -join ' / '))
    S ("A1 probe=" + (Probe-Icons) + " detail=" + (Probe-Detail))

    $c0 = Get-Cursor
    S ("A2 cursor_saved=" + $c0[1] + ',' + $c0[2])
    $shell.MinimizeAll()
    Start-Sleep -Milliseconds 1500
    S ("A2 MinimizeAll done, probe=" + (Probe-Icons))

    [void][Qa.Win]::OpenDesktopListView()
    $bp = [Qa.Win]::BlankPoint(40, 20)
    S ("A3 blank_point found=" + $bp[0] + " x=" + $bp[1] + " y=" + $bp[2] + " grid_tested=" + $bp[3] + " icon_boxes=" + $bp[4])
    if ($bp[0] -ne 1) { throw 'no blank desktop point available' }
    $bx = $bp[1]; $by = $bp[2]
    S ("A3 blank_point=" + $bx + ',' + $by + " window_from_point=" + ([Qa.Win]::PointReport($bx, $by, [IntPtr]::Zero)))
    $hb = [Qa.Win]::HitCompare($bx, $by)
    S ("A3 subhit " + $hb)
    $ic = [Qa.Win]::CollectIcons()
    S ("A3 icons_on_desktop=" + ($ic.Count - 1))

    for ($round = 1; $round -le 3; $round++) {
        $before = Probe-Icons
        if ($before -ne 'visible') {
            [void][Qa.Win]::ShowWindow(([Qa.Win]::DefViews())[0], 5)
            Start-Sleep -Milliseconds 300
            $before = Probe-Icons
        }
        [void][Qa.Win]::SetCursorPos($bx, $by)
        Start-Sleep -Milliseconds 120
        $c = Get-Cursor
        S ("A4 round=$round before=$before cursor=" + $c[1] + ',' + $c[2])
        $t0 = Get-Date
        $sent = [Qa.Win]::InjectDoubleClick(40)
        $r1 = Wait-Flip 'visible' 3000
        $lat1 = ([int]((Get-Date) - $t0).TotalMilliseconds)
        S ("A4 round=$round hide: sent_inputs=$sent flipped=" + $r1.flipped + " to=" + $r1.to + " probe_latency=" + $r1.ms + 'ms wall=' + $lat1 + 'ms')
        Start-Sleep -Milliseconds 500
        $t1 = Get-Date
        [void][Qa.Win]::InjectDoubleClick(40)
        $r2 = Wait-Flip 'hidden' 3000
        $lat2 = ([int]((Get-Date) - $t1).TotalMilliseconds)
        S ("A4 round=$round show: flipped=" + $r2.flipped + " to=" + $r2.to + " probe_latency=" + $r2.ms + 'ms wall=' + $lat2 + 'ms')
        Start-Sleep -Milliseconds 500
        if (-not $r1.flipped -or -not $r2.flipped) {
            S ("A4 round=$round STATUS PROBE -> " + ((& $exe --status 2>&1) -join ' / '))
        }
    }
    S ("A5 final_probe=" + (Probe-Icons))
}
finally {
    [Qa.Win]::CloseDesktopListView()
    if ($null -ne $c0) { [void][Qa.Win]::SetCursorPos($c0[1], $c0[2]) }
    $c = Get-Cursor
    S ("F cursor_now=" + $c[1] + ',' + $c[2])
    Stop-Instances
    S ("F probe_before_show=" + (Probe-Icons))
    foreach ($v in [Qa.Win]::DefViews()) { [void][Qa.Win]::ShowWindow($v, 5) }
    Start-Sleep -Milliseconds 400
    S ("F probe_after_show=" + (Probe-Icons))
    $shell.UndoMinimizeAll()
    Start-Sleep -Milliseconds 1200
    S ("F UndoMinimizeAll done")
    $sb.ToString() | Out-File -Encoding utf8 $out
}
