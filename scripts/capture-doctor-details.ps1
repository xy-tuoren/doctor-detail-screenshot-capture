param(
    [ValidateSet('Probe','Prototype','Batch','Search','SearchNames','Calibrate','LoginCalibrate','CalibrateAll','LoginToHome','OpenListAndSearchNames','LoginAndSearchNames','Review')]
    [string]$Mode = 'Probe',

    # 列表入口：Main=主执业机构在本院医师；Multi=外院在本院多执业医师
    [ValidateSet('Main','Multi')]
    [string]$ListEntry = 'Main',

    [string]$MainWindowTitleRegex = '8\.9\.4|医师电子化注册信息系统',
    [string]$DetailWindowTitleRegex = '信息展示|执业信息|详细信息',
    [string]$ViewDetailButtonRegex = '查看详',

    [string]$OutputDir = '',
    [string]$LogPath = '',
    [string]$CalibrationPath = '',
    [string]$LoginConfigPath = '',
    [string]$ConfigPath = '',
    [string]$StatePath = '',

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
    [int]$CalibrateCountdown = 5,
    [int]$CaptureRestInterval = 100,
    [int]$CaptureRestMinutes = 5,
    [switch]$NoOcr,

    # 接口异常弹窗自动恢复相关
    [string]$ErrorLogPath = '',
    [string]$ErrorPopupTextRegex = '非法访问用户身份|禁止\s*Web\s*服务调用|获取详细信息时发生错误|服务调用\(1\)',
    [string]$ErrorPopupTitleRegex = '提示|错误|异常|警告',
    [int]$MaxAutoRestarts = 100,
    [int]$RestartWaitSeconds = 5,
    [switch]$NoAutoRestart,

    # 登录自动化相关
    [string]$AppPath = '',
    [string]$LoginUser = '',
    [string]$LoginPassword = '',
    [string]$LoginWindowTitleRegex = '用户登录|医师电子化注册信息系统',
    [int]$LoginWaitSeconds = 90,
    [int]$PostLoginWaitSeconds = 8,

    [switch]$UseAutomationButtons,
    [switch]$UsePaneDetection,
    [switch]$Elevate,
    [switch]$ResetState,
    [switch]$DisableStateResume,
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

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LogsDir = Join-Path $ProjectRoot 'logs'
if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $ProjectRoot 'captures' }
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $LogsDir 'capture-log.csv' }
if ([string]::IsNullOrWhiteSpace($CalibrationPath)) { $CalibrationPath = Join-Path $ProjectRoot 'calibration.json' }
if ([string]::IsNullOrWhiteSpace($LoginConfigPath)) { $LoginConfigPath = Join-Path $ProjectRoot 'login-calibration.json' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ProjectRoot 'config.json' }
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $LogsDir 'capture-state.json' }
if ([string]::IsNullOrWhiteSpace($ErrorLogPath)) { $ErrorLogPath = Join-Path $LogsDir 'error-popup-log.csv' }

# 主执业 / 多执业截图分别保存到 captures 子目录（未显式指定 -OutputDir 时）
$defaultCapturesDir = Join-Path $ProjectRoot 'captures'
try {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputDir)
    $resolvedDefault = [System.IO.Path]::GetFullPath($defaultCapturesDir)
    if ($resolvedOutput -eq $resolvedDefault) {
        $subFolder = if ($ListEntry -eq 'Multi') { '多执业' } else { '主执业' }
        $OutputDir = Join-Path $defaultCapturesDir $subFolder
    }
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
        '-ListEntry', $ListEntry,
        '-MainWindowTitleRegex', (Quote-Arg $MainWindowTitleRegex),
        '-DetailWindowTitleRegex', (Quote-Arg $DetailWindowTitleRegex),
        '-ViewDetailButtonRegex', (Quote-Arg $ViewDetailButtonRegex),
        '-OutputDir', (Quote-Arg $OutputDir),
        '-LogPath', (Quote-Arg $LogPath),
        '-CalibrationPath', (Quote-Arg $CalibrationPath),
        '-LoginConfigPath', (Quote-Arg $LoginConfigPath),
        '-ConfigPath', (Quote-Arg $ConfigPath),
        '-StatePath', (Quote-Arg $StatePath),
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
        '-NamesFile', (Quote-Arg $NamesFile),
        '-AppPath', (Quote-Arg $AppPath),
        '-LoginUser', (Quote-Arg $LoginUser),
        '-LoginPassword', (Quote-Arg $LoginPassword),
        '-LoginWindowTitleRegex', (Quote-Arg $LoginWindowTitleRegex),
        '-LoginWaitSeconds', $LoginWaitSeconds,
        '-PostLoginWaitSeconds', $PostLoginWaitSeconds,
        '-CaptureRestInterval', $CaptureRestInterval,
        '-CaptureRestMinutes', $CaptureRestMinutes,
        '-ErrorLogPath', (Quote-Arg $ErrorLogPath),
        '-ErrorPopupTextRegex', (Quote-Arg $ErrorPopupTextRegex),
        '-ErrorPopupTitleRegex', (Quote-Arg $ErrorPopupTitleRegex),
        '-MaxAutoRestarts', $MaxAutoRestarts,
        '-RestartWaitSeconds', $RestartWaitSeconds
    )
    if ($Names -and $Names.Count -gt 0) {
        foreach ($n in $Names) { $argParts += '-Names'; $argParts += (Quote-Arg $n) }
    }
    if ($SearchAllMatches) { $argParts += '-SearchAllMatches' }
    if ($UseAutomationButtons) { $argParts += '-UseAutomationButtons' }
    if ($UsePaneDetection) { $argParts += '-UsePaneDetection' }
    if ($ResetState) { $argParts += '-ResetState' }
    if ($DisableStateResume) { $argParts += '-DisableStateResume' }
    if ($Resume) { $argParts += '-Resume' }
    if ($NoScroll) { $argParts += '-NoScroll' }
    if ($KeepDetailWindowOpen) { $argParts += '-KeepDetailWindowOpen' }
    if ($NoAutoRestart) { $argParts += '-NoAutoRestart' }
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
        Write-Step 'Close the admin window and run: .\run-capture.cmd'
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
    [NativeWin32]::ShowWindow($handle, 5) | Out-Null
    [NativeWin32]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, 0x0043) | Out-Null
    Start-Sleep -Milliseconds 80
    [NativeWin32]::SetWindowPos($handle, [IntPtr](-2), 0, 0, 0, 0, 0x0043) | Out-Null
    [NativeWin32]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 250
}

