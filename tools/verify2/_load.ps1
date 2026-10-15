# Shared bootstrap for the 2nd-round QA scripts. Loads the independent Win32 probe.
$ErrorActionPreference = 'Stop'
$script:QaRoot = 'D:\z\workspace\work3\qa-dit-2nd'
if (-not ('Qa.Win' -as [type])) {
    Add-Type -Path (Join-Path $script:QaRoot 'winprobe.cs')
}
# physical pixels, so cursor/SendInput/WindowFromPoint agree with the PerMonitorV2 product
[void][Qa.Win]::SetProcessDPIAware()

function Probe-Icons   { return [Qa.Win]::IconsVisibility() }
function Probe-Detail  { return [Qa.Win]::DefViewDetail() }
function Get-Cursor    { return [Qa.Win]::Cursor() }
function Write-Line($s) { [Console]::Out.WriteLine($s) }

# Waits up to $timeoutMs for the probe to leave $from. Returns @{flipped;to;ms}
function Wait-Flip([string]$from, [int]$timeoutMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -le $timeoutMs) {
        $now = Probe-Icons
        if ($now -ne $from) {
            return [pscustomobject]@{ flipped = $true; to = $now; ms = $sw.ElapsedMilliseconds }
        }
        Start-Sleep -Milliseconds 5
    }
    return [pscustomobject]@{ flipped = $false; to = (Probe-Icons); ms = $sw.ElapsedMilliseconds }
}
