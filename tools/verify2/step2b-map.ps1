. "$PSScriptRoot\_load.ps1"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$out = Join-Path $PSScriptRoot 'map.txt'
$sb = New-Object Text.StringBuilder
function S($s) { [void]$sb.AppendLine($s) }
[void][Qa.Win]::OpenDesktopListView()
S ("time=" + (Get-Date -Format 'HH:mm:ss') + " visibility=" + (Probe-Icons))
S ("FullScan step=24 pad=40 ->")
S ([Qa.Win]::FullScan(24, 40))
S ""
# where does UIA think the desktop icons are, and can it drive them?
$itemCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
S "--- UIA: desktop list items (descendants of Program Manager) ---"
$pmCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Program Manager')
$pm = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $pmCond)
$all = $pm.FindAll([Windows.Automation.TreeScope]::Descendants, $itemCond)
S ("uia_listitems=" + $all.Count)
for ($i = 0; $i -lt $all.Count; $i++) {
    $r = $all[$i].Current.BoundingRectangle
    S ("  [" + $i + "] name=[" + $all[$i].Current.Name + "] rect=" + [int]$r.X + "," + [int]$r.Y + " " + [int]$r.Width + "x" + [int]$r.Height)
}
[Qa.Win]::CloseDesktopListView()
$sb.ToString() | Out-File -Encoding utf8 $out
Write-Line ("WROTE " + $out)