function Maximize-Window {
    param([System.Windows.Automation.AutomationElement]$Element)
    $handle = [IntPtr]([int]$Element.Current.NativeWindowHandle)
    [NativeWin32]::ShowWindow($handle, 3) | Out-Null
    [NativeWin32]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 500
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

function Write-CaptureState {
    param(
        [string]$Stage,
        [string]$CurrentName = '',
        [int]$CurrentRow = 0,
        [string]$CurrentIdCard = '',
        [string]$Message = ''
    )
    # 状态恢复已关闭：保留函数空实现，避免分散调用影响主流程。
    return
}

function Read-CaptureState {
    return $null
}

function Clear-CaptureState {
    if (Test-Path $StatePath) {
        Remove-Item -Path $StatePath -Force
    }
}

function Test-StateStageAtOrAfterList {
    param($State)
    if ($null -eq $State) { return $false }
    return @('ListReady','SearchName','OpenRow','CaptureDetail') -contains ([string]$State.Stage)
}

function Test-StateStageWithinName {
    param($State)
    if ($null -eq $State) { return $false }
    return @('SearchName','OpenRow','CaptureDetail') -contains ([string]$State.Stage)
}

$script:ConfigPersons = @()

function Get-AppConfig {
    if (-not (Test-Path $ConfigPath)) { return $null }
    try {
        $json = [System.IO.File]::ReadAllText($ConfigPath, (Get-Utf8Encoding))
        return ($json | ConvertFrom-Json)
    }
    catch {
        throw ("无法读取配置文件 {0}：{1}" -f $ConfigPath, $_.Exception.Message)
    }
}

function Get-ConfigProperty {
    param(
        $Config,
        [string[]]$Names
    )
    if ($null -eq $Config) { return $null }
    foreach ($name in $Names) {
        $prop = $Config.PSObject.Properties[$name]
        if ($null -ne $prop) { return $prop.Value }
    }
    return $null
}

function ConvertTo-PersonEntry {
    param($Item)
    if ($null -eq $Item) { return $null }

    if ($Item -is [string]) {
        $text = $Item.Trim()
        if ($text.Length -eq 0) { return $null }
        return [pscustomobject]@{ Name = $text; IdCard = '' }
    }

    $name = Get-ConfigProperty -Config $Item -Names @('name', 'Name')
    $idCard = Get-ConfigProperty -Config $Item -Names @('idCard', 'IdCard', 'idcard', '身份证')
    $nameText = [string]$name
    if ([string]::IsNullOrWhiteSpace($nameText)) { return $null }
    return [pscustomobject]@{
        Name   = $nameText.Trim()
        IdCard = if ($null -eq $idCard) { '' } else { [string]$idCard.Trim() }
    }
}

function Add-PersonsToList {
    param(
        [System.Collections.Generic.List[object]]$List,
        $RawPersons
    )
    if ($null -eq $RawPersons) { return }
    foreach ($item in @($RawPersons)) {
        if ($item -is [string]) {
            foreach ($part in ($item -split '[,，;；\s]+')) {
                $entry = ConvertTo-PersonEntry $part
                if ($null -ne $entry) { $List.Add($entry) }
            }
            continue
        }
        $entry = ConvertTo-PersonEntry $item
        if ($null -ne $entry) { $List.Add($entry) }
    }
}

function Normalize-IdCard {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.Trim().ToUpperInvariant() -replace '\s', '')
}

function Get-PersonOutputBaseName {
    param($Person)
    $safeName = Sanitize-FileName $Person.Name
    if ([string]::IsNullOrWhiteSpace($Person.IdCard)) {
        return $safeName
    }
    return ('{0}_{1}' -f $safeName, (Sanitize-FileName $Person.IdCard))
}

function Get-PersonKey {
    param($Person)
    return ('{0}|{1}' -f (Sanitize-FileName $Person.Name), (Normalize-IdCard $Person.IdCard))
}

function Test-PersonAlreadyCaptured {
    param($Person)
    if ([string]::IsNullOrWhiteSpace($Person.IdCard)) { return $false }
    $path = Join-Path $OutputDir ((Get-PersonOutputBaseName -Person $Person) + '.png')
    return (Test-Path $path)
}

function Resolve-PersonList {
    $list = New-Object System.Collections.Generic.List[object]
    if ($Names -and $Names.Count -gt 0) {
        Add-PersonsToList -List $list -RawPersons $Names
    }

    if ($script:ConfigPersons -and $script:ConfigPersons.Count -gt 0) {
        Add-PersonsToList -List $list -RawPersons $script:ConfigPersons
    }

    if (-not [string]::IsNullOrWhiteSpace($NamesFile)) {
        foreach ($line in (Read-LinesUtf8 -Path $NamesFile)) {
            $t = $line.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t.StartsWith('#')) { continue }
            Add-PersonsToList -List $list -RawPersons $t
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SearchName)) {
        $entry = ConvertTo-PersonEntry $SearchName.Trim()
        if ($null -ne $entry) { $list.Add($entry) }
    }

    $unique = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($person in $list) {
        $key = Get-PersonKey $person
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $unique.Add($person)
    }
    return $unique.ToArray()
}

function Get-PendingPersons {
    param([object[]]$Persons)
    $pending = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    foreach ($person in $Persons) {
        if (Test-PersonAlreadyCaptured -Person $person) {
            $skipped++
            continue
        }
        $pending.Add($person)
    }
    return [pscustomobject]@{
        Pending = $pending.ToArray()
        Skipped = $skipped
    }
}

function Find-PersonByOcrIdCard {
    param(
        [object[]]$Candidates,
        [string]$OcrIdCard
    )
    $norm = Normalize-IdCard $OcrIdCard
    if ($norm.Length -eq 0) { return $null }
    foreach ($person in $Candidates) {
        $pNorm = Normalize-IdCard $person.IdCard
        if ($pNorm.Length -eq 0) { continue }
        if ($pNorm -eq $norm) { return $person }
        if ($norm.Contains($pNorm) -or $pNorm.Contains($norm)) { return $person }
    }
    return $null
}

function Apply-AppConfig {
    $cfg = Get-AppConfig
    if ($null -eq $cfg) { return }

    $cfgAppPath = Get-ConfigProperty -Config $cfg -Names @('appPath', 'AppPath')
    if ([string]::IsNullOrWhiteSpace($script:AppPath) -and -not [string]::IsNullOrWhiteSpace([string]$cfgAppPath)) {
        $script:AppPath = [string]$cfgAppPath
    }

    $cfgLoginUser = Get-ConfigProperty -Config $cfg -Names @('loginUser', 'LoginUser')
    if ([string]::IsNullOrWhiteSpace($script:LoginUser) -and -not [string]::IsNullOrWhiteSpace([string]$cfgLoginUser)) {
        $script:LoginUser = [string]$cfgLoginUser
    }

    $cfgLoginPassword = Get-ConfigProperty -Config $cfg -Names @('loginPassword', 'LoginPassword')
    if ([string]::IsNullOrWhiteSpace($script:LoginPassword) -and -not [string]::IsNullOrWhiteSpace([string]$cfgLoginPassword)) {
        $script:LoginPassword = [string]$cfgLoginPassword
    }

    if ($ListEntry -eq 'Multi') {
        # 外院在本院多执业医师：优先读取 namesMulti
        $cfgNames = Get-ConfigProperty -Config $cfg -Names @('namesMulti', 'NamesMulti')
        $usedKey = 'namesMulti'
    }
    else {
        # 主执业机构在本院医师：优先 namesMain，向后兼容旧的 names
        $cfgNames = Get-ConfigProperty -Config $cfg -Names @('namesMain', 'NamesMain', 'names', 'Names')
        $usedKey = 'namesMain/names'
    }
    if ($null -ne $cfgNames) {
        $personList = New-Object System.Collections.Generic.List[object]
        Add-PersonsToList -List $personList -RawPersons $cfgNames
        $script:ConfigPersons = @()
        foreach ($person in $personList) {
            $script:ConfigPersons += $person
        }
        Write-Step ("名单来源：ListEntry={0}，读取配置项 {1}，共 {2} 人。" -f $ListEntry, $usedKey, $script:ConfigPersons.Count)
    }
}

