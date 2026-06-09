param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Find-PythonExecutable {
    $candidates = @(
        (Join-Path $ProjectRoot '.venv\Scripts\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe')
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }

    $fromPath = @(Get-Command python, python3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
    foreach ($path in $fromPath) {
        if ($path -match '\\WindowsApps\\') { continue }
        if (Test-Path $path) { return $path }
    }
    return $null
}

$venvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$requirements = Join-Path $ProjectRoot 'scripts\requirements-ocr.txt'

if (-not (Test-Path $requirements)) {
    throw "Missing requirements file: $requirements"
}

if (-not (Test-Path $venvPython)) {
    $systemPython = Find-PythonExecutable
    if ([string]::IsNullOrWhiteSpace($systemPython)) {
        throw 'Python not found. Install Python 3.10+ first, then run this script again.'
    }

    Write-Step ("Creating project venv with: {0}" -f $systemPython)
    & $systemPython -m venv (Join-Path $ProjectRoot '.venv')
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create .venv'
    }
}

Write-Step 'Installing OCR dependencies into project .venv ...'
& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r $requirements
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to install OCR dependencies'
}

Write-Step 'OCR environment ready.'
