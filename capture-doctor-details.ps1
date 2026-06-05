param(
    [ValidateSet('Probe','Prototype','Batch','Search','SearchNames','Calibrate','Review')]
    [string]$Mode = 'Probe',

    [string]$MainWindowTitleRegex = '8\.9\.4|医师电子化注册信息系统',
    [string]$DetailWindowTitleRegex = '信息展示|执业信息|详细信息',
    [string]$ViewDetailButtonRegex = '查看详',

    [string]$OutputDir = (Join-Path $PSScriptRoot 'captures'),
    [string]$LogPath = (Join-Path $PSScriptRoot 'capture-log.csv'),
    [string]$CalibrationPath = (Join-Path $PSScriptRoot 'calibration.json'),

    [int]$StartIndex = 1,
    [int]$Limit = 0,
    [int]$WaitSeconds = 8,
    [int]$MaxScrolls = 80,
    [double]$DetailButtonXRatio = 0.84,
    [int]$DetailButtonRightInset = 50,
    [double]$SearchBoxXRatio = 0.78,
    [double]$SearchBoxYRatio = 0.30,
    [int]$TableHeaderHeight = 0,
    [int]$TableRowHeight = 31,
    [int]$StopAfterConsecutiveFailures = 3,
    [string]$SearchName = '',
    [switch]$SearchAllMatches,

    # 姓名系列截图相关
    [string[]]$Names = @(),
    [string]$NamesFile = '',
    [int]$SearchWaitSeconds = 3,
    [int]$DetailWaitSeconds = 6,
    [int]$MaxRowsPerName = 50,
    [int]$CalibrateCountdown = 6,
    [switch]$NoOcr,

    [switch]$UseAutomationButtons,
    [switch]$UsePaneDetection,
    [switch]$Elevate,
    [switch]$Resume,
    [switch]$NoScroll,
    [switch]$KeepDetailWindowOpen
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
"@

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Arg {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

if ($Elevate -and -not (Test-IsAdministrator)) {
    $argParts = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-Arg $PSCommandPath),
        '-Mode', $Mode,
        '-MainWindowTitleRegex', (Quote-Arg $MainWindowTitleRegex),
        '-DetailWindowTitleRegex', (Quote-Arg $DetailWindowTitleRegex),
        '-ViewDetailButtonRegex', (Quote-Arg $ViewDetailButtonRegex),
        '-OutputDir', (Quote-Arg $OutputDir),
        '-LogPath', (Quote-Arg $LogPath),
        '-StartIndex', $StartIndex,
        '-Limit', $Limit,
        '-WaitSeconds', $WaitSeconds,
        '-MaxScrolls', $MaxScrolls,
        '-DetailButtonXRatio', $DetailButtonXRatio,
        '-DetailButtonRightInset', $DetailButtonRightInset,
        '-SearchBoxXRatio', $SearchBoxXRatio,
        '-SearchBoxYRatio', $SearchBoxYRatio,
        '-TableHeaderHeight', $TableHeaderHeight,
        '-TableRowHeight', $TableRowHeight,
        '-StopAfterConsecutiveFailures', $StopAfterConsecutiveFailures,
        '-SearchName', (Quote-Arg $SearchName),
        '-NamesFile', (Quote-Arg $NamesFile)
    )
    if ($Names -and $Names.Count -gt 0) {
        foreach ($n in $Names) { $argParts += '-Names'; $argParts += (Quote-Arg $n) }
    }
    if ($SearchAllMatches) { $argParts += '-SearchAllMatches' }
    if ($UseAutomationButtons) { $argParts += '-UseAutomationButtons' }
    if ($UsePaneDetection) { $argParts += '-UsePaneDetection' }
    if ($Resume) { $argParts += '-Resume' }
    if ($NoScroll) { $argParts += '-NoScroll' }
    if ($KeepDetailWindowOpen) { $argParts += '-KeepDetailWindowOpen' }
    $argParts = @('-NoExit') + $argParts
    Start-Process powershell.exe -Verb RunAs -ArgumentList ($argParts -join ' ')
    Write-Step '已启动管理员 PowerShell 窗口。请在 UAC 中点「是」，并在新窗口中查看运行日志（窗口会保留，勿在运行中关闭）。'
    exit
}

if ((-not (Test-IsAdministrator)) -and ($Mode -in @('Prototype','Batch'))) {
    Write-Step 'Warning: this PowerShell is not elevated. If the target application runs as administrator, simulated clicks may be ignored. Re-run with -Elevate or start PowerShell as administrator.'
}

function Safe-Int {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 0 }
    if ($Value -gt [int]::MaxValue) { return [int]::MaxValue }
    if ($Value -lt [int]::MinValue) { return [int]::MinValue }
    return [int]$Value
}

function Sanitize-FileName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    $invalid = [Regex]::Escape((-join [IO.Path]::GetInvalidFileNameChars()))
    $clean = [Regex]::Replace($Value.Trim(), "[$invalid]+", '_')
    $clean = [Regex]::Replace($clean, '\s+', '')
    if ($clean.Length -gt 40) { $clean = $clean.Substring(0, 40) }
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'unknown' }
    return $clean
}

function Get-RootWindows {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Window
    )
    $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
}

function Get-WindowByTitle {
    param([string]$TitleRegex)
    $matchedWindows = @()
    foreach ($win in Get-RootWindows) {
        $title = $win.Current.Name
        if ($title -match $TitleRegex) { $matchedWindows += $win }
    }
    return $matchedWindows | Sort-Object { $_.Current.BoundingRectangle.Top } | Select-Object -First 1
}

function Get-MainWindowTitlePatterns {
    param([string]$UserPattern)
    $patterns = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($UserPattern)) {
        foreach ($part in ($UserPattern -split '\|')) {
            $trimmed = $part.Trim()
            if ($trimmed.Length -gt 0) { $patterns.Add($trimmed) }
        }
    }
    $builtin = -join @(
        [char]0x533B, [char]0x5E08, [char]0x7535, [char]0x5B50, [char]0x5316,
        [char]0x6CE8, [char]0x518C, [char]0x4FE1, [char]0x606F, [char]0x7CFB, [char]0x7EDF
    )
    foreach ($extra in @('8\.9\.4', $builtin, '注册信息', '电子化注册')) {
        if (-not $patterns.Contains($extra)) { $patterns.Add($extra) }
    }
    return $patterns
}

function Find-MainApplicationWindow {
    param([string]$TitleRegex)

    foreach ($pattern in (Get-MainWindowTitlePatterns -UserPattern $TitleRegex)) {
        $main = Get-WindowByTitle $pattern
        if ($null -ne $main) { return $main }
    }

    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        if ($proc.MainWindowHandle -eq 0) { continue }
        $title = $proc.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        foreach ($pattern in (Get-MainWindowTitlePatterns -UserPattern $TitleRegex)) {
            if ($title -match $pattern) {
                $fromHandle = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]($proc.MainWindowHandle))
                if ($null -ne $fromHandle) { return $fromHandle }
            }
        }
    }
    return $null
}