function Read-ConfigHashtable {
    if (-not (Test-Path $ConfigPath)) {
        return @{
            appPath = ''
            loginUser = ''
            loginPassword = ''
            names = @()
        }
    }
    $json = [System.IO.File]::ReadAllText($ConfigPath, (Get-Utf8Encoding))
    $obj = $json | ConvertFrom-Json
    $ht = @{}
    foreach ($prop in $obj.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    return $ht
}

function Write-ConfigHashtable {
    param($Hashtable)
    $json = $Hashtable | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($ConfigPath, $json, (Get-Utf8Encoding))
}

function Set-ConfigSection {
    param(
        [string]$SectionName,
        [hashtable]$SectionData
    )
    $root = Read-ConfigHashtable
    $root[$SectionName] = $SectionData
    Write-ConfigHashtable -Hashtable $root
}

function Test-ConfigSection {
    param(
        $Section,
        [string[]]$RequiredFields
    )
    if ($null -eq $Section) { return $false }
    $props = @($Section.PSObject.Properties.Name)
    foreach ($field in $RequiredFields) {
        if ($props -notcontains $field) { return $false }
    }
    return $true
}

function Get-SectionInt {
    param(
        $Section,
        [string]$FieldName,
        [int]$Default = 0
    )
    if ($null -eq $Section) { return $Default }
    $val = Get-ConfigProperty -Config $Section -Names @($FieldName)
    if ($null -eq $val) { return $Default }
    try { return [int]$val } catch { return $Default }
}

function Test-CalibrationPointValid {
    param(
        [int]$X,
        [int]$Y
    )
    return ($X -gt 0 -and $Y -gt 0)
}

function Get-CalibrationPointFromSection {
    param(
        $Section,
        [string]$XField,
        [string]$YField
    )
    return [pscustomobject]@{
        X = (Get-SectionInt -Section $Section -FieldName $XField)
        Y = (Get-SectionInt -Section $Section -FieldName $YField)
    }
}

function Read-CalibrationSkipChoice {
    param(
        [string]$Prompt,
        [switch]$AllowQuit
    )
    while ($true) {
        $hint = if ($AllowQuit) { 'S 跳过，Enter 重新记录，Q 退出' } else { 'S 跳过，Enter 重新记录' }
        $answer = (Read-Host ("  {0}（{1}）" -f $Prompt, $hint)).Trim().ToUpperInvariant()
        if ($answer -eq 'S') { return 'Skip' }
        if ($answer -eq '' -or $answer -eq 'ENTER') { return 'Record' }
        if ($AllowQuit -and $answer -eq 'Q') { return 'Quit' }
        Write-Host '  无效输入，请重新选择。'
    }
}

function Read-LegacyJsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $json = [System.IO.File]::ReadAllText($Path, (Get-Utf8Encoding))
        return ($json | ConvertFrom-Json)
    }
    catch { return $null }
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
    $netTask = $asTask.Invoke($null, [object[]]@($Operation))
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
    $idCard = $null
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ Name = $null; CertCode = $null; IdCard = $null }
    }

    $compact = ($Text -replace '\s+', '')
    if ($compact -match '姓名[:：]?([\u4e00-\u9fa5·]{2,8})') {
        $name = $Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($name) -and ($Text -match '姓名\s*[:：]?\s*([\u4e00-\u9fa5]{2,4})')) {
        $name = $Matches[1]
    }

    $idMatches = [regex]::Matches($Text, '(?<![\dXx])(?:\d{17}[\dXx]|\d{15})(?![\dXx])')
    if ($idMatches.Count -gt 0) {
        $eighteen = @($idMatches | ForEach-Object { $_.Value } | Where-Object { $_.Length -eq 18 })
        if ($eighteen.Count -gt 0) {
            $idCard = $eighteen[0].ToUpperInvariant()
        }
        else {
            $idCard = $idMatches[0].Value.ToUpperInvariant()
        }
    }

    $digits = [regex]::Matches($Text, '\d+') | ForEach-Object { $_.Value }
    if ($digits.Count -gt 0) {
        $code = $digits | Where-Object { $_.Length -ge 20 } | Sort-Object Length -Descending | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($code)) {
            $code = $digits | Where-Object { $_.Length -ne 18 } | Sort-Object Length -Descending | Select-Object -First 1
        }
    }
    return @{ Name = $name; CertCode = $code; IdCard = $idCard }
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
    $cfg = Get-AppConfig
    if ($null -ne $cfg) {
        $section = Get-ConfigProperty -Config $cfg -Names @('listCalibration', 'ListCalibration')
        if (Test-ConfigSection -Section $section -RequiredFields @('SearchBoxX','SearchBoxY','NameX','FirstRowY','RowHeight')) {
            return $section
        }
    }

    $legacy = Read-LegacyJsonFile -Path $CalibrationPath
    if (Test-ConfigSection -Section $legacy -RequiredFields @('SearchBoxX','SearchBoxY','NameX','FirstRowY','RowHeight')) {
        return $legacy
    }
    return $null
}

function Read-CursorPointWithConfirm {
    param(
        [string]$Title,
        [string]$Instruction,
        [int]$Seconds = $CalibrateCountdown,
        [int]$ExistingX = 0,
        [int]$ExistingY = 0
    )

    $hasExisting = (Test-CalibrationPointValid -X $ExistingX -Y $ExistingY)

    while ($true) {
        Write-Host ''
        Write-Step $Title
        Write-Host ("  {0}" -f $Instruction)
        if ($hasExisting) {
            Write-Host ("  已有坐标：({0},{1})" -f $ExistingX, $ExistingY)
            $choice = Read-CalibrationSkipChoice -Prompt '准备开始时' -AllowQuit
            if ($choice -eq 'Skip') {
                Write-Step ("  已跳过，保留已有坐标：({0},{1})" -f $ExistingX, $ExistingY)
                return [pscustomobject]@{ X = $ExistingX; Y = $ExistingY }
            }
            if ($choice -eq 'Quit') { throw '用户取消坐标校准。' }
        }
        else {
            Write-Host ("  按 Enter 后会开始 {0} 秒倒计时。" -f $Seconds)
            Write-Host '  倒计时期间请把鼠标移动到目标位置，不要点击；倒计时结束自动记录。'
            $startChoice = (Read-Host '  准备开始时按 Enter（Q 退出）').Trim().ToUpperInvariant()
            if ($startChoice -eq 'Q') { throw '用户取消坐标校准。' }
        }

        for ($i = $Seconds; $i -ge 1; $i--) {
            Write-Host ("  {0}..." -f $i)
            Start-Sleep -Seconds 1
        }

        $cursor = [System.Windows.Forms.Cursor]::Position
        $p = [pscustomobject]@{
            X = [int]$cursor.X
            Y = [int]$cursor.Y
        }
        Write-Step ("  已记录坐标：{0},{1}" -f $p.X, $p.Y)
        $answer = (Read-Host '  确认使用这个坐标吗？输入 Y 确认，R 重新记录，Q 退出').Trim().ToUpperInvariant()
        if ($answer -eq '' -or $answer -eq 'Y') { return $p }
        if ($answer -eq 'Q') { throw '用户取消坐标校准。' }
        Write-Step '  将重新记录该步骤。'
    }
}

function Read-RowHeightWithConfirm {
    param(
        [string]$Title,
        [string]$Instruction,
        [int]$FirstRowY,
        [int]$ExistingRowHeight = 0,
        [int]$Seconds = $CalibrateCountdown
    )

    $hasExisting = ($ExistingRowHeight -ge 8)

    while ($true) {
        Write-Host ''
        Write-Step $Title
        Write-Host ("  {0}" -f $Instruction)
        if ($hasExisting) {
            Write-Host ("  已有行高：{0}px" -f $ExistingRowHeight)
            $choice = Read-CalibrationSkipChoice -Prompt '准备开始时' -AllowQuit
            if ($choice -eq 'Skip') {
                Write-Step ("  已跳过，保留已有行高：{0}px" -f $ExistingRowHeight)
                return [pscustomobject]@{
                    Y = [int]($FirstRowY + $ExistingRowHeight)
                    RowHeight = [int]$ExistingRowHeight
                }
            }
            if ($choice -eq 'Quit') { throw '用户取消坐标校准。' }
        }
        else {
            Write-Host ("  按 Enter 后会开始 {0} 秒倒计时。" -f $Seconds)
            Write-Host '  倒计时期间请把鼠标移动到目标位置，不要点击；倒计时结束自动记录。'
            $startChoice = (Read-Host '  准备开始时按 Enter（Q 退出）').Trim().ToUpperInvariant()
            if ($startChoice -eq 'Q') { throw '用户取消坐标校准。' }
        }

        for ($i = $Seconds; $i -ge 1; $i--) {
            Write-Host ("  {0}..." -f $i)
            Start-Sleep -Seconds 1
        }

        $cursor = [System.Windows.Forms.Cursor]::Position
        $p = [pscustomobject]@{
            Y = [int]$cursor.Y
        }
        Write-Step ("  已记录坐标：Y={0}" -f $p.Y)
        $answer = (Read-Host '  确认使用这个坐标吗？输入 Y 确认，R 重新记录，Q 退出').Trim().ToUpperInvariant()
        if ($answer -eq '' -or $answer -eq 'Y') { return $p }
        if ($answer -eq 'Q') { throw '用户取消坐标校准。' }
        Write-Step '  将重新记录该步骤。'
    }
}

