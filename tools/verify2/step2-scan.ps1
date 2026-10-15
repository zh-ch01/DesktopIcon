. "$PSScriptRoot\_load.ps1"
$out = Join-Path $PSScriptRoot 'scan.txt'
$sb = New-Object Text.StringBuilder
function S($s) { [void]$sb.AppendLine($s) }

S ("time=" + (Get-Date -Format 'HH:mm:ss'))
S ("progman=" + [Qa.Win]::Progman() + " roots=" + ([Qa.Win]::DesktopRoots().Count) + " defviews=" + ([Qa.Win]::DefViews().Count))
S ("probe_visibility=" + (Probe-Icons) + " detail=" + (Probe-Detail))
[void][Qa.Win]::OpenDesktopListView()
S ("listview " + [Qa.Win]::ListViewHandle() + " itemcount=" + [Qa.Win]::ItemCountNow())
S ""
S "--- visible top-level windows (biggest first): what already covers the desktop ---"
foreach ($w in ([Qa.Win]::TopWindows() | Select-Object -First 10)) { S ("  " + $w) }
S ""
S "--- desktop icons: LVM_GETITEMRECT(0x100E) + LVM_GETITEMPOSITION(0x1010) + LVM_GETITEMTEXTW(0x1073) ---"
$icons = [Qa.Win]::CollectIcons()
foreach ($l in $icons) { S ("  " + $l) }
S ""
S "--- real LVM_SUBITEMHITTEST(0x1039) vs the id the product sends(0x103F) ---"
foreach ($l in $icons) {
    if ($l -notmatch '^(\d+)\|') { continue }
    $parts = $l.Split('|')
    if ($parts[3] -match 'c=(-?\d+),(-?\d+)') {
        $cx = [int]$Matches[1]; $cy = [int]$Matches[2]
        S ("  [" + $parts[1] + "] " + ([Qa.Win]::HitCompare($cx, $cy)))
    }
}
S ""
S "--- blank desktop point, >=40px from every icon box, root must be Progman/WorkerW, subhit must show no ONITEM ---"
$bp = [Qa.Win]::BlankPoint(40, 20)
S ("  found=" + $bp[0] + " x=" + $bp[1] + " y=" + $bp[2] + " grid_points_tested=" + $bp[3] + " icon_boxes=" + $bp[4])
if ($bp[0] -eq 1) {
    S ("  point_report=" + [Qa.Win]::PointReport($bp[1], $bp[2], [IntPtr]::Zero))
    S ("  compare " + ([Qa.Win]::HitCompare($bp[1], $bp[2])))
    ("" + $bp[1] + "," + $bp[2]) | Out-File -Encoding ascii (Join-Path $PSScriptRoot 'blank-point.txt')
}
[Qa.Win]::CloseDesktopListView()
$sb.ToString() | Out-File -Encoding utf8 $out
Write-Line ("WROTE " + $out)
