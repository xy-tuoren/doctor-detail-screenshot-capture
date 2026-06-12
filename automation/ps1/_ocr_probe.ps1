$AutomationRoot = Split-Path -Parent $PSScriptRoot
$ProjectRoot = Split-Path -Parent $AutomationRoot
$python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$ocrScript = Join-Path $AutomationRoot 'py\recognize_captcha.py'
$img = Join-Path $ProjectRoot 'logs\captcha-last.png'

Write-Host "python: $python"
Write-Host "img exists: $(Test-Path $img)"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $python
$psi.Arguments = "`"$ocrScript`" --serve"
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $false
$psi.CreateNoWindow = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

$proc = [System.Diagnostics.Process]::Start($psi)
$w = $proc.StandardInput
$r = $proc.StandardOutput
Start-Sleep -Milliseconds 300

for ($i = 1; $i -le 6; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $w.WriteLine($img)
    $w.Flush()
    $task = $r.ReadLineAsync()
    if ($task.Wait(8000)) {
        $line = $task.Result
        Write-Host ("call {0}: {1}ms -> '{2}'" -f $i, $sw.ElapsedMilliseconds, $line)
    }
    else {
        Write-Host ("call {0}: TIMEOUT after {1}ms" -f $i, $sw.ElapsedMilliseconds)
        break
    }
}

$w.WriteLine('__quit__')
$w.Flush()
$proc.WaitForExit(3000) | Out-Null
if (-not $proc.HasExited) { $proc.Kill() }
Write-Host 'done'