function Invoke-Calibration {
    $existing = Get-ConfigProperty -Config (Get-AppConfig) -Names @('listCalibration', 'ListCalibration')
    if ($null -eq $existing) {
        $existing = Read-LegacyJsonFile -Path $CalibrationPath
    }

    Write-Step '列表坐标校准开始。请保证医师系统已打开，并停留在医师列表页。'
    Write-Step '请先随便搜索一个常见姓名/姓氏，让列表至少显示两行结果。'
    Write-Step '已有坐标的步骤可输入 S 跳过。'
    Read-Host '列表准备好后按 Enter 开始校准'

    $existingSearch = Get-CalibrationPointFromSection -Section $existing -XField 'SearchBoxX' -YField 'SearchBoxY'
    $search = Read-CursorPointWithConfirm -Title '列表校准 第1步/3：医师姓名输入框' -Instruction '把鼠标移到【医师姓名】输入框中间。' `
        -ExistingX $existingSearch.X -ExistingY $existingSearch.Y

    $existingRow1 = Get-CalibrationPointFromSection -Section $existing -XField 'NameX' -YField 'FirstRowY'
    $row1 = Read-CursorPointWithConfirm -Title '列表校准 第2步/3：第1行姓名单元格' -Instruction '把鼠标移到列表【第 1 行】的【姓名】单元格中间。' `
        -ExistingX $existingRow1.X -ExistingY $existingRow1.Y

    $existingRowHeight = Get-SectionInt -Section $existing -FieldName 'RowHeight'
    $row2 = Read-RowHeightWithConfirm -Title '列表校准 第3步/3：第2行姓名单元格' -Instruction '把鼠标移到列表【第 2 行】的【姓名】单元格中间。' `
        -FirstRowY ([int]$row1.Y) -ExistingRowHeight $existingRowHeight

    if ($row2.PSObject.Properties.Name -contains 'RowHeight') {
        $rowHeight = [int]$row2.RowHeight
    }
    else {
        $rowHeight = [Math]::Abs($row2.Y - $row1.Y)
        if ($rowHeight -lt 8) {
            Write-Step ("警告：两行间距太小（{0}px），将使用默认行高 {1}。请确认第1、2行选对了。" -f $rowHeight, $TableRowHeight)
            $rowHeight = $TableRowHeight
        }
    }

    $section = @{
        SearchBoxX = [int]$search.X
        SearchBoxY = [int]$search.Y
        NameX      = [int]$row1.X
        FirstRowY  = [int]$row1.Y
        RowHeight  = [int]$rowHeight
        SavedAt    = (Get-Date).ToString('s')
    }
    Set-ConfigSection -SectionName 'listCalibration' -SectionData $section
    Write-Step ("列表坐标已保存到 {0} 的 listCalibration" -f $ConfigPath)
    Write-Step ("搜索框=({0},{1}) 姓名列X={2} 首行Y={3} 行高={4}" -f $section.SearchBoxX, $section.SearchBoxY, $section.NameX, $section.FirstRowY, $section.RowHeight)
    Write-Step '现在可以运行： .\\run-capture.cmd'
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

function Invoke-CaptureBatchRest {
    param([int]$TotalSaved)
    if ($CaptureRestInterval -le 0 -or $CaptureRestMinutes -le 0) { return }
    if ($TotalSaved % $CaptureRestInterval -ne 0) { return }

    $restSeconds = $CaptureRestMinutes * 60
    Write-CaptureState -Stage 'Rest' -Message ("已抓取 {0} 次，休息 {1} 分钟" -f $TotalSaved, $CaptureRestMinutes)
    Write-Step ("已累计成功截图 {0} 张，休息 {1} 分钟..." -f $TotalSaved, $CaptureRestMinutes)
    Start-Sleep -Seconds $restSeconds
    Write-Step '休息结束，继续抓取。'
}

$script:NeedRestart = $false
$script:ErrorPopupCount = 0
$script:LastErrorPopupTime = $null
$script:CapturedSinceLastPopup = 0
$script:ErrorPopupStatsReady = $false

function Append-CsvRowToPath {
    param(
        [string]$Path,
        [pscustomobject]$Row
    )
    $enc = Get-Utf8Encoding
    $csv = @($Row | ConvertTo-Csv -NoTypeInformation)
    if (Test-Path $Path) {
        [System.IO.File]::AppendAllText($Path, $csv[1] + [Environment]::NewLine, $enc)
    }
    else {
        [System.IO.File]::WriteAllText($Path, $csv[0] + [Environment]::NewLine + $csv[1] + [Environment]::NewLine, $enc)
    }
}

function Initialize-ErrorPopupStats {
    if ($script:ErrorPopupStatsReady) { return }
    $script:ErrorPopupStatsReady = $true
    if (-not (Test-Path $ErrorLogPath)) { return }
    try {
        $rows = @(Import-Csv $ErrorLogPath)
        if ($rows.Count -gt 0) {
            $script:ErrorPopupCount = $rows.Count
            try { $script:LastErrorPopupTime = [datetime]$rows[-1].Timestamp } catch { }
        }
    }
    catch { }
}

function Find-ErrorPopup {
    foreach ($win in Get-RootWindows) {
        if ($win.Current.IsOffscreen) { continue }
        $title = [string]$win.Current.Name
        $text = ''
        try { $text = Get-ElementTextSummary $win } catch { }
        $combined = ($title + ' | ' + $text)
        if ($combined -match $ErrorPopupTextRegex) {
            return [pscustomobject]@{ Window = $win; Title = $title; Text = $combined }
        }
    }
    return $null
}

function Write-ErrorPopupLog {
    param(
        [string]$Context = '',
        [string]$PopupText = ''
    )
    Initialize-ErrorPopupStats
    $now = Get-Date
    $script:ErrorPopupCount++
    $secondsSinceLast = ''
    if ($null -ne $script:LastErrorPopupTime) {
        $secondsSinceLast = [int]((New-TimeSpan -Start $script:LastErrorPopupTime -End $now).TotalSeconds)
    }
    $cleanText = ($PopupText -replace '\s+', ' ').Trim()
    if ($cleanText.Length -gt 200) { $cleanText = $cleanText.Substring(0, 200) }
    Append-CsvRowToPath -Path $ErrorLogPath -Row ([pscustomobject]@{
        Timestamp         = $now.ToString('s')
        Count             = $script:ErrorPopupCount
        SecondsSinceLast  = $secondsSinceLast
        CapturedSinceLast = $script:CapturedSinceLastPopup
        Context           = $Context
        PopupText         = $cleanText
    })
    Write-Step ("接口异常弹窗第 {0} 次：距上次 {1} 秒，期间成功截图 {2} 张。" -f `
        $script:ErrorPopupCount, $(if ($secondsSinceLast -eq '') { '—' } else { $secondsSinceLast }), $script:CapturedSinceLastPopup)
    $script:LastErrorPopupTime = $now
    $script:CapturedSinceLastPopup = 0
}

