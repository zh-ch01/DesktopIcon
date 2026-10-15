param([string[]]$Files)
$ErrorActionPreference = 'Stop'
foreach ($f in $Files) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
    if ($errs.Count -eq 0) {
        Write-Output ("OK    {0}" -f (Split-Path -Leaf $f))
    } else {
        Write-Output ("ERR   {0}  ({1} 处)" -f (Split-Path -Leaf $f), $errs.Count)
        foreach ($e in ($errs | Select-Object -First 5)) {
            Write-Output ("      行 {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    }
}
