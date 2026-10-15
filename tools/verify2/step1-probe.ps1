# Step 1: independent probe. Never calls the product.
. "$PSScriptRoot\_load.ps1"

$progman = [Qa.Win]::FindWindowW('Progman', $null)
Write-Line ("PROBE progman=" + $progman + " class=" + [Qa.Win]::ClassNameOf($progman))
$roots = [Qa.Win]::DesktopRoots()
Write-Line ("PROBE roots=" + ($roots -join ',') + " (progman + WorkerW)")
$views = [Qa.Win]::DefViews()
Write-Line ("PROBE defviews=" + $views.Count)
foreach ($v in $views) {
    Write-Line ("PROBE defview hwnd=" + $v + " visible=" + [Qa.Win]::IsWindowVisible($v) + " children=" + ([Qa.Win]::ChildClasses($v)))
}
$lv = [Qa.Win]::IconListView()
Write-Line ("PROBE listview=" + $lv + " class=" + [Qa.Win]::ClassNameOf($lv) + " chain=" + [Qa.Win]::AncestorChain($lv))
if ($lv -ne [IntPtr]::Zero) {
    $pid2 = 0
    [void][Qa.Win]::GetWindowThreadProcessId($lv, [ref]$pid2)
    Write-Line ("PROBE listview_pid=" + $pid2 + " procname=" + (Get-Process -Id $pid2).ProcessName)
    Write-Line ("PROBE itemcount=" + [Qa.Win]::ItemCount($lv))
}
Write-Line ("PROBE visibility=" + (Probe-Icons))
Write-Line ("PROBE screen=" + [Qa.Win]::GetSystemMetrics(0) + 'x' + [Qa.Win]::GetSystemMetrics(1) +
    " workarea=" + [Qa.Win]::GetSystemMetrics(78) + ',' + [Qa.Win]::GetSystemMetrics(79) +
    ' ' + [Qa.Win]::GetSystemMetrics(78) + 'x' + [Qa.Win]::GetSystemMetrics(79))
Write-Line ("PROBE dblclicktime_ms=" + [Qa.Win]::GetDoubleClickTime())
$c = Get-Cursor
Write-Line ("PROBE cursor=" + $c[1] + ',' + $c[2])
Write-Line ("PROBE taskbar_probe_at_960_590=" + [Qa.Win]::RootClassAt(960, 590))
Write-Line ("PROBE ipc_window=" + [Qa.Win]::FindIpcWindow())