function Stop-DoctorApplication {
    Write-Step '关闭医师系统应用...'
    $killed = 0
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $t = $proc.MainWindowTitle
            if (-not [string]::IsNullOrWhiteSpace($t) -and ($t -match $MainWindowTitleRegex -or $t -match $LoginWindowTitleRegex)) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                $killed++
            }
        }
        catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($AppPath) -and (Test-Path $AppPath)) {
        $procName = [IO.Path]::GetFileNameWithoutExtension($AppPath)
        foreach ($proc in (Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; $killed++ } catch { }
        }
    }
    Write-Step ("已结束 {0} 个相关进程。" -f $killed)
    Start-Sleep -Seconds 3
}

function Restart-DoctorAndEnterList {
    if ([string]::IsNullOrWhiteSpace($AppPath)) {
        throw '未配置 appPath，无法自动重启应用。请在 config.json 设置 appPath。'
    }
    Stop-DoctorApplication
    Start-Sleep -Seconds $RestartWaitSeconds
    Invoke-LoginAndEnterList
}

function Invoke-CaptureNameSeriesWithRecovery {
    Initialize-ErrorPopupStats
    for ($attempt = 0; ; $attempt++) {
        $script:NeedRestart = $false
        Capture-NameSeries
        if (-not $script:NeedRestart) { break }
        if ($NoAutoRestart) {
            Write-Step '检测到接口异常弹窗，但已禁用自动重启（-NoAutoRestart），停止。'
            break
        }
        if ($attempt -ge $MaxAutoRestarts) {
            Write-Step ("已达到最大自动重启次数 {0}，停止。" -f $MaxAutoRestarts)
            break
        }
        Write-Step ("第 {0} 次自动重启：重启应用并恢复抓取..." -f ($attempt + 1))
        try {
            Restart-DoctorAndEnterList
        }
        catch {
            Write-Step ("重启失败：{0}" -f $_.Exception.Message)
            break
        }
    }
}

function Wait-IfPauseRequested {
    try {
        $pressed = $false
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Spacebar') { $pressed = $true }
        }
        if (-not $pressed) { return }

        Write-Step '已暂停（按【空格】继续）...'
        while ($true) {
            Start-Sleep -Milliseconds 200
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Spacebar') {
                    Write-Step '已恢复运行。'
                    return
                }
            }
        }
    }
    catch {
        # 控制台不可交互（如输入被重定向）时忽略暂停功能。
    }
}

