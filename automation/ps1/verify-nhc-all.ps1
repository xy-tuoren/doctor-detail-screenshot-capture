# Incrementally OCR-verify all captures/卫健委/*.png until complete.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)

$report = "logs\verify-nhc-report.csv"
$totalPng = (Get-ChildItem "captures\卫健委\*.png").Count

while ($true) {
    & .\.venv\Scripts\python.exe -m src.cli verify-nhc-captures --limit 80
    if (-not (Test-Path $report)) { break }
    $done = (Import-Csv $report -Encoding UTF8).Count
    Write-Host "Progress: $done / $totalPng"
    if ($done -ge $totalPng) { break }
}

Write-Host "Done. Report: $report"
