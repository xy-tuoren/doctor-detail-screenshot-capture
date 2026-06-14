# Static verification for export stabilization (no live export)
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'capture-doctor-details.ps1'

$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host '[FAIL] parse errors'
    $parseErrors | ForEach-Object { Write-Host $_.ToString() }
    exit 1
}
Write-Host '[OK] script parse'

$content = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

$fnMatch = [regex]::Match($content, 'function Get-ExportFlowState\s*\{([\s\S]*?)^\}', 'Multiline')
if (-not $fnMatch.Success) {
    Write-Host '[FAIL] Get-ExportFlowState not found'
    exit 1
}
$fnBody = $fnMatch.Groups[1].Value
$forbidden = @('dialog_ocr', 'loading_ocr', 'captcha_ocr', 'Test-CaptchaDialogByRegionOcr', 'Test-CaptchaImageReady')
foreach ($token in $forbidden) {
    if ($fnBody -match [regex]::Escape($token)) {
        Write-Host "[FAIL] forbidden token in Get-ExportFlowState: $token"
        exit 1
    }
}
Write-Host '[OK] Get-ExportFlowState OCR state paths removed'

$requiredFns = @(
    'Get-ExportProbeSnapshot',
    'Test-ExportCaptchaWindowPresent',
    'Test-ExportSaveDialogPresent',
    'Register-ExportCaptchaEmptyOcr',
    'Invoke-OptionalExportValidation',
    'Write-ExportProbeDiagnostics'
)
foreach ($fn in $requiredFns) {
    if ($content -notmatch "function $fn\s*\{") {
        Write-Host "[FAIL] missing function: $fn"
        exit 1
    }
}
Write-Host '[OK] ExportStateProbe functions present'

if ($content -notmatch "Method = 'probe_inconclusive'") {
    Write-Host '[FAIL] probe_inconclusive fallback missing'
    exit 1
}
Write-Host '[OK] no default ListReady on probe failure'

Write-Host ''
Write-Host 'Static verification passed. Run cmd\automation\export.cmd x3 on live app.'
exit 0
