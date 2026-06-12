$errs = $null
$path = (Resolve-Path 'scripts\capture-doctor-details.ps1').Path
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    foreach ($e in $errs) { Write-Host ("ERR L{0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) }
}
else {
    Write-Host 'PARSE OK'
}