function Write-MainWindowNotFoundHelp {
    param([string]$TitleRegex)
    Write-Step 'Main window not found.'
    if (Test-IsAdministrator) {
        Write-Step 'This PowerShell is elevated (Administrator). If the doctor app is a normal window, Windows blocks automation across privilege levels.'
        Write-Step 'Close the admin window and run: .\run-batch.cmd  (do not use run-batch-as-admin.cmd).'
    }
    else {
        Write-Step 'Open the doctor registration app and stay on the list page, then run again.'
    }
    Write-Step ("Current -MainWindowTitleRegex: {0}" -f $TitleRegex)
    Write-Step 'Top-level windows with a title:'
    foreach ($win in Get-RootWindows) {
        $title = $win.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            Write-Host ("  - {0}" -f $title)
        }
    }
    Write-Step 'If your window title differs, run: .\capture-doctor-details.ps1 -Mode Probe -MainWindowTitleRegex "part-of-title"'
}

function Get-WindowHandles {
    $set = @{}
    foreach ($win in Get-RootWindows) {
        $handle = [int]$win.Current.NativeWindowHandle
        if ($handle -ne 0) { $set[$handle] = $true }
    }
    return $set
}

function Bring-ToFront {
    param([System.Windows.Automation.AutomationElement]$Element)
    $handle = [IntPtr]([int]$Element.Current.NativeWindowHandle)
    [NativeWin32]::ShowWindow($handle, 9) | Out-Null
    [NativeWin32]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, 0x0043) | Out-Null
    Start-Sleep -Milliseconds 80
    [NativeWin32]::SetWindowPos($handle, [IntPtr](-2), 0, 0, 0, 0, 0x0043) | Out-Null
    [NativeWin32]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 250
}

function Element-IsVisible {
    param([System.Windows.Automation.AutomationElement]$Element)
    $rect = $Element.Current.BoundingRectangle
    return (($rect.Width -gt 2) -and ($rect.Height -gt 2) -and (-not $Element.Current.IsOffscreen))
}

function Get-InvokeButtons {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$NameRegex
    )
    $items = @()
    $types = @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::Hyperlink,
        [System.Windows.Automation.ControlType]::Text
    )
    foreach ($controlType in $types) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            $controlType
        )
        foreach ($element in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
            if ((Element-IsVisible $element) -and ($element.Current.Name -match $NameRegex)) {
                $items += $element
            }
        }
    }

    $paneCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Pane
    )
    foreach ($pane in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $paneCond)) {
        if (-not (Element-IsVisible $pane)) { continue }
        $name = $pane.Current.Name
        if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch $NameRegex) { continue }
        $patternObj = $null
        if ($pane.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObj)) {
            $items += $pane
        }
    }

    return $items | Sort-Object { $_.Current.BoundingRectangle.Top }, { $_.Current.BoundingRectangle.Left }
}

function Get-RowLikeAncestor {
    param([System.Windows.Automation.AutomationElement]$Element)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $current = $Element
    for ($i = 0; $i -lt 8; $i++) {
        if ($null -eq $current) { break }
        $type = $current.Current.ControlType.ProgrammaticName
        if ($type -match 'DataItem|ListItem|Custom|Pane') { return $current }
        $current = $walker.GetParent($current)
    }
    return $Element
}

function Get-ElementTextSummary {
    param([System.Windows.Automation.AutomationElement]$Element)
    $parts = New-Object System.Collections.Generic.List[string]
    $cond = [System.Windows.Automation.Condition]::TrueCondition
    foreach ($child in $Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        $name = $child.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $type = $child.Current.ControlType.ProgrammaticName
            if ($type -notmatch 'Button') { $parts.Add($name.Trim()) }
        }
        if ($parts.Count -ge 20) { break }
    }
    $selfName = $Element.Current.Name
    if (-not [string]::IsNullOrWhiteSpace($selfName)) { $parts.Insert(0, $selfName.Trim()) }
    return (($parts | Select-Object -Unique) -join ' | ')
}

function Get-DetailIdentity {
    param([string]$Text)
    $name = $null
    $license = $null

    if ($Text -match '姓名\s*[:：]?\s*([^\s|，,;；]+)') { $name = $Matches[1] }
    if ($Text -match '执业证书编码\s*[:：]?\s*([0-9A-Za-z]+)') { $license = $Matches[1] }
    if (-not $license -and $Text -match '证书编码\s*[:：]?\s*([0-9A-Za-z]+)') { $license = $Matches[1] }

    return @{ Name = $name; License = $license }
}

function Get-RectIntersection {
    param(
        [System.Windows.Rect]$A,
        [System.Windows.Rect]$B
    )
    $left = [Math]::Max($A.Left, $B.Left)
    $top = [Math]::Max($A.Top, $B.Top)
    $right = [Math]::Min(($A.Left + $A.Width), ($B.Left + $B.Width))
    $bottom = [Math]::Min(($A.Top + $A.Height), ($B.Top + $B.Height))
    $width = $right - $left
    $height = $bottom - $top
    if ($width -le 2 -or $height -le 2) { return $null }
    return New-Object System.Windows.Rect($left, $top, $width, $height)
}

function Get-ScreenRectHash {
    param([System.Windows.Rect]$Rect)

    $left = [int][Math]::Max(0, [Math]::Floor($Rect.Left))
    $top = [int][Math]::Max(0, [Math]::Floor($Rect.Top))
    $width = [int][Math]::Max(4, [Math]::Ceiling($Rect.Width))
    $height = [int][Math]::Max(4, [Math]::Ceiling($Rect.Height))

    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $stream = New-Object System.IO.MemoryStream
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($width, $height)))
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($stream.ToArray())
            return ([BitConverter]::ToString($hash) -replace '-', '')
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-DetailClickPoint {
    param(
        [System.Windows.Rect]$TableRect,
        [System.Windows.Rect]$MainRect,
        [int]$RowOnPage,
        [int]$HeaderHeight,
        [int]$RowHeight,
        [double]$XRatio,
        [int]$RightInset
    )
    $visibleTable = Get-RectIntersection -A $TableRect -B $MainRect
    if ($null -eq $visibleTable) { $visibleTable = $TableRect }

    if ($RightInset -gt 0) {
        $clickX = Safe-Int (($visibleTable.Left + $visibleTable.Width) - $RightInset)
        $maxX = Safe-Int (($MainRect.Left + $MainRect.Width) - 12)
        if ($clickX -gt $maxX) { $clickX = $maxX }
    }
    else {
        $clickX = Safe-Int ($MainRect.Left + ($MainRect.Width * $XRatio))
    }

    $clickY = Safe-Int ($visibleTable.Top + $HeaderHeight + ($RowHeight / 2) + ($RowOnPage * $RowHeight))
    return @{ X = $clickX; Y = $clickY; VisibleTable = $visibleTable }
}

function Get-LargePaneMap {
    param([System.Windows.Automation.AutomationElement]$Root)
    $map = @{}
    if (-not $UsePaneDetection) { return $map }

    $paneCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Pane
    )
    foreach ($pane in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $paneCond)) {
        if ($pane.Current.IsOffscreen) { continue }
        $rect = $pane.Current.BoundingRectangle
        if ($rect.Width -lt 480 -or $rect.Height -lt 240) { continue }
        if ($rect.Width -gt 1300 -or $rect.Height -gt 950) { continue }
        $key = ('{0},{1},{2},{3}' -f (Safe-Int $rect.Left), (Safe-Int $rect.Top), (Safe-Int $rect.Width), (Safe-Int $rect.Height))
        $map[$key] = $pane
    }
    return $map
}