function Capture-NameSeries {
    Write-Step '提示：运行中可按【空格】暂停，再按【空格】恢复。'
    $allPersons = @(Resolve-PersonList)
    if ($allPersons.Count -eq 0) {
        throw ("请在 config.json 的 names 中配置人员（name + idCard），或使用 -Names / -NamesFile / -SearchName 指定。配置文件：{0}" -f $ConfigPath)
    }

    $pendingResult = Get-PendingPersons -Persons $allPersons
    $personList = @($pendingResult.Pending)
    if ($pendingResult.Skipped -gt 0) {
        Write-Step ("已跳过 {0} 个已有截图的人员（按 姓名+身份证 匹配 {1}）。" -f $pendingResult.Skipped, $OutputDir)
    }
    if ($personList.Count -eq 0) {
        Write-Step '所有配置人员均已有截图，无需继续抓取。'
        Review-Output
        return
    }

    $missingIdCard = @($personList | Where-Object { [string]::IsNullOrWhiteSpace($_.IdCard) })
    if ($missingIdCard.Count -gt 0) {
        Write-Step ("警告：有 {0} 个人员未配置 idCard，将无法按身份证命名和启动前去重。" -f $missingIdCard.Count)
    }

    $cfg = Get-Calibration
    if ($null -eq $cfg) {
        Write-Step ("未找到有效列表坐标，请在 config.json 的 listCalibration 中配置，或运行 run-calibrate.cmd。")
        throw 'Calibration required.'
    }

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
    Write-Step ("截图保存目录：{0}" -f $OutputDir)
    if (-not $NoOcr) { Initialize-Ocr | Out-Null }

    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        Write-MainWindowNotFoundHelp $MainWindowTitleRegex
        throw 'Main window not found. See messages above.'
    }
    $mainHandle = [int]$main.Current.NativeWindowHandle

    Write-Step ("待抓取 {0} 人，OCR={1}，校准=({2},{3})，姓名列X={4}，首行Y={5}，行高={6}" -f `
        $personList.Count, (-not $NoOcr), $cfg.SearchBoxX, $cfg.SearchBoxY, $cfg.NameX, $cfg.FirstRowY, $cfg.RowHeight)

    $totalSaved = 0
    $groups = $personList | Group-Object -Property Name
    foreach ($group in $groups) {
        Wait-IfPauseRequested
        $searchName = [string]$group.Name
        $remaining = New-Object System.Collections.Generic.List[object]
        foreach ($person in $group.Group) { $remaining.Add($person) }

        Write-CaptureState -Stage 'SearchName' -CurrentName $searchName -CurrentRow 0 -Message '搜索姓名'
        Write-Step ("=== 搜索姓名：{0}（待抓取 {1} 人）===" -f $searchName, $remaining.Count)
        try {
            Invoke-NameSearchInput -MainWindow $main -Calibration $cfg -Name $searchName
        }
        catch {
            Write-Step ("输入姓名失败：{0}" -f $_.Exception.Message)
            continue
        }
        Start-Sleep -Seconds $SearchWaitSeconds

        $rowSavedForName = 0
        $seenSignatures = @{}
        $seenOcrIdCards = @{}
        $consecutiveRowFailures = 0
        $stopCurrentName = $false
        $previousDetailHash = ''
        for ($row = 0; $row -lt $MaxRowsPerName -and $remaining.Count -gt 0; $row++) {
            Wait-IfPauseRequested
            $x = [int]$cfg.NameX
            $y = [int]$cfg.FirstRowY + ($row * [int]$cfg.RowHeight)

            Write-CaptureState -Stage 'OpenRow' -CurrentName $searchName -CurrentRow $row -Message ("打开第 {0} 行" -f ($row + 1))
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
                $popup = Find-ErrorPopup
                if ($null -ne $popup) {
                    Write-ErrorPopupLog -Context ("name={0};row={1}" -f $searchName, ($row + 1)) -PopupText $popup.Text
                    Write-Step '  检测到接口异常弹窗，将重启应用并恢复抓取。'
                    $script:NeedRestart = $true
                    return
                }
                if ($row -eq 0) { Write-Step ("  未出现详情窗口，'{0}' 可能无结果。" -f $searchName) }
                else { Write-Step ("  第 {0} 行无更多结果，结束该姓名。" -f ($row + 1)) }
                break
            }

            $fileName = $null
            $targetPerson = $null
            $isDuplicate = $false
            $isUnmatched = $false
            try {
                Write-CaptureState -Stage 'CaptureDetail' -CurrentName $searchName -CurrentRow $row -Message ("截图第 {0} 行详情" -f ($row + 1))
                $bitmap = Capture-WindowBitmap -Window $detail
                try {
                    $detailHash = Get-BitmapHash -Bitmap $bitmap
                    if (-not [string]::IsNullOrWhiteSpace($previousDetailHash) -and $detailHash -eq $previousDetailHash) {
                        $isDuplicate = $true
                        $stopCurrentName = $true
                        Write-Step ("  第 {0} 行详情与上一行相同，判定为空行重复弹窗，结束该姓名。" -f ($row + 1))
                    }
                    else {
                        $previousDetailHash = $detailHash
                        $ocrIdCard = $null
                        if (-not $NoOcr) {
                            $ocrText = Get-OcrTextFromBitmap -Bitmap $bitmap
                            $fields = Get-DetailFieldsFromOcrText -Text $ocrText
                            $ocrIdCard = $fields.IdCard
                        }

                        if (-not $NoOcr) {
                            if ([string]::IsNullOrWhiteSpace($ocrIdCard)) {
                                $isUnmatched = $true
                                Write-Step ("  第 {0} 行未识别到身份证号，跳过。" -f ($row + 1))
                            }
                            else {
                                $normOcrId = Normalize-IdCard $ocrIdCard
                                if ($seenOcrIdCards.ContainsKey($normOcrId)) {
                                    $isUnmatched = $true
                                    Write-Step ("  第 {0} 行列表重复出现身份证 {1}，跳过。" -f ($row + 1), $normOcrId)
                                }
                                else {
                                    $targetPerson = Find-PersonByOcrIdCard -Candidates $remaining.ToArray() -OcrIdCard $ocrIdCard
                                    if ($null -eq $targetPerson) {
                                        $isUnmatched = $true
                                        Write-Step ("  第 {0} 行身份证 {1} 不在待抓取名单，跳过。" -f ($row + 1), $normOcrId)
                                    }
                                }
                            }
                        }
                        elseif ($remaining.Count -eq 1) {
                            $targetPerson = $remaining[0]
                            Write-Step ("  警告：未启用 OCR，按待抓取顺序保存第 1 人。")
                        }
                        else {
                            $isUnmatched = $true
                            Write-Step ("  第 {0} 行同名待抓取 {1} 人，未启用 OCR 无法区分，跳过。" -f ($row + 1), $remaining.Count)
                        }

                        if ($null -ne $targetPerson) {
                            if ([string]::IsNullOrWhiteSpace($targetPerson.IdCard)) {
                                throw '该人员未配置 idCard，无法按 姓名+身份证 保存。'
                            }

                            $signature = 'idcard:' + (Normalize-IdCard $targetPerson.IdCard)
                            if ($seenSignatures.ContainsKey($signature)) {
                                $isDuplicate = $true
                                Write-Step ("  第 {0} 行与已截取的记录重复，停止该姓名。" -f ($row + 1))
                            }
                            elseif (Test-PersonAlreadyCaptured -Person $targetPerson) {
                                $isDuplicate = $true
                                Write-Step ("  第 {0} 行对应人员已有截图，停止该姓名。" -f ($row + 1))
                            }
                            else {
                                $seenSignatures[$signature] = $true
                                $baseName = Get-PersonOutputBaseName -Person $targetPerson
                                $path = Join-Path $OutputDir ($baseName + '.png')
                                $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
                                $fileName = [IO.Path]::GetFileName($path)
                                [void]$remaining.Remove($targetPerson)
                                if (-not $NoOcr) {
                                    $seenOcrIdCards[(Normalize-IdCard $targetPerson.IdCard)] = $true
                                }
                                Write-CaptureState -Stage 'SearchName' -CurrentName $searchName -CurrentRow ($row + 1) -CurrentIdCard $targetPerson.IdCard -Message '已保存当前人员，继续下一行'
                            }
                        }
                    }
                }
                finally {
                    $bitmap.Dispose()
                }
                $consecutiveRowFailures = 0

                if ($null -ne $targetPerson -and -not $isDuplicate -and -not $isUnmatched) {
                    Append-LogRow ([pscustomobject]@{
                        Timestamp   = (Get-Date).ToString('s')
                        RowIndex    = ($row + 1)
                        Status      = 'success'
                        FileName    = $fileName
                        DetailTitle = $detail.Current.Name
                        Name        = $targetPerson.Name
                        License     = $targetPerson.IdCard
                        Signature   = ("search:{0}:idcard:{1}:row:{2}" -f $searchName, $targetPerson.IdCard, ($row + 1))
                        Message     = 'name-series capture'
                        RowText     = ''
                    })
                    Write-Step ("  已保存：{0}" -f $fileName)
                    $totalSaved++
                    $rowSavedForName++
                    $script:CapturedSinceLastPopup++
                    Invoke-CaptureBatchRest -TotalSaved $totalSaved
                }
            }
            catch {
                Append-LogRow ([pscustomobject]@{
                    Timestamp   = (Get-Date).ToString('s')
                    RowIndex    = ($row + 1)
                    Status      = 'failed'
                    FileName    = $fileName
                    DetailTitle = ''
                    Name        = $searchName
                    License     = ''
                    Signature   = ("name:{0}:row:{1}" -f $searchName, ($row + 1))
                    Message     = $_.Exception.Message
                    RowText     = ''
                })
                Write-Step ("  第 {0} 行截图失败：{1}" -f ($row + 1), $_.Exception.Message)
                $consecutiveRowFailures++
                if ($consecutiveRowFailures -ge $StopAfterConsecutiveFailures) {
                    Write-Step ("  连续 {0} 行截图失败，停止该姓名，避免继续点击空行。" -f $consecutiveRowFailures)
                    $stopCurrentName = $true
                }
            }
            finally {
                Close-WindowWithAltF4 $detail
                Start-Sleep -Milliseconds 250
                Bring-ToFront $main
                Start-Sleep -Milliseconds 150
            }

            if ($stopCurrentName) { break }
            if ($isDuplicate) { break }
        }

        if ($remaining.Count -gt 0) {
            Write-Step ("  '{0}' 仍有 {1} 人未匹配到截图。" -f $searchName, $remaining.Count)
        }
        Write-Step ("  '{0}' 完成，本次截图 {1} 张。" -f $searchName, $rowSavedForName)
        Write-CaptureState -Stage 'ListReady' -CurrentName $searchName -CurrentRow 0 -Message ("姓名 {0} 已处理完成" -f $searchName)
    }

    Write-Step ("全部完成，共截图 {0} 张。" -f $totalSaved)
    Write-CaptureState -Stage 'Completed' -Message '全部完成'
    Review-Output
}

#region 登录自动化（启动应用 + 坐标登录 + 进入列表页）

function Get-LoginCalibration {
    $cfg = Get-AppConfig
    if ($null -ne $cfg) {
        $section = Get-ConfigProperty -Config $cfg -Names @('loginCalibration', 'LoginCalibration')
        if (Test-ConfigSection -Section $section -RequiredFields @('SwitchLoginX','SwitchLoginY','UserX','UserY','PasswordX','PasswordY','LoginButtonX','LoginButtonY','MainInstitutionX','MainInstitutionY')) {
            return $section
        }
    }

    $legacy = Read-LegacyJsonFile -Path $LoginConfigPath
    if (Test-ConfigSection -Section $legacy -RequiredFields @('SwitchLoginX','SwitchLoginY','UserX','UserY','PasswordX','PasswordY','LoginButtonX','LoginButtonY','MainInstitutionX','MainInstitutionY')) {
        return $legacy
    }
    return $null
}

function Invoke-LoginCalibration {
    $existing = Get-ConfigProperty -Config (Get-AppConfig) -Names @('loginCalibration', 'LoginCalibration')
    if ($null -eq $existing) {
        $existing = Read-LegacyJsonFile -Path $LoginConfigPath
    }

    Write-Step '登录坐标校准开始。请打开医师系统登录页。'
    Write-Step '每一步都会等待你按 Enter 后才记录坐标，并允许确认或重录。'
    Write-Step '已有坐标的步骤可输入 S 跳过。'
    Read-Host '登录页准备好后按 Enter 开始校准'

    $existingSwitchLogin = Get-CalibrationPointFromSection -Section $existing -XField 'SwitchLoginX' -YField 'SwitchLoginY'
    $switchLogin = Read-CursorPointWithConfirm -Title '登录校准 第1步/6：切换登录方式' -Instruction '把鼠标移到右上角【切换登录方式】链接中间。' `
        -ExistingX $existingSwitchLogin.X -ExistingY $existingSwitchLogin.Y

    $existingUser = Get-CalibrationPointFromSection -Section $existing -XField 'UserX' -YField 'UserY'
    $userBox = Read-CursorPointWithConfirm -Title '登录校准 第2步/6：账号输入框' -Instruction '切换到账号登录界面后，把鼠标移到【账号输入框】中间。' `
        -ExistingX $existingUser.X -ExistingY $existingUser.Y

    $existingPassword = Get-CalibrationPointFromSection -Section $existing -XField 'PasswordX' -YField 'PasswordY'
    $passwordBox = Read-CursorPointWithConfirm -Title '登录校准 第3步/6：密码输入框' -Instruction '把鼠标移到【密码输入框】中间。' `
        -ExistingX $existingPassword.X -ExistingY $existingPassword.Y

    $existingLoginButton = Get-CalibrationPointFromSection -Section $existing -XField 'LoginButtonX' -YField 'LoginButtonY'
    $loginButton = Read-CursorPointWithConfirm -Title '登录校准 第4步/6：登录按钮' -Instruction '把鼠标移到【登录】按钮中间。' `
        -ExistingX $existingLoginButton.X -ExistingY $existingLoginButton.Y

    Write-Step '第5、6步需要校准登录后的两个列表入口。'
    Write-Step '请先手动登录，等待主页加载完成，然后继续。'
    Read-Host '主页已经加载完成后按 Enter 继续'

    $existingMainEntry = Get-CalibrationPointFromSection -Section $existing -XField 'MainInstitutionX' -YField 'MainInstitutionY'
    $mainEntry = Read-CursorPointWithConfirm -Title '登录校准 第5步/6：主执业机构在本院医师入口' -Instruction '把鼠标移到主页左侧【主执业机构在本院医师】入口中间。' `
        -ExistingX $existingMainEntry.X -ExistingY $existingMainEntry.Y

    $existingMultiEntry = Get-CalibrationPointFromSection -Section $existing -XField 'MultiInstitutionX' -YField 'MultiInstitutionY'
    $multiEntry = Read-CursorPointWithConfirm -Title '登录校准 第6步/6：外院在本院多执业医师入口' -Instruction '把鼠标移到【外院在本院多执业医师】入口中间。' `
        -ExistingX $existingMultiEntry.X -ExistingY $existingMultiEntry.Y

    $section = @{
        SwitchLoginX      = [int]$switchLogin.X
        SwitchLoginY      = [int]$switchLogin.Y
        UserX             = [int]$userBox.X
        UserY             = [int]$userBox.Y
        PasswordX         = [int]$passwordBox.X
        PasswordY         = [int]$passwordBox.Y
        LoginButtonX      = [int]$loginButton.X
        LoginButtonY      = [int]$loginButton.Y
        MainInstitutionX  = [int]$mainEntry.X
        MainInstitutionY  = [int]$mainEntry.Y
        MultiInstitutionX = [int]$multiEntry.X
        MultiInstitutionY = [int]$multiEntry.Y
        SavedAt           = (Get-Date).ToString('s')
    }
    Set-ConfigSection -SectionName 'loginCalibration' -SectionData $section
    Write-Step ("登录坐标已保存到 {0} 的 loginCalibration" -f $ConfigPath)
    Write-Step ("切换=({0},{1}) 账号=({2},{3}) 密码=({4},{5}) 登录=({6},{7}) 主执业入口=({8},{9}) 外院多执业入口=({10},{11})" -f `
        $section.SwitchLoginX, $section.SwitchLoginY, $section.UserX, $section.UserY, $section.PasswordX, $section.PasswordY, `
        $section.LoginButtonX, $section.LoginButtonY, $section.MainInstitutionX, $section.MainInstitutionY, `
        $section.MultiInstitutionX, $section.MultiInstitutionY)
}