function Find-NewDetailPane {
    param(
        [hashtable]$BeforePaneMap,
        [System.Windows.Automation.AutomationElement]$MainWindow
    )
    foreach ($entry in (Get-LargePaneMap -Root $MainWindow).GetEnumerator()) {
        if (-not $BeforePaneMap.ContainsKey($entry.Key)) { return $entry.Value }
    }
    return $null
}

function Invoke-ElementAction {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [System.Windows.Automation.AutomationElement]$FocusWindow = $null
    )
    if ($null -ne $FocusWindow) { Bring-ToFront $FocusWindow }
    else { Bring-ToFront $Element }

    $patternObj = $null
    $ok = $Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObj)
    if ($ok -and $null -ne $patternObj) {
        $patternObj.Invoke()
        return
    }

    $rect = $Element.Current.BoundingRectangle
    Invoke-ScreenClick -X (Safe-Int ($rect.Left + ($rect.Width / 2))) -Y (Safe-Int ($rect.Top + ($rect.Height / 2))) -FocusWindow $FocusWindow
}

function Invoke-ScreenClick {
    param(
        [int]$X,
        [int]$Y,
        [System.Windows.Automation.AutomationElement]$FocusWindow = $null,
        [switch]$DoubleClick
    )
    if ($null -ne $FocusWindow) { Bring-ToFront $FocusWindow }
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($X, $Y)
    Start-Sleep -Milliseconds 120
    [NativeWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NativeWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    if ($DoubleClick) {
        Start-Sleep -Milliseconds 80
        [NativeWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        [NativeWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }
}

function Wait-DetailSurface {
    param(
        [hashtable]$BeforeHandles,
        [hashtable]$BeforePaneMap,
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [int]$MainProcessId,
        [int]$MainHandle,
        [string]$TitleRegex,
        [int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        foreach ($win in Get-RootWindows) {
            $handle = [int]$win.Current.NativeWindowHandle
            $title = $win.Current.Name
            $rect = $win.Current.BoundingRectangle
            $isSameProcessDialog = (
                $handle -ne 0 `
                -and $handle -ne $MainHandle `
                -and $win.Current.ProcessId -eq $MainProcessId `
                -and -not $win.Current.IsOffscreen `
                -and $rect.Width -ge 480 `
                -and $rect.Height -ge 240
            )
            $isNewLikelyDialog = (
                $handle -ne 0 `
                -and -not $BeforeHandles.ContainsKey($handle) `
                -and -not $win.Current.IsOffscreen `
                -and $rect.Width -ge 500 `
                -and $rect.Width -le 1200 `
                -and $rect.Height -ge 300 `
                -and $rect.Height -le 900
            )
            if (($title -match $TitleRegex) -or $isNewLikelyDialog -or $isSameProcessDialog) {
                return $win
            }
        }

        if ($null -ne $MainWindow) {
            $pane = Find-NewDetailPane -BeforePaneMap $BeforePaneMap -MainWindow $MainWindow
            if ($null -ne $pane) { return $pane }
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Capture-WindowPng {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Path
    )
    Bring-ToFront $Window
    $rect = $Window.Current.BoundingRectangle
    if ($rect.Width -lt 20 -or $rect.Height -lt 20) {
        throw "Window rectangle is too small: $rect"
    }

    $left = [int][Math]::Max(0, [Math]::Floor($rect.Left))
    $top = [int][Math]::Max(0, [Math]::Floor($rect.Top))
    $width = [int][Math]::Ceiling($rect.Width)
    $height = [int][Math]::Ceiling($rect.Height)

    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($width, $height)))
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Close-WindowWithAltF4 {
    param([System.Windows.Automation.AutomationElement]$Window)
    if ($KeepDetailWindowOpen) { return }
    Bring-ToFront $Window
    [System.Windows.Forms.SendKeys]::SendWait('%{F4}')
    Start-Sleep -Milliseconds 400
}

function Get-Utf8Encoding {
    return New-Object System.Text.UTF8Encoding($true)
}

function Read-LinesUtf8 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $text = $utf8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        try {
            $text = $utf8Strict.GetString($bytes)
        }
        catch {
            $text = [System.Text.Encoding]::Default.GetString($bytes)
            Write-Step ("Warning: {0} is not valid UTF-8; read with system default encoding." -f $Path)
        }
    }
    return @($text -split "`r?`n")
}

function Append-LogRow {
    param([pscustomobject]$Row)
    $enc = Get-Utf8Encoding
    $exists = Test-Path $LogPath
    if ($exists) {
        $line = (($Row | ConvertTo-Csv -NoTypeInformation)[1])
        [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $enc)
    }
    else {
        $header = (($Row | ConvertTo-Csv -NoTypeInformation)[0])
        $line = (($Row | ConvertTo-Csv -NoTypeInformation)[1])
        [System.IO.File]::WriteAllText($LogPath, $header + [Environment]::NewLine + $line + [Environment]::NewLine, $enc)
    }
}

function Get-SuccessSignatures {
    $set = @{}
    if (-not $Resume -or -not (Test-Path $LogPath)) { return $set }
    foreach ($row in Import-Csv $LogPath) {
        if ($row.Status -eq 'success' -and -not [string]::IsNullOrWhiteSpace($row.Signature)) {
            $set[$row.Signature] = $true
        }
    }
    return $set
}

function Get-ElementSignature {
    param(
        [int]$Index,
        [string]$RowText,
        [System.Windows.Automation.AutomationElement]$Button
    )
    if (-not [string]::IsNullOrWhiteSpace($RowText)) { return $RowText }
    $rid = ($Button.GetRuntimeId() -join '.')
    return "runtime:$rid:index:$Index"
}

function Try-ScrollMainList {
    param([System.Windows.Automation.AutomationElement]$MainWindow)
    $scrollPattern = $null
    $ok = $MainWindow.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollPattern)
    if ($ok -and $null -ne $scrollPattern -and $scrollPattern.Current.VerticallyScrollable) {
        $scrollPattern.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, [System.Windows.Automation.ScrollAmount]::LargeIncrement)
        Start-Sleep -Milliseconds 700
        return $true
    }

    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsScrollPatternAvailableProperty,
        $true
    )
    foreach ($element in $MainWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        $scrollPattern = $null
        $ok = $element.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollPattern)
        if ($ok -and $null -ne $scrollPattern -and $scrollPattern.Current.VerticallyScrollable) {
            $scrollPattern.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, [System.Windows.Automation.ScrollAmount]::LargeIncrement)
            Start-Sleep -Milliseconds 700
            return $true
        }
    }
    return $false
}

function Find-TablePaneRect {
    param([System.Windows.Automation.AutomationElement]$MainWindow)

    $mainRect = $MainWindow.Current.BoundingRectangle
    $fallbackTop = $mainRect.Top + [Math]::Round($mainRect.Height * 0.55)
    $fallbackHeight = [Math]::Round($mainRect.Height * 0.36)
    $fallbackRect = New-Object System.Windows.Rect($mainRect.Left, $fallbackTop, $mainRect.Width, $fallbackHeight)

    if (-not $UsePaneDetection) {
        return $fallbackRect
    }

    $paneCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Pane
    )
    $candidates = @()
    foreach ($pane in $MainWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, $paneCond)) {
        $rect = $pane.Current.BoundingRectangle
        if (-not $pane.Current.IsOffscreen `
            -and $rect.Width -gt ($mainRect.Width * 0.5) `
            -and $rect.Height -gt 80 `
            -and $rect.Height -lt 420 `
            -and $rect.Top -gt ($mainRect.Top + 250)) {
            $candidates += [pscustomobject]@{
                Rect = $rect
                Area = ($rect.Width * $rect.Height)
                Top = $rect.Top
            }
        }
    }

    $tableRect = $null
    if ($candidates.Count -gt 0) {
        $tableRect = ($candidates | Sort-Object Area -Descending | Select-Object -First 1).Rect
    }
    else {
        $tableRect = $fallbackRect
    }

    $visible = Get-RectIntersection -A $tableRect -B $mainRect
    if ($null -ne $visible) { return $visible }
    return $tableRect
}

function Get-TableHeaderHeight {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [System.Windows.Rect]$TableRect,
        [int]$ConfiguredHeight
    )
    if ($ConfiguredHeight -gt 0) { return $ConfiguredHeight }
    if (-not $UsePaneDetection) { return 31 }

    $paneCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Pane
    )
    foreach ($pane in $MainWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, $paneCond)) {
        $rect = $pane.Current.BoundingRectangle
        if ($pane.Current.IsOffscreen) { continue }
        if ($rect.Height -lt 12 -or $rect.Height -gt 40) { continue }
        if ($rect.Width -lt ($TableRect.Width * 0.7)) { continue }
        if ([Math]::Abs($rect.Top - $TableRect.Top) -gt 6) { continue }
        return [Math]::Max(12, [int][Math]::Round($rect.Height))
    }
    return 31
}

function Invoke-TablePageDown {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [System.Windows.Rect]$TableRect
    )
    $x = Safe-Int ($TableRect.Left + ($TableRect.Width / 2))
    $y = Safe-Int ($TableRect.Top + ($TableRect.Height / 2))
    Invoke-ScreenClick -X $x -Y $y -FocusWindow $MainWindow
    [System.Windows.Forms.SendKeys]::SendWait('{PGDN}')
    Start-Sleep -Milliseconds 800
}

function Find-SearchEditRect {
    param([System.Windows.Automation.AutomationElement]$MainWindow)

    $mainRect = $MainWindow.Current.BoundingRectangle
    # The WinForms search edit is not reliably exposed through UIA. Use ratios
    # so the click scales with the application window size and never blocks.
    return New-Object System.Windows.Rect -ArgumentList `
        ($mainRect.Left + ($mainRect.Width * $SearchBoxXRatio) - 45), `
        ($mainRect.Top + ($mainRect.Height * $SearchBoxYRatio) - 11), `
        90, `
        22
}

function Invoke-SearchByName {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'SearchName is required for -Mode Search.'
    }

    Bring-ToFront $MainWindow
    $editRect = Find-SearchEditRect $MainWindow
    $x = Safe-Int ($editRect.Left + ($editRect.Width / 2))
    $y = Safe-Int ($editRect.Top + ($editRect.Height / 2))

    Write-Step ("Search input at {0},{1}; name='{2}'" -f $x, $y, $Name)
    Invoke-ScreenClick -X $x -Y $y -FocusWindow $MainWindow
    Start-Sleep -Milliseconds 120
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 80
    Set-Clipboard -Value $Name
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 120
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 1000
}

function Capture-DetailsByCoordinates {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [int]$EffectiveLimit
    )

    Write-Step 'Using coordinate fallback because detail buttons are not exposed through UI Automation.'

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }

    $successSignatures = Get-SuccessSignatures
    $processed = 0
    $globalIndex = [Math]::Max(1, $StartIndex)
    $consecutiveFailures = 0

    $mainProcessId = $MainWindow.Current.ProcessId
    $mainHandle = [int]$MainWindow.Current.NativeWindowHandle
    $visitedPageHashes = @{}

    for ($scroll = 0; $scroll -le $MaxScrolls; $scroll++) {
        Bring-ToFront $MainWindow
        $mainRect = $MainWindow.Current.BoundingRectangle
        $tableRect = Find-TablePaneRect $MainWindow
        $pageHash = Get-ScreenRectHash $tableRect
        if ($visitedPageHashes.ContainsKey($pageHash)) {
            Write-Step 'Stopped because the table page did not change after scrolling.'
            return
        }
        $visitedPageHashes[$pageHash] = $true
        $headerHeight = Get-TableHeaderHeight -MainWindow $MainWindow -TableRect $tableRect -ConfiguredHeight $TableHeaderHeight
        $firstPoint = Get-DetailClickPoint -TableRect $tableRect -MainRect $mainRect -RowOnPage 0 -HeaderHeight $headerHeight -RowHeight $TableRowHeight -XRatio $DetailButtonXRatio -RightInset $DetailButtonRightInset
        $firstY = $firstPoint.Y
        $clickX = $firstPoint.X
        $lastY = Safe-Int ($firstPoint.VisibleTable.Top + $firstPoint.VisibleTable.Height - 8)
        $rowsOnPage = [Math]::Max(1, [Math]::Floor(($lastY - $firstY) / $TableRowHeight) + 1)

        Write-Step ("Coordinate page {0}: table={1},{2},{3},{4}; header={5}; rows={6}; clickX={7}" -f ($scroll + 1), (Safe-Int $tableRect.Left), (Safe-Int $tableRect.Top), (Safe-Int $tableRect.Width), (Safe-Int $tableRect.Height), $headerHeight, $rowsOnPage, $clickX)

        $shouldTryNextPage = $false
        for ($rowOnPage = 0; $rowOnPage -lt $rowsOnPage; $rowOnPage++) {
            if ($EffectiveLimit -gt 0 -and $processed -ge $EffectiveLimit) { return }
            if ($consecutiveFailures -ge $StopAfterConsecutiveFailures) {
                Write-Step ("Reached {0} consecutive failures on this page; trying next page before stopping." -f $consecutiveFailures)
                $shouldTryNextPage = $true
                break
            }

            $point = Get-DetailClickPoint -TableRect $tableRect -MainRect $mainRect -RowOnPage $rowOnPage -HeaderHeight $headerHeight -RowHeight $TableRowHeight -XRatio $DetailButtonXRatio -RightInset $DetailButtonRightInset
            $clickX = $point.X
            $clickY = $point.Y
            $signature = "coord:scroll=${scroll}:row=${rowOnPage}:x=${clickX}:y=${clickY}"
            if ($successSignatures.ContainsKey($signature)) {
                Append-LogRow ([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('s')
                    RowIndex = $globalIndex
                    Status = 'skipped'
                    FileName = ''
                    DetailTitle = ''
                    Name = ''
                    License = ''
                    Signature = $signature
                    Message = 'already captured in previous log'
                    RowText = ''
                })
                $globalIndex++
                continue
            }

            $fileName = $null
            try {
                Write-Step ("Opening detail by coordinate for item #{0} at {1},{2}" -f $globalIndex, $clickX, $clickY)
                $before = Get-WindowHandles
                $beforePanes = Get-LargePaneMap -Root $MainWindow
                Invoke-ScreenClick -X $clickX -Y $clickY -FocusWindow $MainWindow
                $detail = Wait-DetailSurface -BeforeHandles $before -BeforePaneMap $beforePanes -MainWindow $MainWindow -MainProcessId $mainProcessId -MainHandle $mainHandle -TitleRegex $DetailWindowTitleRegex -TimeoutSeconds $WaitSeconds
                if ($null -eq $detail) {
                    Invoke-ScreenClick -X $clickX -Y $clickY -FocusWindow $MainWindow -DoubleClick
                    $detail = Wait-DetailSurface -BeforeHandles $before -BeforePaneMap $beforePanes -MainWindow $MainWindow -MainProcessId $mainProcessId -MainHandle $mainHandle -TitleRegex $DetailWindowTitleRegex -TimeoutSeconds 3
                }
                if ($null -eq $detail) { throw 'Detail window not found after coordinate click.' }

                $detailText = Get-ElementTextSummary $detail
                $identity = Get-DetailIdentity $detailText
                if ([string]::IsNullOrWhiteSpace($identity.Name) -and -not [string]::IsNullOrWhiteSpace($SearchName)) {
                    $identity.Name = $SearchName
                }
                $safeName = Sanitize-FileName $identity.Name
                $safeLicense = Sanitize-FileName $identity.License
                $fileName = ("{0:D4}_{1}_{2}.png" -f $globalIndex, $safeName, $safeLicense)
                $path = Join-Path $OutputDir $fileName

                Capture-WindowPng -Window $detail -Path $path
                Append-LogRow ([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('s')
                    RowIndex = $globalIndex
                    Status = 'success'
                    FileName = $fileName
                    DetailTitle = $detail.Current.Name
                    Name = $identity.Name
                    License = $identity.License
                    Signature = $signature
                    Message = 'captured by coordinate fallback'
                    RowText = ''
                })
                Write-Step ("Saved: {0}" -f $path)
                $processed++
                $consecutiveFailures = 0
                Close-WindowWithAltF4 $detail
            }
            catch {
                $consecutiveFailures++
                Append-LogRow ([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('s')
                    RowIndex = $globalIndex
                    Status = 'failed'
                    FileName = $fileName
                    DetailTitle = ''
                    Name = ''
                    License = ''
                    Signature = $signature
                    Message = $_.Exception.Message
                    RowText = ''
                })
                Write-Step ("Failed coordinate item #{0}: {1}" -f $globalIndex, $_.Exception.Message)
            }
            finally {
                $globalIndex++
                Bring-ToFront $MainWindow
            }
        }

        if ($NoScroll) { break }
        if ($EffectiveLimit -gt 0 -and $processed -ge $EffectiveLimit) { return }
        Invoke-TablePageDown -MainWindow $MainWindow -TableRect $tableRect
        if ($shouldTryNextPage) {
            $consecutiveFailures = 0
        }
    }
}

function Probe-Environment {
    Write-Step 'Top-level windows:'
    foreach ($win in Get-RootWindows) {
        $rect = $win.Current.BoundingRectangle
        $title = $win.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            Write-Host ("- Handle={0} Title={1} Rect={2},{3},{4},{5}" -f $win.Current.NativeWindowHandle, $title, (Safe-Int $rect.Left), (Safe-Int $rect.Top), (Safe-Int $rect.Width), (Safe-Int $rect.Height))
        }
    }

    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        Write-MainWindowNotFoundHelp $MainWindowTitleRegex
        return
    }

    Write-Step ("Main window found: {0}" -f $main.Current.Name)
    if (-not (Test-IsAdministrator)) {
        Write-Step 'PowerShell is not elevated. If clicks fail, re-run with -Elevate.'
    }
    Bring-ToFront $main
    $searchRect = Find-SearchEditRect $main
    Write-Step ("Search box candidate: {0},{1},{2},{3}" -f (Safe-Int $searchRect.Left), (Safe-Int $searchRect.Top), (Safe-Int $searchRect.Width), (Safe-Int $searchRect.Height))
    $buttons = @()
    if ($UseAutomationButtons) {
        $buttons = @(Get-InvokeButtons -Root $main -NameRegex $ViewDetailButtonRegex)
    }
    Write-Step ("Visible detail buttons: {0}" -f $buttons.Count)
    if ($buttons.Count -eq 0) {
        $mainRect = $main.Current.BoundingRectangle
        $tableRect = Find-TablePaneRect $main
        $headerHeight = Get-TableHeaderHeight -MainWindow $main -TableRect $tableRect -ConfiguredHeight $TableHeaderHeight
        $point = Get-DetailClickPoint -TableRect $tableRect -MainRect $mainRect -RowOnPage 0 -HeaderHeight $headerHeight -RowHeight $TableRowHeight -XRatio $DetailButtonXRatio -RightInset $DetailButtonRightInset
        Write-Step ("Coordinate fallback ready: table={0},{1},{2},{3}; header={4}; firstClick={5},{6}; rowHeight={7}" -f (Safe-Int $tableRect.Left), (Safe-Int $tableRect.Top), (Safe-Int $tableRect.Width), (Safe-Int $tableRect.Height), $headerHeight, $point.X, $point.Y, $TableRowHeight)
    }
    $i = 0
    foreach ($button in $buttons | Select-Object -First 10) {
        $i++
        $row = Get-RowLikeAncestor $button
        $text = Get-ElementTextSummary $row
        $rect = $button.Current.BoundingRectangle
        Write-Host ("  {0}. Button='{1}' Rect={2},{3},{4},{5} RowText='{6}'" -f $i, $button.Current.Name, (Safe-Int $rect.Left), (Safe-Int $rect.Top), (Safe-Int $rect.Width), (Safe-Int $rect.Height), $text)
    }

    $detail = Get-WindowByTitle $DetailWindowTitleRegex
    if ($null -ne $detail) {
        $rect = $detail.Current.BoundingRectangle
        Write-Step ("Detail window currently visible: {0}; Rect={1},{2},{3},{4}" -f $detail.Current.Name, (Safe-Int $rect.Left), (Safe-Int $rect.Top), (Safe-Int $rect.Width), (Safe-Int $rect.Height))
    }
}

function Capture-Details {
    param([int]$EffectiveLimit)

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }

    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        Write-MainWindowNotFoundHelp $MainWindowTitleRegex
        throw 'Main window not found. See messages above.'
    }
    Bring-ToFront $main

    $successSignatures = Get-SuccessSignatures
    $processed = 0
    $visitedThisRun = @{}
    $globalIndex = [Math]::Max(1, $StartIndex)
    $mainProcessId = $main.Current.ProcessId
    $mainHandle = [int]$main.Current.NativeWindowHandle

    if (-not $UseAutomationButtons) {
        Capture-DetailsByCoordinates -MainWindow $main -EffectiveLimit $EffectiveLimit
        return
    }

    for ($scroll = 0; $scroll -le $MaxScrolls; $scroll++) {
        $buttons = @(Get-InvokeButtons -Root $main -NameRegex $ViewDetailButtonRegex)
        if ($buttons.Count -eq 0) {
            Capture-DetailsByCoordinates -MainWindow $main -EffectiveLimit $EffectiveLimit
            return
        }

        $newOnPage = 0
        foreach ($button in $buttons) {
            if ($EffectiveLimit -gt 0 -and $processed -ge $EffectiveLimit) { return }

            $row = Get-RowLikeAncestor $button
            $rowText = Get-ElementTextSummary $row
            $signature = Get-ElementSignature -Index $globalIndex -RowText $rowText -Button $button
            if ($visitedThisRun.ContainsKey($signature)) { continue }
            $visitedThisRun[$signature] = $true
            $newOnPage++

            if ($successSignatures.ContainsKey($signature)) {
                Append-LogRow ([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('s')
                    RowIndex = $globalIndex
                    Status = 'skipped'
                    FileName = ''
                    DetailTitle = ''
                    Name = ''
                    License = ''
                    Signature = $signature
                    Message = 'already captured in previous log'
                    RowText = $rowText
                })
                $globalIndex++
                continue
            }

            $before = Get-WindowHandles
            $beforePanes = Get-LargePaneMap -Root $main
            $fileName = $null
            try {
                Write-Step ("Opening detail for item #{0}" -f $globalIndex)
                Invoke-ElementAction -Element $button -FocusWindow $main
                $detail = Wait-DetailSurface -BeforeHandles $before -BeforePaneMap $beforePanes -MainWindow $main -MainProcessId $mainProcessId -MainHandle $mainHandle -TitleRegex $DetailWindowTitleRegex -TimeoutSeconds $WaitSeconds
                if ($null -eq $detail) { throw "Detail window not found after clicking." }

                $detailText = Get-ElementTextSummary $detail
                $identity = Get-DetailIdentity $detailText
                if ([string]::IsNullOrWhiteSpace($identity.Name) -and -not [string]::IsNullOrWhiteSpace($SearchName)) {
                    $identity.Name = $SearchName
                }
                $safeName = Sanitize-FileName $identity.Name
                $safeLicense = Sanitize-FileName $identity.License
                $fileName = ("{0:D4}_{1}_{2}.png" -f $globalIndex, $safeName, $safeLicense)
                $path = Join-Path $OutputDir $fileName

                Capture-WindowPng -Window $detail -Path $path
                Append-LogRow ([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('s')
                    RowIndex = $globalIndex
                    Status = 'success'
                    FileName = $fileName
                    DetailTitle = $detail.Current.Name
                    Name = $identity.Name
                    License = $identity.License
                    Signature = $signature
                    Message = 'captured'
                    RowText = $rowText
                })
                Write-Step ("Saved: {0}" -f $path)
                $processed++
                Close-WindowWithAltF4 $detail
            }
            catch {
                Append-LogRow ([pscustomobject]@{
                    Timestamp = (Get-Date).ToString('s')
                    RowIndex = $globalIndex
                    Status = 'failed'
                    FileName = $fileName
                    DetailTitle = ''
                    Name = ''
                    License = ''
                    Signature = $signature
                    Message = $_.Exception.Message
                    RowText = $rowText
                })
                Write-Step ("Failed item #{0}: {1}" -f $globalIndex, $_.Exception.Message)
            }
            finally {
                $globalIndex++
                Bring-ToFront $main
            }
        }

        if ($NoScroll) { break }
        if ($EffectiveLimit -gt 0 -and $processed -ge $EffectiveLimit) { return }
        if ($newOnPage -eq 0) { break }
        if (-not (Try-ScrollMainList $main)) {
            Write-Step 'No scrollable list found; finished visible rows.'
            break
        }
    }
}

function Capture-SearchDetails {
    if ([string]::IsNullOrWhiteSpace($SearchName)) {
        throw 'Use -SearchName "姓名" with -Mode Search.'
    }

    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        Write-MainWindowNotFoundHelp $MainWindowTitleRegex
        throw 'Main window not found. See messages above.'
    }

    Invoke-SearchByName -MainWindow $main -Name $SearchName

    $effective = $Limit
    if (-not $SearchAllMatches -and $effective -le 0) {
        $effective = 1
    }

    Write-Step ("Capturing search result(s) for '{0}'. Limit={1}" -f $SearchName, $effective)
    Capture-Details -EffectiveLimit $effective
    Review-Output
}

function Review-Output {
    if (-not (Test-Path $OutputDir)) {
        Write-Step "OutputDir not found: $OutputDir"
        return
    }
    $files = @(Get-ChildItem -Path $OutputDir -Filter '*.png' -File -ErrorAction SilentlyContinue)
    Write-Step ("PNG files: {0}" -f $files.Count)
    if (Test-Path $LogPath) {
        $rows = @(Import-Csv $LogPath)
        $success = @($rows | Where-Object { $_.Status -eq 'success' }).Count
        $failed = @($rows | Where-Object { $_.Status -eq 'failed' }).Count
        $skipped = @($rows | Where-Object { $_.Status -eq 'skipped' }).Count
        Write-Step ("Log summary: success={0}, failed={1}, skipped={2}, total={3}" -f $success, $failed, $skipped, $rows.Count)
    }
    $bad = @($files | Where-Object { $_.Length -lt 10240 })
    if ($bad.Count -gt 0) {
        Write-Step ("Potentially incomplete screenshots under 10KB: {0}" -f $bad.Count)
        $bad | Select-Object -First 10 FullName, Length | Format-Table -AutoSize
    }
    $files | Sort-Object LastWriteTime -Descending | Select-Object -First 10 FullName, Length, LastWriteTime | Format-Table -AutoSize
}

#region 姓名系列截图（坐标校准 + 标题信号确认 + OCR 命名）

$script:WinRtAsTaskGeneric = $null
$script:OcrEngine = $null
$script:OcrReady = $false

function Invoke-WinRtAwait {
    param($Operation, [Type]$ResultType)
    if ($null -eq $script:WinRtAsTaskGeneric) {
        $script:WinRtAsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    }
    $asTask = $script:WinRtAsTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($Operation))
    $netTask.Wait(-1) | Out-Null
    return $netTask.Result
}

function Initialize-Ocr {
    if ($script:OcrReady) { return ($null -ne $script:OcrEngine) }
    $script:OcrReady = $true
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
        [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
        [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
        $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $script:OcrEngine) {
            $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language('zh-Hans')))
        }
    }
    catch {
        Write-Step ("OCR init failed: {0}" -f $_.Exception.Message)
        $script:OcrEngine = $null
    }
    if ($null -eq $script:OcrEngine) {
        Write-Step 'OCR engine unavailable; will name files by sequence instead of certificate code.'
        return $false
    }
    return $true
}

function Get-OcrTextFromBitmap {
    param([System.Drawing.Bitmap]$Bitmap)
    if (-not (Initialize-Ocr)) { return $null }
    $ms = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()

        $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
        $writer = New-Object Windows.Storage.Streams.DataWriter($stream)
        $writer.WriteBytes($bytes)
        Invoke-WinRtAwait ($writer.StoreAsync()) ([uint32]) | Out-Null
        $writer.DetachStream() | Out-Null
        $stream.Seek(0)

        $decoder = Invoke-WinRtAwait ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $softwareBitmap = Invoke-WinRtAwait ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Invoke-WinRtAwait ($script:OcrEngine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
        return $result.Text
    }
    catch {
        Write-Step ("OCR recognize failed: {0}" -f $_.Exception.Message)
        return $null
    }
    finally {
        $ms.Dispose()
    }
}

function Get-DetailFieldsFromOcrText {
    param([string]$Text)
    $name = $null
    $code = $null
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ Name = $null; CertCode = $null }
    }

    $compact = ($Text -replace '\s+', '')
    if ($compact -match '姓名[:：]?([\u4e00-\u9fa5·]{2,8})') {
        $name = $Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($name) -and ($Text -match '姓名\s*[:：]?\s*([\u4e00-\u9fa5]{2,4})')) {
        $name = $Matches[1]
    }

    $digits = [regex]::Matches($Text, '\d+') | ForEach-Object { $_.Value }
    if ($digits.Count -gt 0) {
        $code = $digits | Where-Object { $_.Length -ge 20 } | Sort-Object Length -Descending | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($code)) {
            $code = $digits | Sort-Object Length -Descending | Select-Object -First 1
        }
    }
    return @{ Name = $name; CertCode = $code }
}

function Get-CertCodeFromBitmap {
    param([System.Drawing.Bitmap]$Bitmap)
    $text = Get-OcrTextFromBitmap -Bitmap $Bitmap
    return (Get-DetailFieldsFromOcrText -Text $text).CertCode
}

function Get-BitmapHash {
    param([System.Drawing.Bitmap]$Bitmap)
    $ms = New-Object System.IO.MemoryStream
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $hash = $sha.ComputeHash($ms.ToArray())
        return ([BitConverter]::ToString($hash) -replace '-', '')
    }
    finally {
        $sha.Dispose()
        $ms.Dispose()
    }
}

function Capture-WindowBitmap {
    param([System.Windows.Automation.AutomationElement]$Window)
    Bring-ToFront $Window
    $rect = $Window.Current.BoundingRectangle
    if ($rect.Width -lt 20 -or $rect.Height -lt 20) {
        throw "Window rectangle is too small: $rect"
    }
    $left = [int][Math]::Max(0, [Math]::Floor($rect.Left))
    $top = [int][Math]::Max(0, [Math]::Floor($rect.Top))
    $width = [int][Math]::Ceiling($rect.Width)
    $height = [int][Math]::Ceiling($rect.Height)

    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($width, $height)))
    }
    finally {
        $graphics.Dispose()
    }
    return $bitmap
}

function Invoke-ScreenDoubleClick {
    param(
        [int]$X,
        [int]$Y,
        [System.Windows.Automation.AutomationElement]$FocusWindow = $null
    )
    if ($null -ne $FocusWindow) { Bring-ToFront $FocusWindow }
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($X, $Y)
    Start-Sleep -Milliseconds 120
    [NativeWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NativeWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [NativeWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NativeWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Wait-DetailWindowByTitle {
    param(
        [hashtable]$BeforeHandles,
        [int]$MainHandle,
        [string]$TitleRegex,
        [int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        foreach ($win in Get-RootWindows) {
            $handle = [int]$win.Current.NativeWindowHandle
            if ($handle -eq 0 -or $handle -eq $MainHandle) { continue }
            if ($win.Current.IsOffscreen) { continue }
            $title = $win.Current.Name
            $rect = $win.Current.BoundingRectangle
            if ($rect.Width -lt 400 -or $rect.Height -lt 250) { continue }

            $titleMatch = ($title -match $TitleRegex)
            $isNew = (-not $BeforeHandles.ContainsKey($handle))
            if ($titleMatch -or $isNew) { return $win }
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-Calibration {
    if (-not (Test-Path $CalibrationPath)) { return $null }
    try {
        $cfgJson = [System.IO.File]::ReadAllText($CalibrationPath, (Get-Utf8Encoding))
        $cfg = $cfgJson | ConvertFrom-Json
    }
    catch { return $null }
    $props = @($cfg.PSObject.Properties.Name)
    foreach ($field in @('SearchBoxX','SearchBoxY','NameX','FirstRowY','RowHeight')) {
        if ($props -notcontains $field) { return $null }
    }
    return $cfg
}

function Read-CursorPointAfterCountdown {
    param([string]$Prompt, [int]$Seconds)
    Write-Host ''
    Write-Step $Prompt
    for ($i = $Seconds; $i -ge 1; $i--) {
        Write-Host ("  {0}..." -f $i)
        Start-Sleep -Seconds 1
    }
    $p = [System.Windows.Forms.Cursor]::Position
    Write-Step ("  recorded: {0},{1}" -f $p.X, $p.Y)
    return $p
}

function Invoke-Calibration {
    Write-Step '坐标校准开始。请保证医师系统已打开，且【先随便搜一个名字让列表出现至少两行】。'
    Write-Step '过程中只需移动鼠标到指定位置，不要点击；每一步会倒计时后自动记录鼠标所在坐标。'

    $search = Read-CursorPointAfterCountdown -Prompt '第1步：把鼠标移到【医师姓名 输入框】上。' -Seconds $CalibrateCountdown
    $row1 = Read-CursorPointAfterCountdown -Prompt '第2步：把鼠标移到【列表第 1 行 姓名 单元格】上。' -Seconds $CalibrateCountdown
    $row2 = Read-CursorPointAfterCountdown -Prompt '第3步：把鼠标移到【列表第 2 行 姓名 单元格】上。' -Seconds $CalibrateCountdown

    $rowHeight = [Math]::Abs($row2.Y - $row1.Y)
    if ($rowHeight -lt 8) {
        Write-Step ("警告：两行间距太小（{0}px），将使用默认行高 {1}。请确认第1、2行选对了。" -f $rowHeight, $TableRowHeight)
        $rowHeight = $TableRowHeight
    }

    $cfg = [pscustomobject]@{
        SearchBoxX = [int]$search.X
        SearchBoxY = [int]$search.Y
        NameX      = [int]$row1.X
        FirstRowY  = [int]$row1.Y
        RowHeight  = [int]$rowHeight
        SavedAt    = (Get-Date).ToString('s')
    }
    [System.IO.File]::WriteAllText($CalibrationPath, ($cfg | ConvertTo-Json), (Get-Utf8Encoding))
    Write-Step ("校准已保存到 {0}" -f $CalibrationPath)
    Write-Step ("搜索框=({0},{1}) 姓名列X={2} 首行Y={3} 行高={4}" -f $cfg.SearchBoxX, $cfg.SearchBoxY, $cfg.NameX, $cfg.FirstRowY, $cfg.RowHeight)
    Write-Step '现在可以运行： .\\run-search.cmd  或  -Mode SearchNames -Names ...'
}

function Invoke-NameSearchInput {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        $Calibration,
        [string]$Name
    )
    Bring-ToFront $MainWindow
    Invoke-ScreenClick -X ([int]$Calibration.SearchBoxX) -Y ([int]$Calibration.SearchBoxY) -FocusWindow $MainWindow
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
    Start-Sleep -Milliseconds 60
    Set-Clipboard -Value $Name
    Start-Sleep -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
}

function Resolve-NameList {
    $list = New-Object System.Collections.Generic.List[string]
    if ($Names -and $Names.Count -gt 0) {
        foreach ($n in $Names) {
            foreach ($part in ($n -split '[,，;；\s]+')) {
                $t = $part.Trim()
                if ($t.Length -gt 0) { $list.Add($t) }
            }
        }
    }

    $filePath = $NamesFile
    if ([string]::IsNullOrWhiteSpace($filePath)) {
        $defaultFile = Join-Path $PSScriptRoot 'name.txt'
        if (Test-Path $defaultFile) { $filePath = $defaultFile }
    }
    if (-not [string]::IsNullOrWhiteSpace($filePath)) {
        foreach ($line in (Read-LinesUtf8 -Path $filePath)) {
            $t = $line.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t.StartsWith('#')) { continue }
            foreach ($part in ($t -split '[,，;；\s]+')) {
                $p = $part.Trim()
                if ($p.Length -gt 0) { $list.Add($p) }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SearchName)) { $list.Add($SearchName.Trim()) }
    return ($list | Select-Object -Unique)
}

function Get-UniqueOutputPath {
    param([string]$BaseName)
    $path = Join-Path $OutputDir ($BaseName + '.png')
    if (-not (Test-Path $path)) { return $path }
    for ($i = 2; $i -lt 1000; $i++) {
        $path = Join-Path $OutputDir ("{0}_{1}.png" -f $BaseName, $i)
        if (-not (Test-Path $path)) { return $path }
    }
    return (Join-Path $OutputDir ("{0}_{1}.png" -f $BaseName, ([Guid]::NewGuid().ToString('N').Substring(0,6))))
}

function Capture-NameSeries {
    $nameList = @(Resolve-NameList)
    if ($nameList.Count -eq 0) {
        throw '请用 -Names "张三,李四" 或 -NamesFile names.txt 或 -SearchName "张三" 指定姓名。'
    }

    $cfg = Get-Calibration
    if ($null -eq $cfg) {
        Write-Step ("未找到有效校准文件：{0}" -f $CalibrationPath)
        Write-Step '请先运行：.\\run-calibrate.cmd（或 -Mode Calibrate）完成一次坐标校准。'
        throw 'Calibration required.'
    }

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
    if (-not $NoOcr) { Initialize-Ocr | Out-Null }

    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        Write-MainWindowNotFoundHelp $MainWindowTitleRegex
        throw 'Main window not found. See messages above.'
    }
    $mainHandle = [int]$main.Current.NativeWindowHandle

    Write-Step ("共有 {0} 个姓名需要处理。OCR={1} 校准=({2},{3}) 姓名列X={4} 首行Y={5} 行高={6}" -f $nameList.Count, (-not $NoOcr), $cfg.SearchBoxX, $cfg.SearchBoxY, $cfg.NameX, $cfg.FirstRowY, $cfg.RowHeight)

    $totalSaved = 0
    foreach ($name in $nameList) {
        Write-Step ("=== 搜索姓名：{0} ===" -f $name)
        try {
            Invoke-NameSearchInput -MainWindow $main -Calibration $cfg -Name $name
        }
        catch {
            Write-Step ("输入姓名失败：{0}" -f $_.Exception.Message)
            continue
        }
        Start-Sleep -Seconds $SearchWaitSeconds

        $rowSavedForName = 0
        $seenSignatures = @{}
        for ($row = 0; $row -lt $MaxRowsPerName; $row++) {
            $x = [int]$cfg.NameX
            $y = [int]$cfg.FirstRowY + ($row * [int]$cfg.RowHeight)

            $before = Get-WindowHandles
            Invoke-ScreenDoubleClick -X $x -Y $y -FocusWindow $main
            $detail = Wait-DetailWindowByTitle -BeforeHandles $before -MainHandle $mainHandle -TitleRegex $DetailWindowTitleRegex -TimeoutSeconds $DetailWaitSeconds

            if ($null -eq $detail -and $row -eq 0) {
                Start-Sleep -Seconds 1
                $before = Get-WindowHandles
                Invoke-ScreenDoubleClick -X $x -Y $y -FocusWindow $main
                $detail = Wait-DetailWindowByTitle -BeforeHandles $before -MainHandle $mainHandle -TitleRegex $DetailWindowTitleRegex -TimeoutSeconds $DetailWaitSeconds
            }

            if ($null -eq $detail) {
                if ($row -eq 0) { Write-Step ("  未出现详情窗口，'{0}' 可能无结果。" -f $name) }
                else { Write-Step ("  第 {0} 行无更多结果，结束该姓名。" -f ($row + 1)) }
                break
            }

            $fileName = $null
            $filePersonName = $name
            $isDuplicate = $false
            try {
                $bitmap = Capture-WindowBitmap -Window $detail
                try {
                    $code = $null
                    $detailName = $null
                    if (-not $NoOcr) {
                        $ocrText = Get-OcrTextFromBitmap -Bitmap $bitmap
                        $fields = Get-DetailFieldsFromOcrText -Text $ocrText
                        $code = $fields.CertCode
                        $detailName = $fields.Name
                    }

                    # 去重键：有编码用编码，否则用截图哈希。重名(不同人)编码/截图不同，不会误判；
                    # 同一行被重复打开则键相同 -> 判定为重复并停止该姓名。
                    if (-not [string]::IsNullOrWhiteSpace($code)) {
                        $signature = "code:$code"
                    }
                    else {
                        $signature = "img:" + (Get-BitmapHash -Bitmap $bitmap)
                    }

                    if ($seenSignatures.ContainsKey($signature)) {
                        $isDuplicate = $true
                        Write-Step ("  第 {0} 行与已截取的记录重复（同一行被重复打开），停止该姓名。" -f ($row + 1))
                    }
                    else {
                        $seenSignatures[$signature] = $true
                        $filePersonName = if (-not [string]::IsNullOrWhiteSpace($detailName)) { $detailName } else { $name }
                        $safeName = Sanitize-FileName $filePersonName
                        if ([string]::IsNullOrWhiteSpace($code)) {
                            $baseName = ("{0}_row{1}" -f $safeName, ($row + 1))
                        }
                        else {
                            $baseName = ("{0}_{1}" -f $safeName, (Sanitize-FileName $code))
                        }
                        $path = Get-UniqueOutputPath -BaseName $baseName
                        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
                        $fileName = [IO.Path]::GetFileName($path)
                    }
                }
                finally {
                    $bitmap.Dispose()
                }

                if (-not $isDuplicate) {
                    Append-LogRow ([pscustomobject]@{
                        Timestamp   = (Get-Date).ToString('s')
                        RowIndex    = ($row + 1)
                        Status      = 'success'
                        FileName    = $fileName
                        DetailTitle = $detail.Current.Name
                        Name        = $filePersonName
                        License     = $code
                        Signature   = ("search:{0}:file:{1}:row:{2}" -f $name, $filePersonName, ($row + 1))
                        Message     = 'name-series capture'
                        RowText     = ''
                    })
                    Write-Step ("  已保存：{0}" -f $fileName)
                    $totalSaved++
                    $rowSavedForName++
                }
            }
            catch {
                Append-LogRow ([pscustomobject]@{
                    Timestamp   = (Get-Date).ToString('s')
                    RowIndex    = ($row + 1)
                    Status      = 'failed'
                    FileName    = $fileName
                    DetailTitle = ''
                    Name        = $name
                    License     = ''
                    Signature   = ("name:{0}:row:{1}" -f $name, ($row + 1))
                    Message     = $_.Exception.Message
                    RowText     = ''
                })
                Write-Step ("  第 {0} 行截图失败：{1}" -f ($row + 1), $_.Exception.Message)
            }
            finally {
                Close-WindowWithAltF4 $detail
                Start-Sleep -Milliseconds 250
                Bring-ToFront $main
                Start-Sleep -Milliseconds 150
            }

            if ($isDuplicate) { break }
        }

        Write-Step ("  '{0}' 完成，截图 {1} 张。" -f $name, $rowSavedForName)
    }

    Write-Step ("全部完成，共截图 {0} 张。" -f $totalSaved)
    Review-Output
}

#endregion

switch ($Mode) {
    'Probe' { Probe-Environment }
    'Calibrate' { Invoke-Calibration }
    'Prototype' {
        if ($Limit -le 0) { $Limit = 5 }
        Capture-Details -EffectiveLimit $Limit
        Review-Output
    }
    'Batch' { Capture-Details -EffectiveLimit $Limit; Review-Output }
    'Search' { Capture-NameSeries }
    'SearchNames' { Capture-NameSeries }
    'Review' { Review-Output }
}