function Invoke-AllCalibration {
    Write-Step '统一坐标校准开始。'
    Write-Step '本流程会依次完成：登录坐标校准 -> 列表截图坐标校准。'
    Write-Step '每个点位都可以确认或重录；已有有效坐标的步骤可输入 S 跳过。'
    Read-Host '准备好后按 Enter 开始登录坐标校准'
    Invoke-LoginCalibration

    Write-Host ''
    Write-Step '登录坐标校准已完成。下面开始列表截图坐标校准。'
    Write-Step '请确保已经进入【主执业机构在本院医师】列表页，并让列表至少显示两行结果。'
    Read-Host '列表页准备好后按 Enter 开始列表坐标校准'
    Invoke-Calibration

    Write-Host ''
    Write-Step '统一坐标校准完成。'
    Write-Step ("所有坐标已保存到 {0}" -f $ConfigPath)
}

function Find-WindowByAnyTitle {
    param([string]$TitleRegex)
    foreach ($win in Get-RootWindows) {
        $title = $win.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($title) -and $title -match $TitleRegex) {
            return $win
        }
    }
    return $null
}

function Wait-WindowByAnyTitle {
    param(
        [string]$TitleRegex,
        [int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $win = Find-WindowByAnyTitle -TitleRegex $TitleRegex
        if ($null -ne $win) { return $win }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Start-DoctorApplication {
    if ([string]::IsNullOrWhiteSpace($AppPath)) {
        Write-Step '未提供 -AppPath，将使用当前已打开的医师系统窗口。'
        return
    }
    if (-not (Test-Path $AppPath)) {
        throw "AppPath not found: $AppPath"
    }
    Write-Step ("启动应用：{0}" -f $AppPath)
    Start-Process -FilePath $AppPath | Out-Null
}

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Clear-ClipboardSafe {
    try {
        [System.Windows.Forms.Clipboard]::Clear()
    }
    catch {
        Write-Step ("Warning: 清空剪贴板失败：{0}" -f $_.Exception.Message)
    }
}

function Invoke-ClickAndPasteText {
    param(
        [int]$X,
        [int]$Y,
        [string]$Text,
        [System.Windows.Automation.AutomationElement]$FocusWindow = $null,
        [switch]$ClearClipboardAfterPaste
    )
    Invoke-ScreenClick -X $X -Y $Y -FocusWindow $FocusWindow
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
    Start-Sleep -Milliseconds 80
    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 120
    if ($ClearClipboardAfterPaste) {
        Clear-ClipboardSafe
    }
}

function Wait-RectStable {
    param(
        [System.Windows.Rect]$Rect,
        [int]$TimeoutSeconds = 10,
        [int]$StableChecks = 2
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    $same = 0
    do {
        try {
            $hash = Get-ScreenRectHash $Rect
            if ($hash -eq $last) { $same++ } else { $same = 0 }
            $last = $hash
            if ($same -ge $StableChecks) { return $true }
        }
        catch { }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Wait-LoggedInMainWindow {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $main = Find-MainApplicationWindow $MainWindowTitleRegex
        if ($null -ne $main) {
            $title = $main.Current.Name
            $rect = $main.Current.BoundingRectangle
            if ($title -notmatch '用户登录' -and $rect.Width -gt 800 -and $rect.Height -gt 500) {
                return $main
            }
        }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-LoginToHome {
    Write-CaptureState -Stage 'Login' -Message '准备登录'
    $loginCfg = Get-LoginCalibration
    if ($null -eq $loginCfg) {
        Write-Step ("未找到有效登录坐标，请在 config.json 的 loginCalibration 中配置，或运行 run-calibrate.cmd。")
        throw 'Login calibration required.'
    }
    if ([string]::IsNullOrWhiteSpace($LoginUser)) {
        $LoginUserValue = Read-Host '请输入登录账号'
    }
    else {
        $LoginUserValue = $LoginUser
    }
    if ([string]::IsNullOrWhiteSpace($LoginPassword)) {
        $securePassword = Read-Host '请输入登录密码（不会保存）' -AsSecureString
        $plainPassword = Convert-SecureStringToPlainText -Secure $securePassword
    }
    else {
        $plainPassword = $LoginPassword
    }

    Write-CaptureState -Stage 'StartApp' -Message '启动应用或使用已打开窗口'
    Start-DoctorApplication
    $loginWin = Wait-WindowByAnyTitle -TitleRegex $LoginWindowTitleRegex -TimeoutSeconds $LoginWaitSeconds
    if ($null -eq $loginWin) {
        throw "登录窗口未出现。请检查 -AppPath 或 -LoginWindowTitleRegex。"
    }
    Bring-ToFront $loginWin

    Write-CaptureState -Stage 'Login' -Message '切换登录方式'
    Write-Step '点击“切换登录方式”。'
    Invoke-ScreenClick -X ([int]$loginCfg.SwitchLoginX) -Y ([int]$loginCfg.SwitchLoginY) -FocusWindow $loginWin
    Start-Sleep -Milliseconds 1000
    Wait-RectStable -Rect $loginWin.Current.BoundingRectangle -TimeoutSeconds 4 -StableChecks 1 | Out-Null

    Write-Step '输入账号。'
    Invoke-ClickAndPasteText -X ([int]$loginCfg.UserX) -Y ([int]$loginCfg.UserY) -Text $LoginUserValue -FocusWindow $loginWin

    Write-Step '输入密码。'
    try {
        Invoke-ClickAndPasteText -X ([int]$loginCfg.PasswordX) -Y ([int]$loginCfg.PasswordY) -Text $plainPassword -FocusWindow $loginWin -ClearClipboardAfterPaste
    }
    finally {
        $plainPassword = $null
        Clear-ClipboardSafe
    }

    Write-Step '点击登录。'
    Invoke-ScreenClick -X ([int]$loginCfg.LoginButtonX) -Y ([int]$loginCfg.LoginButtonY) -FocusWindow $loginWin

    Write-CaptureState -Stage 'WaitMain' -Message '等待主页加载完成'
    Write-Step '等待主页加载完成。'
    $main = Wait-LoggedInMainWindow -TimeoutSeconds $LoginWaitSeconds
    if ($null -eq $main) {
        throw '登录后未检测到主窗口，请检查账号密码、验证码/扫码要求或网络加载状态。'
    }
    Bring-ToFront $main
    Write-Step '最大化主页窗口。'
    Maximize-Window $main
    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        throw '最大化主页窗口后主窗口丢失。'
    }
    Wait-RectStable -Rect $main.Current.BoundingRectangle -TimeoutSeconds $PostLoginWaitSeconds -StableChecks 2 | Out-Null
    Write-CaptureState -Stage 'HomeReady' -Message '主页已稳定'
    Write-Step '主页已稳定。'
    return $main
}

function Invoke-EnterListFromHome {
    param([System.Windows.Automation.AutomationElement]$MainWindow = $null)

    $loginCfg = Get-LoginCalibration
    if ($null -eq $loginCfg) {
        Write-Step ("未找到有效登录坐标，请在 config.json 的 loginCalibration 中配置，或运行 run-calibrate.cmd。")
        throw 'Login calibration required.'
    }

    $main = $MainWindow
    if ($null -eq $main) {
        $main = Find-MainApplicationWindow $MainWindowTitleRegex
        if ($null -eq $main) {
            Write-MainWindowNotFoundHelp $MainWindowTitleRegex
            throw 'Main window not found. Please login to the home page first.'
        }
    }

    Write-Step '激活并最大化医师系统窗口。'
    Bring-ToFront $main
    Maximize-Window $main
    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        throw '最大化窗口后主窗口丢失。'
    }
    Bring-ToFront $main
    Wait-RectStable -Rect $main.Current.BoundingRectangle -TimeoutSeconds $PostLoginWaitSeconds -StableChecks 2 | Out-Null

    if ($ListEntry -eq 'Multi') {
        $entryX = [int](Get-ConfigProperty -Config $loginCfg -Names @('MultiInstitutionX'))
        $entryY = [int](Get-ConfigProperty -Config $loginCfg -Names @('MultiInstitutionY'))
        if ($entryX -le 0 -and $entryY -le 0) {
            throw '未找到【外院在本院多执业医师】入口坐标。请先运行 run-calibrate.cmd 完成第6步坐标校准。'
        }
        Write-CaptureState -Stage 'OpenList' -Message '点击外院在本院多执业医师入口'
        Write-Step '点击“外院在本院多执业医师”。'
    }
    else {
        $entryX = [int]$loginCfg.MainInstitutionX
        $entryY = [int]$loginCfg.MainInstitutionY
        Write-CaptureState -Stage 'OpenList' -Message '点击主执业机构入口'
        Write-Step '点击“主执业机构在本院医师”。'
    }
    Invoke-ScreenClick -X $entryX -Y $entryY -FocusWindow $main
    Start-Sleep -Seconds 2
    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        throw '点击主执业机构入口后主窗口丢失。'
    }
    Bring-ToFront $main
    $tableRect = Find-TablePaneRect $main
    if (-not (Wait-RectStable -Rect $tableRect -TimeoutSeconds $PostLoginWaitSeconds -StableChecks 2)) {
        Write-Step 'Warning: 列表区域未完全稳定，仍将继续执行后续姓名截图。'
    }
    else {
        Write-Step '列表页已稳定。'
    }
    Write-CaptureState -Stage 'ListReady' -Message '列表页已稳定'
}

function Invoke-LoginAndEnterList {
    $main = Invoke-LoginToHome
    Invoke-EnterListFromHome -MainWindow $main
}

function Invoke-OpenListAndCaptureNames {
    if ($ResetState) {
        Clear-CaptureState
        Write-Step '已清除上次状态文件。'
    }
    Write-Step '将从当前主页点击入口进入列表，然后开始姓名截图。'
    Invoke-EnterListFromHome
    Invoke-CaptureNameSeriesWithRecovery
}

function Invoke-LoginAndCaptureNames {
    if ($ResetState) {
        Clear-CaptureState
        Write-Step '已清除上次状态文件。'
    }
    Write-Step '状态恢复已关闭：本次将从登录/进入列表流程开始。'
    Invoke-LoginAndEnterList
    Invoke-CaptureNameSeriesWithRecovery
}

#endregion

#endregion

Apply-AppConfig

switch ($Mode) {
    'Probe' { Probe-Environment }
    'Calibrate' { Invoke-Calibration }
    'LoginCalibrate' { Invoke-LoginCalibration }
    'CalibrateAll' { Invoke-AllCalibration }
    'Prototype' {
        if ($Limit -le 0) { $Limit = 5 }
        Capture-Details -EffectiveLimit $Limit
        Review-Output
    }
    'Batch' { Capture-Details -EffectiveLimit $Limit; Review-Output }
    'Search' { Capture-NameSeries }
    'SearchNames' { Capture-NameSeries }
    'LoginToHome' { [void](Invoke-LoginToHome) }
    'OpenListAndSearchNames' { Invoke-OpenListAndCaptureNames }
    'LoginAndSearchNames' { Invoke-LoginAndCaptureNames }
    'Review' { Review-Output }
}
