param(
    [ValidateSet('Probe','Prototype','Batch','Search','SearchNames','Calibrate','LoginCalibrate','CalibrateAll','LoginToHome','OpenListAndSearchNames','LoginAndSearchNames','Review','Export','ExportCalibrate')]
    [string]$Mode = 'Probe',

    # 列表入口：Main=主执业机构在本院医师；Multi=外院在本院多执业医师
    [ValidateSet('Main','Multi')]
    [string]$ListEntry = 'Main',

    [string]$MainWindowTitleRegex = '医师电子化注册信息系统|机构版',
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

    # 数据导出相关
    [string]$ExportDir = '',
    [int]$MaxCaptchaRetries = 0,
    [int]$LoadingWaitSeconds = 120,
    [switch]$KeepAppOpen,

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
    [switch]$KeepDetailWindowOpen,

    # 机构端窗口离开前台时自动暂停，回到前台自动继续（可用 -DisableForegroundPause 关闭）
    [switch]$DisableForegroundPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }

$AutomationRoot = Split-Path -Parent $PSScriptRoot
$ProjectRoot = Split-Path -Parent $AutomationRoot
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
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
    public const uint GW_OWNER = 4;
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("imm32.dll")] public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
    public const int VK_SPACE = 0x20;
    public const int VK_CONTROL = 0x11;
    public const uint WM_IME_CONTROL = 0x0283;
    public const int IMC_SETOPENSTATUS = 0x0006;
}
"@

# 用 Win32 EnumWindows 枚举可见顶层窗口（含“被拥有窗口/owned window”）。
# 验证码弹窗“请输入验证码”是主窗口的被拥有窗口，UI Automation 的 RootElement 子节点枚举会漏掉它，
# 但 EnumWindows 能枚举到，用于可靠检测验证码弹窗是否打开。
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class WinEnum {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
    public static string[] GetTopLevelTitles() {
        var list = new List<string>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len <= 0) return true;
            var sb = new StringBuilder(len + 2);
            GetWindowText(h, sb, sb.Capacity);
            string t = sb.ToString();
            if (!string.IsNullOrEmpty(t)) list.Add(t);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
"@

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public static class CapturePauseSignal {
    static int _toggleRequested;
    public static void RequestToggle() {
        Interlocked.Exchange(ref _toggleRequested, 1);
    }
    public static bool ConsumeToggleRequest() {
        return Interlocked.Exchange(ref _toggleRequested, 0) == 1;
    }
}

public class GlobalPauseHotkeyForm : Form {
    const int WM_HOTKEY = 0x0312;
    const int HotkeyId = 0x4CA1;
    const uint ModControl = 0x0002;
    const uint ModNoRepeat = 0x4000;
    const uint VkSpace = 0x20;

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        RegisterHotKey(Handle, HotkeyId, ModControl | ModNoRepeat, VkSpace);
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        UnregisterHotKey(Handle, HotkeyId);
        base.OnFormClosed(e);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HotkeyId) {
            CapturePauseSignal.RequestToggle();
            return;
        }
        base.WndProc(ref m);
    }

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x80;
            return cp;
        }
    }
}

public static class GlobalPauseHotkeyHost {
    static Thread _thread;
    static GlobalPauseHotkeyForm _form;
    static volatile bool _started;

    public static bool Start() {
        if (_started) { return true; }
        _thread = new Thread(() => {
            Application.EnableVisualStyles();
            _form = new GlobalPauseHotkeyForm();
            _form.ShowInTaskbar = false;
            _form.FormBorderStyle = FormBorderStyle.FixedToolWindow;
            _form.StartPosition = FormStartPosition.Manual;
            _form.Location = new Point(-32000, -32000);
            _form.Size = new Size(1, 1);
            _form.Opacity = 0;
            Application.Run(_form);
        });
        _thread.IsBackground = true;
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        for (int i = 0; i < 100; i++) {
            if (_form != null && _form.IsHandleCreated) {
                _started = true;
                return true;
            }
            Thread.Sleep(20);
        }
        return false;
    }

    public static void Stop() {
        if (!_started) { return; }
        try {
            if (_form != null && _form.IsHandleCreated) {
                _form.Invoke(new Action(() => {
                    _form.Close();
                    Application.ExitThread();
                }));
            }
        }
        catch { }
        _started = false;
        _form = null;
        _thread = null;
    }
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
    foreach ($extra in @($builtin, '电子化注册', '机构版')) {
        if (-not $patterns.Contains($extra)) { $patterns.Add($extra) }
    }
    return $patterns
}

function Test-MatchesMainWindowTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    foreach ($pattern in (Get-MainWindowTitlePatterns -UserPattern $MainWindowTitleRegex)) {
        if ($Title -match $pattern) { return $true }
    }
    return $false
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
        Write-Step 'Close the admin window and run: .\cmd\automation\capture.cmd'
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

function Set-ImeEnglishForForeground {
    <#
        把当前前台窗口的输入法切到英文（关闭 IME 开启状态）。
        中文输入法激活时，SendKeys 合成的 ^a / {DEL} / ^v 会被 IME 拦截而无法送进输入框。
        通过向目标线程的默认 IME 窗口发送 WM_IME_CONTROL(IMC_SETOPENSTATUS, 0) 关闭输入法，
        该方式可跨进程生效。失败仅告警，不中断流程。
    #>
    try {
        $hwnd = [NativeWin32]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $ime = [NativeWin32]::ImmGetDefaultIMEWnd($hwnd)
        if ($ime -eq [IntPtr]::Zero) { return }
        [NativeWin32]::SendMessage(
            $ime,
            [NativeWin32]::WM_IME_CONTROL,
            [IntPtr][NativeWin32]::IMC_SETOPENSTATUS,
            [IntPtr]0) | Out-Null
    }
    catch {
        Write-Step ("Warning: 切换输入法到英文失败：{0}" -f $_.Exception.Message)
    }
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

function Move-CursorAway {
    <#
        把鼠标移到一个中性空白位置，避免停留在按钮上触发软件的悬停提示浮窗。
        优先依据主窗口计算列表空白区域，失败则退回主屏左下角。
    #>
    param([System.Windows.Automation.AutomationElement]$MainWindow = $null)

    $x = $null; $y = $null
    try {
        if ($null -ne $MainWindow) {
            $rect = $MainWindow.Current.BoundingRectangle
            if ($null -ne $rect -and $rect.Width -gt 0 -and $rect.Height -gt 0 `
                    -and -not [double]::IsInfinity($rect.Width)) {
                # 列表左下方空白处：远离顶部工具栏按钮，也避开居中的验证码弹窗
                $x = [int]($rect.Left + 30)
                $y = [int]($rect.Top + ($rect.Height * 0.85))
            }
        }
    }
    catch { $x = $null; $y = $null }

    if ($null -eq $x -or $null -eq $y) {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = [int]($screen.Left + 20)
        $y = [int]($screen.Top + $screen.Height - 60)
    }

    try {
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
    }
    catch { }
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

$script:DoctorAppExeName = '医师电子化注册信息系统（机构版）.exe'

function Expand-AppPathCandidate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if ($Path -match '\.lnk$') {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $target = [string]$shell.CreateShortcut($Path).TargetPath
            if (-not [string]::IsNullOrWhiteSpace($target) -and (Test-Path -LiteralPath $target)) {
                return $target
            }
        }
        catch { }
        return $null
    }
    return $Path
}

function Get-DoctorAppPathFromRunningProcess {
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $title = [string]$proc.MainWindowTitle
            if ([string]::IsNullOrWhiteSpace($title)) { continue }
            if ($title -notmatch $LoginWindowTitleRegex -and -not (Test-MatchesMainWindowTitle $title)) { continue }

            $path = Expand-AppPathCandidate -Path ([string]$proc.Path)
            if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }

            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $proc.Id) -ErrorAction SilentlyContinue
            $path = Expand-AppPathCandidate -Path ([string]$cim.ExecutablePath)
            if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
        }
        catch { }
    }

    $procName = [IO.Path]::GetFileNameWithoutExtension($script:DoctorAppExeName)
    foreach ($proc in (Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
        try {
            $path = Expand-AppPathCandidate -Path ([string]$proc.Path)
            if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }

            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $proc.Id) -ErrorAction SilentlyContinue
            $path = Expand-AppPathCandidate -Path ([string]$cim.ExecutablePath)
            if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
        }
        catch { }
    }
    return $null
}

function Find-DoctorAppPathFromShortcuts {
    $shell = New-Object -ComObject WScript.Shell
    $shortcutRoots = @(
        [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonPrograms'),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($root in $shortcutRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $links = Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$($script:DoctorAppExeName)*" -or $_.Name -like '*医师电子化注册*' }
        foreach ($link in $links) {
            try {
                $target = [string]$shell.CreateShortcut($link.FullName).TargetPath
                $path = Expand-AppPathCandidate -Path $target
                if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
            }
            catch { }
        }
    }
    return $null
}

function Find-DoctorAppPathOnDrives {
    $relativePaths = @(
        "医师电子化注册信息系统（机构版）\$($script:DoctorAppExeName)",
        "北京民科医疗科技有限公司\医师电子化注册信息系统（机构版）\$($script:DoctorAppExeName)"
    )
    $drives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' }
    foreach ($drive in $drives) {
        $root = $drive.RootDirectory.FullName
        foreach ($rel in $relativePaths) {
            $candidate = Join-Path $root $rel
            $path = Expand-AppPathCandidate -Path $candidate
            if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
        }

        try {
            $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*医师电子化注册*' }
            foreach ($dir in $dirs) {
                $candidate = Join-Path $dir.FullName $script:DoctorAppExeName
                $path = Expand-AppPathCandidate -Path $candidate
                if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }

                $nested = Join-Path $dir.FullName "医师电子化注册信息系统（机构版）\$($script:DoctorAppExeName)"
                $path = Expand-AppPathCandidate -Path $nested
                if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
            }
        }
        catch { }
    }
    return $null
}

function Resolve-DoctorAppPath {
    if (-not [string]::IsNullOrWhiteSpace($script:AppPath)) {
        $existing = Expand-AppPathCandidate -Path $script:AppPath
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            if ($existing -ne $script:AppPath) {
                Write-Step ("解析 appPath 快捷方式：{0}" -f $existing)
            }
            $script:AppPath = $existing
            return $existing
        }
        Write-Step ("配置的 appPath 不存在，将自动查找：{0}" -f $script:AppPath)
    }

    $finders = @(
        @{ Name = '运行中的进程'; Action = { Get-DoctorAppPathFromRunningProcess } },
        @{ Name = '开始菜单/桌面快捷方式'; Action = { Find-DoctorAppPathFromShortcuts } },
        @{ Name = '常见安装目录'; Action = { Find-DoctorAppPathOnDrives } }
    )
    foreach ($finder in $finders) {
        $found = & $finder.Action
        if (-not [string]::IsNullOrWhiteSpace($found)) {
            Write-Step ("自动找到应用（{0}）：{1}" -f $finder.Name, $found)
            $script:AppPath = $found
            return $found
        }
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
    Resolve-DoctorAppPath | Out-Null

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

function Convert-OcrTokenToIdCard {
    # 把一段疑似身份证号的 OCR 文本（可能夹杂被误读为字母的数字）纠正为标准身份证号。
    # 仅当能整理出 15 位或 18 位（18 位末尾可为 X）时返回，否则返回 $null。
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }

    $chars = $Token.ToUpperInvariant().ToCharArray()
    $map = @{
        'O' = '0'; 'Q' = '0'; 'D' = '0';
        'I' = '1'; 'L' = '1'; '|' = '1'; '!' = '1';
        'Z' = '2';
        'A' = '4';
        'S' = '5';
        'G' = '6';
        'T' = '7';
        'B' = '8';
        'X' = 'X'
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $chars) {
        $c = [string]$ch
        if ($c -match '\d') {
            [void]$sb.Append($c)
        }
        elseif ($map.ContainsKey($c)) {
            [void]$sb.Append($map[$c])
        }
        # 其它字符（中文、空格、标点等）作为分隔符忽略。
    }
    $cleaned = $sb.ToString()

    # 末位若为 X，仅当整体长度为 18 时才合法（18 位身份证校验位可为 X）。
    if ($cleaned.Length -eq 18 -and $cleaned -match '^\d{17}[\dX]$') {
        return $cleaned
    }
    if ($cleaned.Length -eq 15 -and $cleaned -match '^\d{15}$') {
        return $cleaned
    }
    # 长度偏长时尝试截取标签后紧邻的合法前缀（应对把后一字段数字粘连进来的情况）。
    if ($cleaned.Length -gt 18) {
        $m = [regex]::Match($cleaned, '^\d{17}[\dX]')
        if ($m.Success) { return $m.Value }
        $m15 = [regex]::Match($cleaned, '^\d{15}')
        if ($m15.Success) { return $m15.Value }
    }
    return $null
}

function Get-IdCardFromOcrText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $compact = ($Text -replace '\s+', '')

    # 1) 优先：以“身份证(号/号码)”标签锚定，截取其后一段字母数字串再纠错。
    #    号码后面通常紧跟中文字段（执业信息/医师照片等），故以非字母数字为边界。
    $labelMatch = [regex]::Match($compact, '身份证(?:号码|号|證)?[:：]?\s*([0-9A-Za-z|!]{14,25})')
    if ($labelMatch.Success) {
        $id = Convert-OcrTokenToIdCard -Token $labelMatch.Groups[1].Value
        if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }
    }

    # 2) 回退：在去空格文本中查找任意“独立”的 18/15 位号码（前后不接数字/X，避免命中资格证书编号子串）。
    $idMatches = [regex]::Matches($compact, '(?<![\dXx])(?:\d{17}[\dXx]|\d{15})(?![\dXx])')
    if ($idMatches.Count -gt 0) {
        $eighteen = @($idMatches | ForEach-Object { $_.Value } | Where-Object { $_.Length -eq 18 })
        if ($eighteen.Count -gt 0) { return $eighteen[0].ToUpperInvariant() }
        return $idMatches[0].Value.ToUpperInvariant()
    }

    # 3) 兜底：原始文本（保留空格）再扫一次，兼容罕见换行/分段情况。
    $rawMatches = [regex]::Matches($Text, '(?<![\dXx])(?:\d{17}[\dXx]|\d{15})(?![\dXx])')
    if ($rawMatches.Count -gt 0) {
        $eighteen = @($rawMatches | ForEach-Object { $_.Value } | Where-Object { $_.Length -eq 18 })
        if ($eighteen.Count -gt 0) { return $eighteen[0].ToUpperInvariant() }
        return $rawMatches[0].Value.ToUpperInvariant()
    }

    return $null
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

    $idCard = Get-IdCardFromOcrText -Text $Text

    $digits = @([regex]::Matches($Text, '\d+') | ForEach-Object { $_.Value })
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

function Test-LoadingText {
    # 判断 OCR 文本中是否仍存在“正在查询/请稍后/加载中”等加载提示。
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '正在查询|正在加载|加载中|请稍[后候]|数据加载|获取最新数据|正在获取|loading|Loading')
}

function Wait-DetailContentReady {
    <#
        等待详情窗口内容渲染完成再返回，避免截到“正在查询，请稍后...”的加载层。
        策略：
          1) 画面哈希稳定（连续两帧一致）——加载动画播放时帧会变化，加载完成后趋于静止；
          2) 启用 OCR 时再确认文本中不含加载提示，且已识别到身份证号。
        返回： @{ Bitmap = <stable bitmap>; OcrText = <ocr text or $null> }
        调用方负责 Dispose 返回的 Bitmap。
    #>
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [int]$TimeoutSeconds = 12
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $prevHash = ''
    $stableCount = 0
    $lastBitmap = $null
    $lastOcrText = $null

    while ((Get-Date) -lt $deadline) {
        Wait-IfPauseRequested

        $bmp = Capture-WindowBitmap -Window $Window
        $hash = Get-BitmapHash -Bitmap $bmp

        if ($hash -eq $prevHash) { $stableCount++ }
        else { $stableCount = 0; $prevHash = $hash }

        if ($null -ne $lastBitmap) { $lastBitmap.Dispose() }
        $lastBitmap = $bmp
        $lastOcrText = $null

        if ($stableCount -ge 1) {
            if ($NoOcr) {
                # 未启用 OCR：仅以画面静止为准。
                return @{ Bitmap = $lastBitmap; OcrText = $null }
            }

            $lastOcrText = Get-OcrTextFromBitmap -Bitmap $lastBitmap
            if (-not (Test-LoadingText -Text $lastOcrText)) {
                $id = Get-IdCardFromOcrText -Text $lastOcrText
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    # 内容已加载且能读到身份证号，视为渲染完成。
                    return @{ Bitmap = $lastBitmap; OcrText = $lastOcrText }
                }
            }
        }

        Start-SleepWithPause -Milliseconds 350
    }

    # 超时：返回当前最后一帧（可能仍含加载层），由上层按未识别处理。
    return @{ Bitmap = $lastBitmap; OcrText = $lastOcrText }
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
        Wait-IfPauseRequested
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
    Write-Step '现在可以运行： .\\cmd\\automation\\capture.cmd'
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
    Write-FocusDiagnostics -Tag '姓名框点击后'
    Set-ImeEnglishForForeground
    Start-Sleep -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
    Start-Sleep -Milliseconds 60
    Set-Clipboard -Value $Name
    Start-Sleep -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 150

    # 写入后回读校验：能读到值且为空 => 写入失败，按要求立即停止
    $entered = Get-FocusedElementValue
    if ($null -ne $entered) {
        Write-Step ("  [诊断] 姓名框回读值='{0}'" -f $entered)
        if ([string]::IsNullOrEmpty($entered)) {
            Write-FocusDiagnostics -Tag '姓名写入失败'
            throw ("姓名搜索框未能写入内容（回读为空），已立即停止以便排查。姓名='{0}'。请把以上 [诊断:...] 日志发我。" -f $Name)
        }
    }

    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
}

function Invoke-CaptureBatchRest {
    param([int]$TotalSaved)
    if ($CaptureRestInterval -le 0 -or $CaptureRestMinutes -le 0) { return }
    if ($TotalSaved % $CaptureRestInterval -ne 0) { return }

    $restSeconds = $CaptureRestMinutes * 60
    Write-CaptureState -Stage 'Rest' -Message ("已抓取 {0} 次，休息 {1} 分钟" -f $TotalSaved, $CaptureRestMinutes)
    Write-Step ("已累计成功截图 {0} 张，休息 {1} 分钟..." -f $TotalSaved, $CaptureRestMinutes)
    Start-SleepSecondsWithPause -Seconds $restSeconds
    Write-Step '休息结束，继续抓取。'
}

$script:NeedRestart = $false
$script:ErrorPopupCount = 0
$script:LastErrorPopupTime = $null
$script:CapturedSinceLastPopup = 0
$script:ErrorPopupStatsReady = $false
$script:IsCapturePaused = $false
$script:IsForegroundPaused = $false
$script:ForegroundPauseAnnounced = $false
$script:PauseWhenAppNotForeground = $true
$script:LastCtrlSpaceDown = $false
$script:GlobalPauseHotkeyStarted = $false
$script:ExportDebugTiming = (-not [string]::IsNullOrWhiteSpace($env:EXPORT_DEBUG_TIMING))

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
    param([int]$PostWaitSeconds = 1)

    Write-Step '关闭医师系统应用...'
    $killed = 0
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $t = $proc.MainWindowTitle
            if (-not [string]::IsNullOrWhiteSpace($t) -and ((Test-MatchesMainWindowTitle $t) -or $t -match $LoginWindowTitleRegex)) {
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
    if ($PostWaitSeconds -gt 0) {
        Start-Sleep -Seconds $PostWaitSeconds
    }
}

function Restart-DoctorAndEnterList {
    Resolve-DoctorAppPath | Out-Null
    if ([string]::IsNullOrWhiteSpace($AppPath)) {
        throw '未找到医师系统应用路径，无法自动重启。请先手动打开应用，或在 config.json 设置 appPath。'
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

function Test-CtrlSpaceKeyEdge {
    try {
        $ctrlDown = ([NativeWin32]::GetAsyncKeyState([NativeWin32]::VK_CONTROL) -band 0x8000) -ne 0
        $spaceDown = ([NativeWin32]::GetAsyncKeyState([NativeWin32]::VK_SPACE) -band 0x8000) -ne 0
        $comboDown = $ctrlDown -and $spaceDown
    }
    catch {
        return $false
    }
    $edge = $comboDown -and (-not $script:LastCtrlSpaceDown)
    $script:LastCtrlSpaceDown = $comboDown
    return $edge
}

function Read-CtrlSpaceFromConsoleBuffer {
    $pressed = $false
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Spacebar' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
            $pressed = $true
        }
    }
    return $pressed
}

function Start-GlobalPauseHotkey {
    if ($script:GlobalPauseHotkeyStarted) { return $true }
    try {
        $ok = [GlobalPauseHotkeyHost]::Start()
        if ($ok) {
            $script:GlobalPauseHotkeyStarted = $true
            return $true
        }
        Write-Step '全局 Ctrl+空格 热键注册失败，将仅使用键盘轮询作为备用。'
        return $false
    }
    catch {
        Write-Step ("全局 Ctrl+空格 热键启动失败：{0}" -f $_.Exception.Message)
        return $false
    }
}

function Stop-GlobalPauseHotkey {
    if (-not $script:GlobalPauseHotkeyStarted) { return }
    try {
        [GlobalPauseHotkeyHost]::Stop()
    }
    catch { }
    finally {
        $script:GlobalPauseHotkeyStarted = $false
        [CapturePauseSignal]::ConsumeToggleRequest() | Out-Null
    }
}

function Test-PauseToggleRequested {
    if ([CapturePauseSignal]::ConsumeToggleRequest()) { return $true }
    if (Read-CtrlSpaceFromConsoleBuffer) { return $true }
    if (Test-CtrlSpaceKeyEdge) { return $true }
    return $false
}

function Get-DoctorAppProcessIds {
    $ids = @{}
    $procName = [IO.Path]::GetFileNameWithoutExtension($script:DoctorAppExeName)
    foreach ($proc in (Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
        $ids[[int]$proc.Id] = $true
    }
    foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $title = [string]$proc.MainWindowTitle
            if ([string]::IsNullOrWhiteSpace($title)) { continue }
            if (-not (Test-MatchesMainWindowTitle $title) -and $title -notmatch $LoginWindowTitleRegex -and $title -notmatch $DetailWindowTitleRegex) { continue }
            $ids[[int]$proc.Id] = $true
        }
        catch { }
    }
    return $ids
}

function Get-WindowProcessId {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return 0 }
    $procId = [uint32]0
    [void][NativeWin32]::GetWindowThreadProcessId($Hwnd, [ref]$procId)
    return [int]$procId
}

function Get-WindowTitleText {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return '' }
    $sb = New-Object System.Text.StringBuilder 512
    [void][NativeWin32]::GetWindowText($Hwnd, $sb, $sb.Capacity)
    return [string]$sb
}

function Test-DoctorAppWindowTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    if (Test-MatchesMainWindowTitle $Title) { return $true }
    if ($Title -match $LoginWindowTitleRegex) { return $true }
    if ($Title -match $DetailWindowTitleRegex) { return $true }
    if ($Title -match '验证码|另存为|保存|导出') { return $true }
    return $false
}

function Test-WindowBelongsToDoctorApp {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return $false }

    $appPids = Get-DoctorAppProcessIds
    $visited = @{}
    $current = $Hwnd
    while ($current -ne [IntPtr]::Zero -and -not $visited.ContainsKey($current.ToInt64())) {
        $visited[$current.ToInt64()] = $true
        $procId = Get-WindowProcessId -Hwnd $current
        if ($procId -gt 0 -and $appPids.ContainsKey($procId)) { return $true }
        $title = Get-WindowTitleText -Hwnd $current
        if (Test-DoctorAppWindowTitle -Title $title) { return $true }
        $current = [NativeWin32]::GetWindow($current, [NativeWin32]::GW_OWNER)
    }
    return $false
}

function Test-DoctorAppInForeground {
    $fg = [NativeWin32]::GetForegroundWindow()
    return Test-WindowBelongsToDoctorApp -Hwnd $fg
}

function Update-ForegroundPauseState {
    if (-not $script:PauseWhenAppNotForeground) { return }

    if (Test-DoctorAppInForeground) {
        if ($script:IsForegroundPaused) {
            $script:IsForegroundPaused = $false
            $script:ForegroundPauseAnnounced = $false
            Write-Step '机构端已回到前台，自动恢复运行。'
        }
        return
    }

    if (-not $script:IsForegroundPaused) {
        $script:IsForegroundPaused = $true
        if (-not $script:ForegroundPauseAnnounced) {
            Write-Step '机构端不在前台，已自动暂停（切回机构端窗口后将自动继续）。'
            $script:ForegroundPauseAnnounced = $true
        }
    }
}

function Wait-IfPauseRequested {
    try {
        if (Test-PauseToggleRequested) {
            $script:IsCapturePaused = -not $script:IsCapturePaused
            if (-not $script:IsCapturePaused) {
                $script:ForegroundPauseAnnounced = $false
            }
        }

        Update-ForegroundPauseState

        if (-not $script:IsCapturePaused -and -not $script:IsForegroundPaused) { return }

        if ($script:IsCapturePaused -and -not $script:IsForegroundPaused) {
            Write-Step '已暂停（按【Ctrl+空格】继续，无需切换回控制台）...'
        }

        $wasManualPause = [bool]$script:IsCapturePaused
        while ($script:IsCapturePaused -or $script:IsForegroundPaused) {
            Start-Sleep -Milliseconds 150
            if (Test-PauseToggleRequested) {
                $script:IsCapturePaused = -not $script:IsCapturePaused
                if (-not $script:IsCapturePaused) {
                    $script:ForegroundPauseAnnounced = $false
                }
            }
            Update-ForegroundPauseState
        }

        if ($wasManualPause -and -not $script:IsCapturePaused) {
            Write-Step '已恢复运行。'
        }
    }
    catch {
        # 控制台不可交互（如输入被重定向）时忽略暂停功能。
    }
}

function Start-SleepWithPause {
    param([int]$Milliseconds)
    if ($Milliseconds -le 0) { return }
    $deadline = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $deadline) {
        Wait-IfPauseRequested
        $remainingMs = [int](($deadline - (Get-Date)).TotalMilliseconds)
        if ($remainingMs -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min(150, $remainingMs))
    }
}

function Start-SleepSecondsWithPause {
    param([double]$Seconds)
    Start-SleepWithPause -Milliseconds ([int]([Math]::Max(0, $Seconds * 1000)))
}

function Initialize-PauseHotkey {
    param([switch]$DeferGlobalHotkey)

    $script:IsCapturePaused = $false
    $script:IsForegroundPaused = $false
    $script:ForegroundPauseAnnounced = $false
    $script:PauseWhenAppNotForeground = -not $DisableForegroundPause.IsPresent
    try {
        $ctrlDown = ([NativeWin32]::GetAsyncKeyState([NativeWin32]::VK_CONTROL) -band 0x8000) -ne 0
        $spaceDown = ([NativeWin32]::GetAsyncKeyState([NativeWin32]::VK_SPACE) -band 0x8000) -ne 0
        $script:LastCtrlSpaceDown = $ctrlDown -and $spaceDown
    }
    catch {
        $script:LastCtrlSpaceDown = $false
    }
    [CapturePauseSignal]::ConsumeToggleRequest() | Out-Null
    if (-not $DeferGlobalHotkey) {
        Start-GlobalPauseHotkey | Out-Null
        Write-Step '提示：运行中随时按【Ctrl+空格】暂停/恢复（全局热键，控制台被遮挡也有效）。'
    }
    else {
        Write-Step '提示：运行中随时按【Ctrl+空格】暂停/恢复（按键轮询，焦点在医师系统时最稳）。'
    }
    if ($script:PauseWhenAppNotForeground) {
        Write-Step '提示：机构端窗口不在前台时将自动暂停，切回机构端后自动继续。'
    }
}

function Enable-GlobalPauseHotkey {
    if ($script:GlobalPauseHotkeyStarted) { return }
    Start-GlobalPauseHotkey | Out-Null
}

function Capture-NameSeries {
    Initialize-PauseHotkey
    try {
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
        Write-Step ("未找到有效列表坐标，请在 config.json 的 listCalibration 中配置，或运行 cmd\automation\calibrate.cmd。")
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
        Start-SleepSecondsWithPause -Seconds $SearchWaitSeconds

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
                Start-SleepSecondsWithPause -Seconds 1
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
                $ready = Wait-DetailContentReady -Window $detail -TimeoutSeconds $DetailWaitSeconds
                $bitmap = $ready.Bitmap
                $readyOcrText = $ready.OcrText
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
                            Wait-IfPauseRequested
                            if ($null -ne $readyOcrText) { $ocrText = $readyOcrText }
                            else { $ocrText = Get-OcrTextFromBitmap -Bitmap $bitmap }
                            if (Test-LoadingText -Text $ocrText) {
                                Write-Step ("  第 {0} 行仍处于加载中（正在查询/请稍后），跳过以避免截到加载弹窗。" -f ($row + 1))
                                $ocrIdCard = $null
                            }
                            else {
                                Wait-IfPauseRequested
                                $fields = Get-DetailFieldsFromOcrText -Text $ocrText
                                $ocrIdCard = $fields.IdCard
                            }
                        }

                        if (-not $NoOcr) {
                            if ([string]::IsNullOrWhiteSpace($ocrIdCard)) {
                                $isUnmatched = $true
                                Write-Step ("  第 {0} 行未识别到身份证号，跳过。" -f ($row + 1))
                            }
                            else {
                                $normOcrId = Normalize-IdCard $ocrIdCard
                                if ($seenOcrIdCards.ContainsKey($normOcrId)) {
                                    $stopCurrentName = $true
                                    Write-Step ("  第 {0} 行再次出现身份证 {1}，判定列表无更多新结果，结束该姓名。" -f ($row + 1), $normOcrId)
                                }
                                else {
                                    $seenOcrIdCards[$normOcrId] = $true
                                    $targetPerson = Find-PersonByOcrIdCard -Candidates $remaining.ToArray() -OcrIdCard $ocrIdCard
                                    if ($null -eq $targetPerson) {
                                        $isUnmatched = $true
                                        Write-Step ("  第 {0} 行身份证 {1} 不在待抓取名单，跳过。" -f ($row + 1), $normOcrId)
                                        $capturedProbe = [pscustomobject]@{ Name = $searchName; IdCard = $normOcrId }
                                        if ($remaining.Count -eq 1 -and (Test-PersonAlreadyCaptured -Person $capturedProbe)) {
                                            $stopCurrentName = $true
                                            $pendingId = Normalize-IdCard $remaining[0].IdCard
                                            Write-Step ("  搜索结果为已截图人员；待抓取的 {0} 未出现在列表中，结束该姓名。" -f $pendingId)
                                        }
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
                Start-SleepWithPause -Milliseconds 250
                Bring-ToFront $main
                Start-SleepWithPause -Milliseconds 150
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
    finally {
        Stop-GlobalPauseHotkey
    }
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
    Resolve-DoctorAppPath | Out-Null
    if ([string]::IsNullOrWhiteSpace($AppPath)) {
        Write-Step '未找到 appPath，将使用当前已打开的医师系统窗口。'
        return
    }
    if (-not (Test-Path -LiteralPath $AppPath)) {
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

function Get-FocusedElementValue {
    <#
        读取当前焦点元素的文本值（仅当其支持 ValuePattern 时）。
        返回 $null 表示无法判定（控件不支持或读取失败），调用方应跳过校验而非当作失败。
    #>
    try {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused) { return $null }
        $pattern = $null
        $ok = $focused.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)
        if ($ok -and $null -ne $pattern) {
            return $pattern.Current.Value
        }
    }
    catch { }
    return $null
}

function Write-FocusDiagnostics {
    <#
        打印当前前台窗口句柄与焦点元素信息（类型/类名/是否有键盘焦点/当前值），
        用于定位“点了输入框但没输入内容”的真因。
    #>
    param([string]$Tag)
    try {
        $fg = [NativeWin32]::GetForegroundWindow()
        $f = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $f) {
            $vp = $null
            $val = '<不支持ValuePattern>'
            if ($f.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
                $val = ("'{0}'" -f $vp.Current.Value)
            }
            Write-Step ("  [诊断:{0}] 前台hwnd={1} 焦点元素 Type={2} Class='{3}' hasFocus={4} 当前值={5}" -f `
                $Tag, $fg, $f.Current.ControlType.ProgrammaticName, $f.Current.ClassName, $f.Current.HasKeyboardFocus, $val)
        }
        else {
            Write-Step ("  [诊断:{0}] 前台hwnd={1} 焦点元素=<null>" -f $Tag, $fg)
        }
    }
    catch { Write-Step ("  [诊断:{0}] 读取诊断信息失败：{1}" -f $Tag, $_.Exception.Message) }
}

function Invoke-ClickAndPasteText {
    <#
        点击坐标并粘贴文本。返回值：
          $true  —— 写入成功（回读非空），或控件不支持回读（无法判定，按成功处理）。
          $false —— 控件支持回读但回读为空（确认写入失败）。
        -LogSteps 打印每一步与焦点诊断。
    #>
    param(
        [int]$X,
        [int]$Y,
        [string]$Text,
        [System.Windows.Automation.AutomationElement]$FocusWindow = $null,
        [switch]$ClearClipboardAfterPaste,
        [switch]$LogSteps
    )
    Invoke-ScreenClick -X $X -Y $Y -FocusWindow $FocusWindow
    Start-Sleep -Milliseconds 150
    if ($LogSteps) { Write-FocusDiagnostics -Tag '点击输入框后' }

    $result = $true
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($LogSteps) { Write-Step ("  第{0}次尝试：关IME -> ^a -> DEL -> Set-Clipboard -> ^v" -f $attempt) }
        Set-ImeEnglishForForeground
        Start-Sleep -Milliseconds 60
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        Start-Sleep -Milliseconds 80
        [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
        Start-Sleep -Milliseconds 80
        Set-Clipboard -Value $Text
        if ($LogSteps) {
            try { Write-Step ("    剪贴板回读='{0}'" -f (Get-Clipboard -Raw)) } catch { }
        }
        Start-Sleep -Milliseconds 80
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Start-Sleep -Milliseconds 120

        # 仅当焦点控件支持 ValuePattern 时才校验；为空且还能重试则再来一次。
        $current = Get-FocusedElementValue
        if ($LogSteps) {
            $shown = if ($null -eq $current) { '<无法回读>' } else { ("'{0}'" -f $current) }
            Write-Step ("    粘贴后回读输入框值={0}" -f $shown)
        }
        if ($null -eq $current) { $result = $true; break }
        if (-not [string]::IsNullOrEmpty($current)) { $result = $true; break }
        $result = $false
        if ($attempt -lt 2) {
            Write-Step '  Warning: 粘贴后输入框仍为空，重试一次。'
            Invoke-ScreenClick -X $X -Y $Y -FocusWindow $FocusWindow
            Start-Sleep -Milliseconds 150
        }
    }

    if ($ClearClipboardAfterPaste) {
        Clear-ClipboardSafe
    }
    return $result
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
        Write-Step ("未找到有效登录坐标，请在 config.json 的 loginCalibration 中配置，或运行 cmd\automation\calibrate.cmd。")
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
    Invoke-ClickAndPasteText -X ([int]$loginCfg.UserX) -Y ([int]$loginCfg.UserY) -Text $LoginUserValue -FocusWindow $loginWin | Out-Null

    Write-Step '输入密码。'
    try {
        Invoke-ClickAndPasteText -X ([int]$loginCfg.PasswordX) -Y ([int]$loginCfg.PasswordY) -Text $plainPassword -FocusWindow $loginWin -ClearClipboardAfterPaste | Out-Null
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
        Write-Step ("未找到有效登录坐标，请在 config.json 的 loginCalibration 中配置，或运行 cmd\automation\calibrate.cmd。")
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
            throw '未找到【外院在本院多执业医师】入口坐标。请先运行 cmd\automation\calibrate.cmd 完成第6步坐标校准。'
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

#region 数据导出自动化

function Get-ExportCalibration {
    param([switch]$RequireMulti)

    $cfg = Get-AppConfig
    if ($null -eq $cfg) { return $null }

    $section = Get-ConfigProperty -Config $cfg -Names @('exportCalibration', 'ExportCalibration')
    if ($null -eq $section) { return $null }

    if ($RequireMulti) {
        if (Test-ConfigSection -Section $section -RequiredFields @('MultiExportX', 'MultiExportY')) {
            $mx = Get-SectionInt -Section $section -FieldName 'MultiExportX'
            $my = Get-SectionInt -Section $section -FieldName 'MultiExportY'
            if ($mx -gt 0 -and $my -gt 0) { return $section }
        }
        return $null
    }

    if (Test-ConfigSection -Section $section -RequiredFields @(
            'GetLatestX', 'GetLatestY',
            'CaptchaImgLeft', 'CaptchaImgTop', 'CaptchaImgRight', 'CaptchaImgBottom',
            'CaptchaInputX', 'CaptchaInputY',
            'ConfirmX', 'ConfirmY',
            'RefreshCaptchaX', 'RefreshCaptchaY',
            'ExportX', 'ExportY')) {
        return $section
    }
    return $null
}

function Save-ScreenRectPng {
    param(
        [int]$Left,
        [int]$Top,
        [int]$Right,
        [int]$Bottom,
        [string]$Path
    )

    $left = [Math]::Min($Left, $Right)
    $top = [Math]::Min($Top, $Bottom)
    $width = [Math]::Abs($Right - $Left)
    $height = [Math]::Abs($Bottom - $Top)
    if ($width -lt 4 -or $height -lt 4) {
        throw "Screenshot rectangle is too small: ($Left,$Top)-($Right,$Bottom)"
    }

    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($width, $height)))
        $dir = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$script:CaptchaOcrProcess = $null
$script:CaptchaOcrWriter = $null
$script:CaptchaOcrReader = $null
$script:ExportCaptchaEmptyStreak = 0
$script:ExportHardFailureEmptyOcrThreshold = 3

#region ExportStateProbe — 导出流程 UI/Win32 状态探测（不依赖状态 OCR）

function Get-ForegroundWindowTitle {
    try {
        $h = [NativeWin32]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return '' }
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        if ($null -ne $el) { return [string]$el.Current.Name }
    }
    catch { }
    return ''
}

function Test-ExportSaveDialogPresent {
    if ($null -ne (Find-WindowByAnyTitle -TitleRegex '导出数据至Excel|另存为|Save As')) { return $true }
    return (Test-NativeWindowTitleMatch -TitleRegex '导出数据至Excel|另存为|Save As')
}

function Test-ExportCaptchaWindowPresent {
    return (Test-CaptchaPresentFast)
}

function Get-FocusedEditValueSafe {
    return (Get-FocusedElementValue)
}

function Get-ExportProbeSnapshot {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow = $null,
        $ExportCfg = $null
    )
    if ($null -eq $MainWindow) {
        $MainWindow = Find-MainApplicationWindow $MainWindowTitleRegex
    }

    $focusedType = ''
    $focusedClass = ''
    $focusedValue = $null
    try {
        $f = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $f) {
            $focusedType = [string]$f.Current.ControlType.ProgrammaticName
            $focusedClass = [string]$f.Current.ClassName
            $focusedValue = Get-FocusedEditValueSafe
        }
    }
    catch { }

    $tableVisible = $false
    if ($null -ne $MainWindow) {
        try {
            $tr = Find-TablePaneRect $MainWindow
            $tableVisible = ($null -ne $tr -and $tr.Width -gt 200 -and $tr.Height -gt 100)
        }
        catch { }
    }

    return [pscustomobject]@{
        ForegroundTitle   = Get-ForegroundWindowTitle
        MainWindowTitle   = if ($null -ne $MainWindow) { [string]$MainWindow.Current.Name } else { '' }
        MainWindowPresent = ($null -ne $MainWindow)
        CaptchaPresent    = (Test-ExportCaptchaWindowPresent)
        SaveDialogPresent = (Test-ExportSaveDialogPresent)
        TableVisible      = $tableVisible
        FocusedType       = $focusedType
        FocusedClass      = $focusedClass
        FocusedValue      = $focusedValue
    }
}

function Write-ExportProbeDiagnostics {
    param(
        [string]$Tag,
        $Snapshot = $null
    )
    if ($null -eq $Snapshot) {
        $Snapshot = Get-ExportProbeSnapshot
    }
    $fv = if ($null -eq $Snapshot.FocusedValue) { '<无法回读>' } else { ("'{0}'" -f $Snapshot.FocusedValue) }
    Write-Step ("  [探测:{0}] 前台='{1}' 主窗={2} 验证码窗={3} 另存为={4} 表格可见={5} 焦点值={6}" -f `
        $Tag, $Snapshot.ForegroundTitle, $Snapshot.MainWindowPresent, $Snapshot.CaptchaPresent, `
        $Snapshot.SaveDialogPresent, $Snapshot.TableVisible, $fv)
}

function Reset-ExportCaptchaEmptyStreak {
    $script:ExportCaptchaEmptyStreak = 0
}

function Register-ExportCaptchaEmptyOcr {
    <#
        记录一次验证码 OCR 空结果。连续达到阈值则抛出硬故障。
    #>
    param([string]$Context = '')
    $script:ExportCaptchaEmptyStreak++
    Write-Step ("  OCR 空结果连续 {0}/{1} 次（{2}）" -f `
        $script:ExportCaptchaEmptyStreak, $script:ExportHardFailureEmptyOcrThreshold, $Context)
    if ($script:ExportCaptchaEmptyStreak -ge $script:ExportHardFailureEmptyOcrThreshold) {
        Write-ExportProbeDiagnostics -Tag 'OCR硬故障'
        throw ("验证码 OCR 连续 {0} 次返回空结果，判定为硬故障并已停止。请检查 .venv/ddddocr、logs\captcha-last.png 与验证码截图区域。" -f `
            $script:ExportHardFailureEmptyOcrThreshold)
    }
}

function Test-ExportRegionHashStable {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [int]$StableChecks = 2,
        [int]$PollMilliseconds = 350
    )
    if ($null -eq $MainWindow) { return $false }
    $rect = $MainWindow.Current.BoundingRectangle
    if ($null -eq $rect -or $rect.Width -lt 100) { return $false }
    $last = $null
    $same = 0
    for ($i = 0; $i -lt ($StableChecks + 3); $i++) {
        $hash = Get-ScreenRectHash $rect
        if ($hash -eq $last) { $same++ } else { $same = 0 }
        $last = $hash
        if ($same -ge $StableChecks) { return $true }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    return $false
}

function Invoke-OptionalExportValidation {
    <#
        导出完成后的可选粗校验：对比 API total 与导出文件行数（不参与状态机）。
        配置不完整或校验失败仅告警，不中断主流程。
    #>
    param([string]$ExportPath)

    if ([string]::IsNullOrWhiteSpace($ExportPath) -or -not (Test-Path -LiteralPath $ExportPath)) {
        Write-Step '  [校验] 跳过：导出文件不存在。'
        return
    }

    $cfg = Get-AppConfig
    $apiCfg = Get-ConfigProperty -Config $cfg -Names @('doctorApi', 'DoctorApi')
    if ($null -eq $apiCfg) {
        Write-Step '  [校验] 跳过：config.json 未配置 doctorApi。'
        return
    }
    $baseUrl = Get-ConfigProperty -Config $apiCfg -Names @('baseUrl', 'BaseUrl')
    if ([string]::IsNullOrWhiteSpace([string]$baseUrl)) {
        Write-Step '  [校验] 跳过：doctorApi.baseUrl 未配置。'
        return
    }

    $python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) {
        Write-Step '  [校验] 跳过：未找到 .venv Python。'
        return
    }

    $validator = @"
import json, sys
from pathlib import Path
root = Path(r'$ProjectRoot')
sys.path.insert(0, str(root / 'src'))
cfg = json.loads((root / 'config.json').read_text(encoding='utf-8-sig'))
api = cfg.get('doctorApi') or cfg.get('DoctorApi')
if not api:
    print('SKIP:no_api')
    sys.exit(0)
from api.doctor_medical import fetch_all_records
try:
    recs = fetch_all_records(api, max_pages=1)
    api_count = len(recs)
except Exception as e:
    print(f'WARN:api_error:{e}')
    sys.exit(0)
path = Path(r'$ExportPath')
file_bytes = path.stat().st_size if path.exists() else 0
print(f'OK:api_first_page={api_count}:file_bytes={file_bytes}')
"@

    $tempPy = Join-Path $env:TEMP ("export_validate_{0}.py" -f [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tempPy, $validator, (Get-Utf8Encoding))
        $out = & $python $tempPy 2>&1 | ForEach-Object { [string]$_ }
        $line = ($out | Select-Object -Last 1).Trim()
        if ($line -match '^OK:api_first_page=(\d+):file_bytes=(\d+)$') {
            $apiN = [int]$Matches[1]
            $fileBytes = [int]$Matches[2]
            Write-Step ("  [校验] API 首页记录数={0}，导出文件大小={1} 字节（粗校验，不参与状态机）" -f $apiN, $fileBytes)
        }
        elseif ($line -match '^WARN:') {
            Write-Step ("  [校验] API 校验告警：{0}" -f $line)
        }
        else {
            Write-Step ("  [校验] 跳过或未完成：{0}" -f ($line -join ' '))
        }
    }
    catch {
        Write-Step ("  [校验] 执行失败（已忽略）：{0}" -f $_.Exception.Message)
    }
    finally {
        if (Test-Path $tempPy) { Remove-Item $tempPy -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

function Start-CaptchaOcrServer {
    if ($null -ne $script:CaptchaOcrProcess -and -not $script:CaptchaOcrProcess.HasExited) {
        return
    }

    $python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    $ocrScript = Join-Path $AutomationRoot 'py\recognize_captcha.py'
    if (-not (Test-Path $python)) {
        throw 'OCR venv not found. Run automation\ps1\setup-ocr-env.ps1 first.'
    }
    if (-not (Test-Path $ocrScript)) {
        throw "Missing captcha OCR script: $ocrScript"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $python
    $psi.Arguments = "`"$ocrScript`" --serve"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $script:CaptchaOcrProcess = [System.Diagnostics.Process]::Start($psi)
    $script:CaptchaOcrWriter = $script:CaptchaOcrProcess.StandardInput
    $script:CaptchaOcrReader = $script:CaptchaOcrProcess.StandardOutput
    Start-Sleep -Milliseconds 300
}

function Stop-CaptchaOcrServer {
    if ($null -eq $script:CaptchaOcrProcess) { return }
    try {
        if (-not $script:CaptchaOcrProcess.HasExited) {
            $script:CaptchaOcrWriter.WriteLine('__quit__')
            $script:CaptchaOcrWriter.Flush()
            if (-not $script:CaptchaOcrProcess.WaitForExit(3000)) {
                $script:CaptchaOcrProcess.Kill()
            }
        }
    }
    catch { }
    finally {
        $script:CaptchaOcrProcess = $null
        $script:CaptchaOcrWriter = $null
        $script:CaptchaOcrReader = $null
    }
}

function Invoke-CaptchaOcrDirect {
    param([string]$ImagePath)

    $python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    $ocrScript = Join-Path $AutomationRoot 'py\recognize_captcha.py'
    $output = & $python $ocrScript $ImagePath 2>$null
    if ($null -eq $output) { return '' }
    return ([string]($output | Select-Object -Last 1)).Trim()
}

function Invoke-CaptchaOcr {
    param(
        [string]$ImagePath,
        [int]$TimeoutSeconds = 8
    )

    try {
        if ($null -ne $script:CaptchaOcrProcess -and -not $script:CaptchaOcrProcess.HasExited) {
            $script:CaptchaOcrWriter.WriteLine($ImagePath)
            $script:CaptchaOcrWriter.Flush()

            # 带超时的 ReadLine，避免 python 子进程无响应时永久阻塞
            $readTask = $script:CaptchaOcrReader.ReadLineAsync()
            if ($readTask.Wait([int]($TimeoutSeconds * 1000))) {
                $line = $readTask.Result
                if ($null -ne $line -and -not [string]::IsNullOrWhiteSpace($line)) {
                    return $line.Trim()
                }
            }
            else {
                # 子进程未在限定时间内返回：判定为不可用，重建服务
                Write-Step ("  验证码 OCR 服务 {0}s 未响应，重启服务并改用直接调用。" -f $TimeoutSeconds)
                Stop-CaptchaOcrServer
                return (Invoke-CaptchaOcrDirect -ImagePath $ImagePath)
            }
        }
    }
    catch {
        Stop-CaptchaOcrServer
    }

    return (Invoke-CaptchaOcrDirect -ImagePath $ImagePath)
}

function Save-CaptchaDebugImage {
    param([string]$SourcePath)

    if (-not (Test-Path $SourcePath)) { return }
    $debugPath = Join-Path $LogsDir 'captcha-last.png'
    try {
        Copy-Item -Path $SourcePath -Destination $debugPath -Force
    }
    catch { }
}

function Test-CaptchaCodeValid {
    param([string]$Code)
    return (-not [string]::IsNullOrWhiteSpace($Code) -and $Code -match '^[A-Z0-9]{3,8}$')
}

function Get-CaptchaCodeFromImageFile {
    param(
        [string]$ImagePath,
        [switch]$LogInvalidOcr
    )

    $code = Invoke-CaptchaOcr -ImagePath $ImagePath
    if (Test-CaptchaCodeValid -Code $code) { return $code }

    if ($LogInvalidOcr -and -not [string]::IsNullOrWhiteSpace($code)) {
        Write-Step ("  OCR 原始结果无效：{0}" -f $code)
    }
    return $null
}

function Get-CaptchaCodeFromScreen {
    param(
        $ExportCfg,
        [switch]$LogInvalidOcr
    )

    if ($null -eq $ExportCfg) { return $null }

    if ($script:ExportDebugTiming) { Write-Step '  [debug] GetCode: 查找主窗口/置前 开始' }
    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -ne $main) { Bring-ToFront $main }
    if ($script:ExportDebugTiming) { Write-Step '  [debug] GetCode: 查找主窗口/置前 结束' }

    $baseLeft = [int]$ExportCfg.CaptchaImgLeft
    $baseTop = [int]$ExportCfg.CaptchaImgTop
    $baseRight = [int]$ExportCfg.CaptchaImgRight
    $baseBottom = [int]$ExportCfg.CaptchaImgBottom

    $cropPlans = @(
        @{ Name = 'calibrated'; Left = $baseLeft; Top = $baseTop; Right = $baseRight; Bottom = $baseBottom },
        @{ Name = 'padded'; Left = ($baseLeft - 12); Top = ($baseTop - 8); Right = ($baseRight + 12); Bottom = ($baseBottom + 8) },
        @{ Name = 'dialog'; Left = ($baseLeft - 40); Top = ($baseTop - 30); Right = ($baseRight + 40); Bottom = ($baseBottom + 30) }
    )

    $tempImg = Join-Path $env:TEMP ("captcha_{0}.png" -f [Guid]::NewGuid().ToString('N'))
    try {
        foreach ($plan in $cropPlans) {
            if ($script:ExportDebugTiming) { Write-Step ("  [debug] GetCode: 截图+OCR plan={0} 开始" -f $plan.Name) }
            Save-ScreenRectPng -Left $plan.Left -Top $plan.Top -Right $plan.Right -Bottom $plan.Bottom -Path $tempImg
            Save-CaptchaDebugImage -SourcePath $tempImg

            $code = Get-CaptchaCodeFromImageFile -ImagePath $tempImg -LogInvalidOcr:$LogInvalidOcr
            if ($script:ExportDebugTiming) { Write-Step ("  [debug] GetCode: plan={0} -> '{1}'" -f $plan.Name, $code) }
            if (-not [string]::IsNullOrWhiteSpace($code)) { return $code }
        }
        return $null
    }
    catch {
        return $null
    }
    finally {
        if (Test-Path $tempImg) {
            Remove-Item $tempImg -Force -ErrorAction SilentlyContinue
        }
    }
}

function Wait-ForCaptchaCode {
    param(
        $ExportCfg,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nextLog = (Get-Date).AddSeconds(3)

    if ($script:ExportDebugTiming) { Write-Step '  [debug] 进入 Wait-ForCaptchaCode 循环' }
    do {
        Wait-IfPauseRequested
        $code = Get-CaptchaCodeFromScreen -ExportCfg $ExportCfg -LogInvalidOcr
        if (-not [string]::IsNullOrWhiteSpace($code)) { return $code }

        if ((Get-Date) -ge $nextLog) {
            $elapsed = [int]($TimeoutSeconds - ($deadline - (Get-Date)).TotalSeconds)
            Write-Step ("  等待验证码识别... 已等待 {0}s（调试图：logs\captcha-last.png）" -f $elapsed)
            $nextLog = (Get-Date).AddSeconds(3)
        }
        Start-SleepWithPause -Milliseconds 450
    } while ((Get-Date) -lt $deadline)

    Write-Step ("验证码识别超时，最近截图已保存到 {0}" -f (Join-Path $LogsDir 'captcha-last.png'))
    return $null
}

function Get-CaptchaDialogScreenRect {
    param($ExportCfg)

    return @{
        Left   = [Math]::Max(0, [int]$ExportCfg.CaptchaImgLeft - 140)
        Top    = [Math]::Max(0, [int]$ExportCfg.CaptchaImgTop - 90)
        Right  = [int]$ExportCfg.CaptchaImgRight + 160
        Bottom = [int]$ExportCfg.CaptchaImgBottom + 160
    }
}

function Capture-ScreenRectBitmap {
    param(
        [int]$Left,
        [int]$Top,
        [int]$Right,
        [int]$Bottom
    )

    $left = [Math]::Min($Left, $Right)
    $top = [Math]::Min($Top, $Bottom)
    $width = [Math]::Abs($Right - $Left)
    $height = [Math]::Abs($Bottom - $Top)
    if ($width -lt 4 -or $height -lt 4) {
        throw "Screenshot rectangle is too small: ($Left,$Top)-($Right,$Bottom)"
    }

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

function Get-CaptchaRegionHash {
    param($ExportCfg)

    if ($null -eq $ExportCfg) { return $null }

    $left = [int]$ExportCfg.CaptchaImgLeft
    $top = [int]$ExportCfg.CaptchaImgTop
    $right = [int]$ExportCfg.CaptchaImgRight
    $bottom = [int]$ExportCfg.CaptchaImgBottom
    $width = [Math]::Abs($right - $left)
    $height = [Math]::Abs($bottom - $top)
    if ($width -lt 20 -or $height -lt 12) { return $null }

    $bmp = Capture-ScreenRectBitmap -Left $left -Top $top -Right $right -Bottom $bottom
    try {
        return (Get-BitmapHash -Bitmap $bmp)
    }
    finally {
        $bmp.Dispose()
    }
}

function Test-CaptchaRegionAppeared {
    param(
        $ExportCfg,
        [string]$BaselineHash
    )

    if ([string]::IsNullOrWhiteSpace($BaselineHash)) { return $false }
    $current = Get-CaptchaRegionHash -ExportCfg $ExportCfg
    if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    return ($current -ne $BaselineHash)
}

function Test-CaptchaDialogByRegionOcr {
    param($ExportCfg)

    if ($null -eq $ExportCfg) { return $false }

    Initialize-Ocr | Out-Null
    $rect = Get-CaptchaDialogScreenRect -ExportCfg $ExportCfg
    $bmp = Capture-ScreenRectBitmap -Left $rect.Left -Top $rect.Top -Right $rect.Right -Bottom $rect.Bottom
    try {
        if ($script:ExportDebugTiming) { Write-Step '  [debug] WinRT OCR(dialog) 开始' }
        $text = Get-OcrTextFromBitmap -Bitmap $bmp
        if ($script:ExportDebugTiming) { Write-Step '  [debug] WinRT OCR(dialog) 结束' }
        return ($text -match '请输入验证码|请输入图片中的验证码|刷新验证码|验证码')
    }
    finally {
        $bmp.Dispose()
    }
}

function Test-NativeWindowTitleMatch {
    <#
        用 Win32 EnumWindows 判断是否存在标题匹配的可见顶层窗口（含被拥有窗口）。
        用于检测 UI Automation 漏掉的“请输入验证码”等被拥有弹窗。
    #>
    param([string]$TitleRegex)
    try {
        foreach ($t in [WinEnum]::GetTopLevelTitles()) {
            if (-not [string]::IsNullOrWhiteSpace($t) -and $t -match $TitleRegex) { return $true }
        }
    }
    catch { }
    return $false
}

function Test-CaptchaPresentFast {
    # 先用 UI Automation 找；找不到再用 Win32 EnumWindows 兜底（验证码弹窗是被拥有窗口，UIA 常枚举不到）。
    if ($null -ne (Find-WindowByAnyTitle -TitleRegex '请输入验证码')) { return $true }
    if (Test-NativeWindowTitleMatch -TitleRegex '请输入验证码') { return $true }
    return $false
}

function Test-CaptchaPresent {
    param($ExportCfg)

    if ($null -eq $ExportCfg) { return $false }
    return (Test-ExportCaptchaWindowPresent)
}

function Get-CaptchaInputErrorIconRect {
    param($ExportCfg)

    $cx = [int]$ExportCfg.CaptchaInputX
    $cy = [int]$ExportCfg.CaptchaInputY
    # 错误小 x 出现在输入框右侧，以校准点为中心向右截取
    return @{
        Left   = $cx + 20
        Top    = $cy - 16
        Right  = $cx + 108
        Bottom = $cy + 16
    }
}

function Test-BitmapHasUiBluePixels {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [int]$MinBluePixels = 8
    )

    $blueCount = 0
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            if ($c.B -ge 90 -and ($c.B - $c.R) -ge 35 -and ($c.B - $c.G) -ge 20) {
                $blueCount++
                if ($blueCount -ge $MinBluePixels) { return $true }
            }
        }
    }
    return $false
}

function Test-CaptchaInputErrorIcon {
    param($ExportCfg)

    if ($null -eq $ExportCfg) { return $false }

    $rect = Get-CaptchaInputErrorIconRect -ExportCfg $ExportCfg
    $width = [Math]::Abs($rect.Right - $rect.Left)
    $height = [Math]::Abs($rect.Bottom - $rect.Top)
    if ($width -lt 8 -or $height -lt 8) { return $false }

    $bmp = Capture-ScreenRectBitmap -Left $rect.Left -Top $rect.Top -Right $rect.Right -Bottom $rect.Bottom
    try {
        return (Test-BitmapHasUiBluePixels -Bitmap $bmp)
    }
    finally {
        $bmp.Dispose()
    }
}

function Test-CaptchaInputRejected {
    param($ExportCfg)

    if ($null -eq $ExportCfg) { return $false }
    if (-not (Test-CaptchaPresent -ExportCfg $ExportCfg)) { return $false }
    return (Test-CaptchaInputErrorIcon -ExportCfg $ExportCfg)
}

function Test-CaptchaStillVisible {
    param($ExportCfg)
    return (Test-CaptchaPresent -ExportCfg $ExportCfg)
}

function Get-ShallowWindowText {
    <#
        只做浅层、有界的文本提取，避免对超大窗口（如含数千行表格的主窗口）
        调用 FindAll(Descendants) 导致 UI Automation 卡死。
    #>
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [int]$MaxItems = 12
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $selfName = $Element.Current.Name
    if (-not [string]::IsNullOrWhiteSpace($selfName)) { $parts.Add($selfName.Trim()) }

    try {
        $cond = [System.Windows.Automation.Condition]::TrueCondition
        # 仅遍历直接子级，不递归整棵子树
        $children = $Element.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
        foreach ($child in $children) {
            $name = $child.Current.Name
            if (-not [string]::IsNullOrWhiteSpace($name)) { $parts.Add($name.Trim()) }
            if ($parts.Count -ge $MaxItems) { break }
        }
    }
    catch { }

    return (($parts | Select-Object -Unique) -join ' | ')
}

function Find-CaptchaErrorPopup {
    $errRegex = '验证码错误|验证码不正确|验证码有误|验证码已过期|请输入正确'
    foreach ($win in Get-RootWindows) {
        if ($win.Current.IsOffscreen) { continue }

        $title = [string]$win.Current.Name
        # 标题命中即可直接判定，无需读取子级
        if ($title -match $errRegex) {
            return [pscustomobject]@{ Window = $win; Text = $title }
        }

        # 跳过主程序窗口与大窗口：它们子树庞大，深扫会卡死，且错误弹窗一定是独立小窗
        if (-not [string]::IsNullOrWhiteSpace($title) -and (Test-MatchesMainWindowTitle $title)) { continue }
        $rect = $win.Current.BoundingRectangle
        if ($rect.Width -gt 900 -or $rect.Height -gt 700) { continue }

        $text = ''
        try { $text = Get-ShallowWindowText -Element $win } catch { }
        $combined = ($title + ' | ' + $text)
        if ($combined -match $errRegex) {
            return [pscustomobject]@{ Window = $win; Text = $combined }
        }
    }
    return $null
}

function Find-CaptchaInputError {
    param(
        $ExportCfg,
        [switch]$CaptchaVisible
    )

    $popup = Find-CaptchaErrorPopup
    if ($null -ne $popup) {
        return [pscustomobject]@{
            Kind   = 'popup'
            Detail = [string]$popup.Text
        }
    }

    if (-not $CaptchaVisible) { return $null }

    if (Test-CaptchaInputErrorIcon -ExportCfg $ExportCfg) {
        return [pscustomobject]@{
            Kind   = 'input_icon'
            Detail = '验证码输入框右侧出现错误图标（小 x）'
        }
    }

    return $null
}

function Clear-CaptchaErrorPopup {
    $popup = Find-CaptchaErrorPopup
    if ($null -eq $popup) { return $false }
    Write-Step '  检测到验证码错误文字弹窗，关闭后重试。'
    try {
        Bring-ToFront $popup.Window
        Start-Sleep -Milliseconds 150
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Milliseconds 200
    }
    catch { }
    return $true
}

function Test-CaptchaRegionClosed {
    param(
        $ExportCfg,
        [string]$ListBaselineHash
    )

    if ($null -eq $ExportCfg) { return $false }
    if ([string]::IsNullOrWhiteSpace($ListBaselineHash)) { return $false }

    $current = Get-CaptchaRegionHash -ExportCfg $ExportCfg
    if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    return ($current -eq $ListBaselineHash)
}

function Report-CaptchaInputError {
    param(
        $ExportCfg,
        [switch]$CaptchaVisible
    )

    $err = Find-CaptchaInputError -ExportCfg $ExportCfg -CaptchaVisible:$CaptchaVisible
    if ($null -eq $err) { return $false }

    if ($err.Kind -eq 'popup') {
        Clear-CaptchaErrorPopup | Out-Null
    }
    else {
        Write-Step ("  {0}" -f $err.Detail)
    }
    return $true
}

function Wait-CaptchaSubmitSuccess {
    param(
        $ExportCfg,
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [string]$ListBaselineHash = '',
        [int]$TimeoutSeconds = 30
    )

    Start-SleepWithPause -Milliseconds 600
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $goneStreak = 0
    $errorStreak = 0

    while ((Get-Date) -lt $deadline) {
        Wait-IfPauseRequested

        # 验证码弹窗是否仍然显示：仅用 UIA/Win32 窗口标题探测，不用 OCR 判断弹窗存在。
        $captchaShown = (Test-ExportCaptchaWindowPresent)

        if ($captchaShown) {
            $goneStreak = 0
            # 仅当验证码确实仍在显示时，错误小 x 才判定为识别错误；
            # 要求连续两次命中，避免弹窗关闭瞬间或列表蓝色控件造成误判。
            if (Test-CaptchaInputErrorIcon -ExportCfg $ExportCfg) {
                $errorStreak++
                if ($errorStreak -ge 2) {
                    Write-Step '  验证码输入框右侧出现错误图标（小 x），判定为识别错误。'
                    return $false
                }
            }
            else {
                $errorStreak = 0
            }
        }
        else {
            $errorStreak = 0
            $goneStreak++
            if ($goneStreak -ge 2) {
                # 验证码弹窗已关闭，说明验证码通过；等待“获取最新”数据加载完成。
                Write-Step '  验证码弹窗已关闭，等待数据加载...'
                Wait-LoadingGone -MainWindow $MainWindow -TimeoutSeconds $LoadingWaitSeconds -Fast -MinWaitMilliseconds 150
                return $true
            }
        }
        Start-SleepWithPause -Milliseconds 350
    }

    # 超时兜底：若验证码窗口确实已不在，按通过处理（覆盖数据加载较久的情况）。
    if (-not (Test-ExportCaptchaWindowPresent)) {
        Wait-LoadingGone -MainWindow $MainWindow -TimeoutSeconds $LoadingWaitSeconds -Fast -MinWaitMilliseconds 150
        return $true
    }
    return $false
}

function Test-CaptchaImageReady {
    param($ExportCfg)

    if ($null -eq $ExportCfg) { return $false }

    $left = [int]$ExportCfg.CaptchaImgLeft
    $top = [int]$ExportCfg.CaptchaImgTop
    $right = [int]$ExportCfg.CaptchaImgRight
    $bottom = [int]$ExportCfg.CaptchaImgBottom
    $width = [Math]::Abs($right - $left)
    $height = [Math]::Abs($bottom - $top)
    if ($width -lt 20 -or $height -lt 12) { return $false }

    $tempImg = Join-Path $env:TEMP ("captcha_probe_{0}.png" -f [Guid]::NewGuid().ToString('N'))
    try {
        Save-ScreenRectPng -Left $left -Top $top -Right $right -Bottom $bottom -Path $tempImg
        if ($script:ExportDebugTiming) { Write-Step '  [debug] ddddocr(probe) 开始' }
        $code = Invoke-CaptchaOcr -ImagePath $tempImg
        if ($script:ExportDebugTiming) { Write-Step '  [debug] ddddocr(probe) 结束' }
        return ($code -match '^[A-Z0-9]{3,8}$')
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path $tempImg) {
            Remove-Item $tempImg -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-IsCaptchaDialogVisible {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow = $null,
        $ExportCfg = $null,
        [string]$BaselineHash = '',
        [switch]$FastOnly
    )

    if (Test-ExportCaptchaWindowPresent) { return $true }

    if ($null -ne $ExportCfg -and -not [string]::IsNullOrWhiteSpace($BaselineHash)) {
        if (Test-CaptchaRegionAppeared -ExportCfg $ExportCfg -BaselineHash $BaselineHash) { return $true }
    }

    return $false
}

function Initialize-CaptchaOcrWarmup {
    Write-Step '预热验证码 OCR 模型...'
    Start-CaptchaOcrServer

    $warmImg = Join-Path $env:TEMP 'captcha_warmup.png'
    try {
        $bmp = New-Object System.Drawing.Bitmap(120, 40)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::White)
            $g.DrawString('TEST12', (New-Object System.Drawing.Font('Arial', 14)), [System.Drawing.Brushes]::Black, 10, 8)
        }
        finally { $g.Dispose() }
        $bmp.Save($warmImg, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $null = Invoke-CaptchaOcr -ImagePath $warmImg
    }
    catch { }
    finally {
        if (Test-Path $warmImg) { Remove-Item $warmImg -Force -ErrorAction SilentlyContinue }
    }
}

function Wait-ForCaptchaDialog {
    <#
        等待点击【获取最新】后的结果。
        返回 'Captcha'：出现验证码弹窗，需走识别提交流程。
        返回 'NoCaptcha'：列表已稳定就绪且长时间无验证码（数据已是最新或无需验证）。
        返回 $null：超时。
    #>
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        $ExportCfg = $null,
        [string]$BaselineHash = '',
        [int]$TimeoutSeconds = 30,
        [int]$NoCaptchaStableSeconds = 5
    )

    Write-Step '等待验证码弹窗出现...'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nextLog = (Get-Date).AddSeconds(3)
    $poll = 0
    $lastLoggedState = ''
    $listReadyStableSince = $null
    $sawLoading = $false

    do {
        Wait-IfPauseRequested
        $poll++
        $deepCheck = (($poll % 2) -eq 0)
        $state = Get-ExportFlowState -MainWindow $MainWindow -ExportCfg $ExportCfg `
            -BaselineHash $BaselineHash -DeepCheck:$deepCheck

        switch ($state.State) {
            'CaptchaDialog' {
                Write-ExportFlowState $state
                Start-SleepWithPause -Milliseconds 350
                return 'Captcha'
            }
            'CaptchaError' {
                $listReadyStableSince = $null
                Write-ExportFlowState $state
                Report-CaptchaInputError -ExportCfg $ExportCfg | Out-Null
            }
            'Loading' {
                $sawLoading = $true
                $listReadyStableSince = $null
                if ($state.State -ne $lastLoggedState -or (Get-Date) -ge $nextLog) {
                    Write-ExportFlowState $state
                    $lastLoggedState = $state.State
                    $elapsed = [int]($TimeoutSeconds - ($deadline - (Get-Date)).TotalSeconds)
                    Write-Step ("  数据加载中，已等待 {0}s..." -f $elapsed)
                    $nextLog = (Get-Date).AddSeconds(3)
                }
            }
            'ListReady' {
                $useStable = ($state.Method -eq 'ui_table') -or ($sawLoading -and $state.Method -eq 'quick_check')
                if ($useStable) {
                    if ($null -eq $listReadyStableSince) {
                        $listReadyStableSince = Get-Date
                    }
                    elseif (((Get-Date) - $listReadyStableSince).TotalSeconds -ge $NoCaptchaStableSeconds) {
                        Write-ExportFlowState $state
                        Write-Step '  未出现验证码弹窗，列表已稳定就绪（无需验证码）。'
                        return 'NoCaptcha'
                    }
                }
                else {
                    $listReadyStableSince = $null
                }
                if ($state.State -ne $lastLoggedState -or (Get-Date) -ge $nextLog) {
                    Write-ExportFlowState $state
                    $lastLoggedState = $state.State
                    $elapsed = [int]($TimeoutSeconds - ($deadline - (Get-Date)).TotalSeconds)
                    Write-Step ("  仍在等待验证码弹窗... 已等待 {0}s" -f $elapsed)
                    $nextLog = (Get-Date).AddSeconds(3)
                }
            }
            default {
                $listReadyStableSince = $null
                if ($state.State -ne $lastLoggedState -or (Get-Date) -ge $nextLog) {
                    Write-ExportFlowState $state
                    $lastLoggedState = $state.State
                    $elapsed = [int]($TimeoutSeconds - ($deadline - (Get-Date)).TotalSeconds)
                    Write-Step ("  仍在等待验证码弹窗... 已等待 {0}s" -f $elapsed)
                    $nextLog = (Get-Date).AddSeconds(3)
                }
            }
        }

        Start-SleepWithPause -Milliseconds 350
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Get-LoadingCheckScreenRect {
    param([System.Windows.Automation.AutomationElement]$MainWindow)

    $cx = $null; $cy = $null
    try {
        if ($null -ne $MainWindow) {
            $rect = $MainWindow.Current.BoundingRectangle
            if ($null -ne $rect -and $rect.Width -gt 0 -and $rect.Height -gt 0 `
                    -and -not [double]::IsInfinity($rect.Width)) {
                $cx = $rect.Left + ($rect.Width / 2)
                $cy = $rect.Top + ($rect.Height / 2)
            }
        }
    }
    catch { $cx = $null; $cy = $null }

    if ($null -eq $cx -or $null -eq $cy) {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $cx = $screen.Left + ($screen.Width / 2)
        $cy = $screen.Top + ($screen.Height / 2)
    }

    return @{
        Left   = [int]($cx - 220)
        Top    = [int]($cy - 90)
        Right  = [int]($cx + 220)
        Bottom = [int]($cy + 90)
    }
}

function Write-ExportFlowState {
    param($State)
    if ($null -eq $State) { return }
    Write-Step ("[状态] {0} — {1}（检测：{2}）" -f $State.State, $State.Detail, $State.Method)
}

function Get-ExportFlowState {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow = $null,
        $ExportCfg = $null,
        [string]$BaselineHash = '',
        [switch]$DeepCheck,
        [switch]$QuickCheck
    )

    if ($null -eq $MainWindow) {
        $MainWindow = Find-MainApplicationWindow $MainWindowTitleRegex
    }

    if (Test-ExportSaveDialogPresent) {
        return [pscustomobject]@{
            State  = 'ExportSaveDialog'
            Detail = '检测到另存为/导出对话框'
            Method = 'window_title'
        }
    }

    if (Test-ExportCaptchaWindowPresent) {
        $inputErr = Find-CaptchaInputError -ExportCfg $ExportCfg -CaptchaVisible
        if ($null -ne $inputErr) {
            $method = if ($inputErr.Kind -eq 'popup') { 'error_popup' } else { 'input_error_icon' }
            return [pscustomobject]@{
                State  = 'CaptchaError'
                Detail = [string]$inputErr.Detail
                Method = $method
            }
        }
        return [pscustomobject]@{
            State  = 'CaptchaDialog'
            Detail = '验证码弹窗（UIA/Win32 窗口标题）'
            Method = 'window_title'
        }
    }

    if ($null -ne $ExportCfg -and -not [string]::IsNullOrWhiteSpace($BaselineHash)) {
        if (Test-CaptchaRegionAppeared -ExportCfg $ExportCfg -BaselineHash $BaselineHash) {
            return [pscustomobject]@{
                State  = 'CaptchaDialog'
                Detail = '验证码区域画面相对点击前已变化'
                Method = 'region_hash_aux'
            }
        }
    }

    if ($QuickCheck) {
        return [pscustomobject]@{
            State  = 'ListReady'
            Detail = '列表页就绪（快速检测：无验证码/另存为窗）'
            Method = 'quick_check'
        }
    }

    $inputErr = Find-CaptchaInputError -ExportCfg $ExportCfg
    if ($null -ne $inputErr) {
        $method = if ($inputErr.Kind -eq 'popup') { 'error_popup' } else { 'input_error_icon' }
        return [pscustomobject]@{
            State  = 'CaptchaError'
            Detail = [string]$inputErr.Detail
            Method = $method
        }
    }

    if ($null -ne $MainWindow) {
        $snapshot = Get-ExportProbeSnapshot -MainWindow $MainWindow -ExportCfg $ExportCfg
        if ($snapshot.TableVisible) {
            if ($DeepCheck -and -not (Test-ExportRegionHashStable -MainWindow $MainWindow -StableChecks 1 -PollMilliseconds 200)) {
                return [pscustomobject]@{
                    State  = 'Loading'
                    Detail = '主窗口画面尚未稳定（哈希探测）'
                    Method = 'region_hash_stable'
                }
            }
            return [pscustomobject]@{
                State  = 'ListReady'
                Detail = '列表表格可见，无验证码弹窗'
                Method = 'ui_table'
            }
        }
        if ($snapshot.MainWindowPresent) {
            return [pscustomobject]@{
                State  = 'Unknown'
                Detail = '主窗口存在但未检测到列表表格'
                Method = 'probe_inconclusive'
            }
        }
    }

    return [pscustomobject]@{
        State  = 'Unknown'
        Detail = '无法确认导出页面状态'
        Method = 'probe_inconclusive'
    }
}

function Wait-UntilListReadyForExport {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        $ExportCfg = $null,
        [int]$TimeoutSeconds = 30
    )

    Write-Step '等待列表页就绪（验证码已关闭）...'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nextLog = (Get-Date).AddSeconds(3)

    do {
        Wait-IfPauseRequested
        $state = Get-ExportFlowState -MainWindow $MainWindow -ExportCfg $ExportCfg -DeepCheck
        switch ($state.State) {
            'ListReady' {
                Write-ExportFlowState $state
                return $true
            }
            'Loading' {
                if ((Get-Date) -ge $nextLog) {
                    Write-ExportFlowState $state
                    $nextLog = (Get-Date).AddSeconds(3)
                }
            }
            'Unknown' {
                if ((Get-Date) -ge $nextLog) {
                    Write-ExportFlowState $state
                    Write-Step '  列表状态未确认，继续等待...'
                    $nextLog = (Get-Date).AddSeconds(3)
                }
            }
            'CaptchaDialog' {
                Write-ExportFlowState $state
                return $false
            }
            'CaptchaError' {
                Write-ExportFlowState $state
                Report-CaptchaInputError -ExportCfg $ExportCfg | Out-Null
            }
            default {
                if ((Get-Date) -ge $nextLog) {
                    Write-ExportFlowState $state
                    $nextLog = (Get-Date).AddSeconds(3)
                }
            }
        }
        Start-SleepWithPause -Milliseconds 350
    } while ((Get-Date) -lt $deadline)

    $final = Get-ExportFlowState -MainWindow $MainWindow -ExportCfg $ExportCfg -DeepCheck
    Write-ExportFlowState $final
    return ($final.State -eq 'ListReady')
}

function Wait-LoadingGone {
    param(
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [int]$TimeoutSeconds = 180,
        [int]$MinWaitMilliseconds = 500,
        [switch]$Fast
    )

    if ($null -eq $MainWindow) {
        Write-Step 'Warning: 主窗口不可用，跳过 loading 等待。'
        return $false
    }

    Start-SleepWithPause -Milliseconds $(if ($Fast) { [Math]::Min($MinWaitMilliseconds, 200) } else { $MinWaitMilliseconds })

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $prevHash = ''
    $stableCount = 0
    $pollMs = if ($Fast) { 250 } else { 700 }

    while ((Get-Date) -lt $deadline) {
        Wait-IfPauseRequested
        if ($Fast) {
            # 导出流程 Fast 模式：仅用主窗口画面哈希稳定判断，不依赖 loading OCR。
            $rect = $MainWindow.Current.BoundingRectangle
            if ($null -ne $rect -and $rect.Width -gt 100) {
                $hash = Get-ScreenRectHash $rect
                if ($hash -eq $prevHash) { $stableCount++ } else { $stableCount = 0 }
                $prevHash = $hash
                if ($stableCount -ge 2) {
                    Write-Step 'Loading 已消失（主窗口画面稳定）。'
                    return $true
                }
            }
        }
        else {
            Initialize-Ocr | Out-Null
            $bmp = Capture-WindowBitmap -Window $MainWindow
            try {
                $text = Get-OcrTextFromBitmap -Bitmap $bmp
                if (-not (Test-LoadingText -Text $text)) {
                    $hash = Get-BitmapHash -Bitmap $bmp
                    if ($hash -eq $prevHash) { $stableCount++ }
                    else { $stableCount = 0 }
                    $prevHash = $hash
                    if ($stableCount -ge 1) {
                        Write-Step 'Loading 已消失，页面稳定。'
                        return $true
                    }
                }
                else {
                    $stableCount = 0
                    $prevHash = Get-BitmapHash -Bitmap $bmp
                }
            }
            finally {
                $bmp.Dispose()
            }
        }
        Start-SleepWithPause -Milliseconds $pollMs
    }

    Write-Step 'Warning: 等待 loading 超时，继续执行。'
    return $false
}

function Save-ExportDialog {
    param(
        [string]$FullPath,
        [int]$InitialWaitMilliseconds = 800
    )

    Write-Step '  正在保存导出文件，向当前焦点粘贴路径...'
    Start-SleepWithPause -Milliseconds $InitialWaitMilliseconds
    Set-ImeEnglishForForeground
    Start-SleepWithPause -Milliseconds 60
    Set-Clipboard -Value $FullPath
    Start-SleepWithPause -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-SleepWithPause -Milliseconds 40
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-SleepWithPause -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')

    # 等待文件落盘；若有覆盖确认弹窗，回车确认
    $deadline = (Get-Date).AddSeconds(20)
    $confirmed = $false
    do {
        Wait-IfPauseRequested
        if (Test-Path $FullPath) { return $true }
        if (-not $confirmed) {
            $overwrite = Find-WindowByAnyTitle -TitleRegex '确认另存为|替换|覆盖|Confirm Save As'
            if ($null -ne $overwrite) {
                Bring-ToFront $overwrite
                Start-SleepWithPause -Milliseconds 100
                [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
                $confirmed = $true
            }
        }
        Start-SleepWithPause -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Invoke-ExportCalibration {
    $existing = Get-ConfigProperty -Config (Get-AppConfig) -Names @('exportCalibration', 'ExportCalibration')

    Write-Step '导出坐标校准开始。'
    Write-Step '请先进入【主执业机构在本院医师】列表页。'
    Write-Step '建议先手动点击一次【获取最新】，让验证码弹窗保持打开。'
    Read-Host '准备好后按 Enter 开始校准'

    $existingGetLatest = Get-CalibrationPointFromSection -Section $existing -XField 'GetLatestX' -YField 'GetLatestY'
    $getLatest = Read-CursorPointWithConfirm -Title '导出校准 第1步/8：获取最新按钮' `
        -Instruction '把鼠标移到【获取最新】按钮中间。' `
        -ExistingX $existingGetLatest.X -ExistingY $existingGetLatest.Y

    $existingCaptchaLeft = Get-CalibrationPointFromSection -Section $existing -XField 'CaptchaImgLeft' -YField 'CaptchaImgTop'
    $captchaLeft = Read-CursorPointWithConfirm -Title '导出校准 第2步/8：验证码图片左上角' `
        -Instruction '把鼠标移到验证码图片左上角（紧贴橙色字母，不要含输入框/边框）。' `
        -ExistingX $existingCaptchaLeft.X -ExistingY $existingCaptchaLeft.Y

    $existingCaptchaRight = Get-CalibrationPointFromSection -Section $existing -XField 'CaptchaImgRight' -YField 'CaptchaImgBottom'
    $captchaRight = Read-CursorPointWithConfirm -Title '导出校准 第3步/8：验证码图片右下角' `
        -Instruction '把鼠标移到验证码图片右下角（紧贴橙色字母）。' `
        -ExistingX $existingCaptchaRight.X -ExistingY $existingCaptchaRight.Y

    $existingCaptchaInput = Get-CalibrationPointFromSection -Section $existing -XField 'CaptchaInputX' -YField 'CaptchaInputY'
    $captchaInput = Read-CursorPointWithConfirm -Title '导出校准 第4步/8：验证码输入框' `
        -Instruction '把鼠标移到验证码输入框中间。' `
        -ExistingX $existingCaptchaInput.X -ExistingY $existingCaptchaInput.Y

    $existingConfirm = Get-CalibrationPointFromSection -Section $existing -XField 'ConfirmX' -YField 'ConfirmY'
    $confirm = Read-CursorPointWithConfirm -Title '导出校准 第5步/8：确定按钮' `
        -Instruction '把鼠标移到验证码弹窗【确定】按钮中间。' `
        -ExistingX $existingConfirm.X -ExistingY $existingConfirm.Y

    $existingRefresh = Get-CalibrationPointFromSection -Section $existing -XField 'RefreshCaptchaX' -YField 'RefreshCaptchaY'
    $refresh = Read-CursorPointWithConfirm -Title '导出校准 第6步/8：刷新验证码' `
        -Instruction '把鼠标移到【刷新验证码】链接中间。' `
        -ExistingX $existingRefresh.X -ExistingY $existingRefresh.Y

    Write-Step '请关闭验证码弹窗，回到【主执业】列表页后再校准【导出】按钮。'
    Read-Host '主执业列表页准备好后按 Enter 继续'

    $existingExport = Get-CalibrationPointFromSection -Section $existing -XField 'ExportX' -YField 'ExportY'
    $exportBtn = Read-CursorPointWithConfirm -Title '导出校准 第7步/8：主执业导出按钮' `
        -Instruction '把鼠标移到【主执业】页面的【导出】按钮中间。' `
        -ExistingX $existingExport.X -ExistingY $existingExport.Y

    Write-Step '现在切换到【外院在本院多执业医师】列表页，校准它的【导出】按钮。'
    Write-Step '若暂不需要多执业导出，可在该步输入 S 跳过（保留已有坐标或留空）。'
    Read-Host '多执业列表页准备好后按 Enter 继续'

    $existingMultiExport = Get-CalibrationPointFromSection -Section $existing -XField 'MultiExportX' -YField 'MultiExportY'
    $multiExportBtn = Read-CursorPointWithConfirm -Title '导出校准 第8步/8：多执业导出按钮' `
        -Instruction '把鼠标移到【多执业】页面的【导出】按钮中间。' `
        -ExistingX $existingMultiExport.X -ExistingY $existingMultiExport.Y

    $section = @{
        GetLatestX        = [int]$getLatest.X
        GetLatestY        = [int]$getLatest.Y
        CaptchaImgLeft    = [int]$captchaLeft.X
        CaptchaImgTop     = [int]$captchaLeft.Y
        CaptchaImgRight   = [int]$captchaRight.X
        CaptchaImgBottom  = [int]$captchaRight.Y
        CaptchaInputX     = [int]$captchaInput.X
        CaptchaInputY     = [int]$captchaInput.Y
        ConfirmX          = [int]$confirm.X
        ConfirmY          = [int]$confirm.Y
        RefreshCaptchaX   = [int]$refresh.X
        RefreshCaptchaY   = [int]$refresh.Y
        ExportX           = [int]$exportBtn.X
        ExportY           = [int]$exportBtn.Y
        MultiExportX      = [int]$multiExportBtn.X
        MultiExportY      = [int]$multiExportBtn.Y
        SavedAt           = (Get-Date).ToString('s')
    }
    Set-ConfigSection -SectionName 'exportCalibration' -SectionData $section
    Write-Step ("导出坐标已保存到 {0} 的 exportCalibration" -f $ConfigPath)
}

function Get-ExportOutputDir {
    $outDir = $ExportDir
    if ([string]::IsNullOrWhiteSpace($outDir)) {
        $outDir = Join-Path $ProjectRoot 'exports'
    }
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    return $outDir
}

function Get-ExportFileName {
    param([string]$Entry)
    $label = if ($Entry -eq 'Multi') { '多执业导出' } else { '主执业导出' }
    return ("{0}-{1}.xls" -f $label, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
}

function Enter-ExportListPage {
    param([string]$EntryLabel)

    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        $main = Invoke-LoginToHome
    }
    Invoke-EnterListFromHome -MainWindow $main

    $main = Find-MainApplicationWindow $MainWindowTitleRegex
    if ($null -eq $main) {
        throw ("进入{0}列表后主窗口丢失。" -f $EntryLabel)
    }
    Bring-ToFront $main
    Wait-RectStable -Rect $main.Current.BoundingRectangle -TimeoutSeconds 4 -StableChecks 1 | Out-Null
    return $main
}

function Format-CaptchaAttemptLabel {
    param(
        [int]$Attempt,
        [int]$MaxRetries
    )

    if ($MaxRetries -gt 0) {
        return ("第 {0}/{1} 次" -f $Attempt, $MaxRetries)
    }
    return ("第 {0} 次" -f $Attempt)
}

function Resolve-CaptchaForExport {
    <#
        在验证码弹窗已打开的前提下，识别并提交验证码，失败自动刷新重试。
        MaxCaptchaRetries <= 0 时不限制次数；> 0 时达到上限返回 $false。
        成功返回 $true。
        硬故障（OCR 连续空、输入框写入失败、状态矛盾）立即 throw 停止。
    #>
    param(
        $ExportCfg,
        [System.Windows.Automation.AutomationElement]$MainWindow,
        [string]$ListBaselineHash = ''
    )

    Reset-ExportCaptchaEmptyStreak

    $maxRetries = [Math]::Max(0, $MaxCaptchaRetries)
    $unlimited = ($maxRetries -le 0)
    $attempt = 0

    while ($true) {
        $attempt++
        if (-not $unlimited -and $attempt -gt $maxRetries) {
            return $false
        }

        $attemptLabel = Format-CaptchaAttemptLabel -Attempt $attempt -MaxRetries $maxRetries

        Wait-IfPauseRequested
        if ($attempt -gt 1) {
            Write-Step '  刷新验证码后重试。'
            Invoke-ScreenClick -X ([int]$ExportCfg.RefreshCaptchaX) -Y ([int]$ExportCfg.RefreshCaptchaY) -FocusWindow $MainWindow
            Start-SleepWithPause -Milliseconds 700
        }

        if (-not (Test-ExportCaptchaWindowPresent)) {
            $state = Get-ExportFlowState -MainWindow $MainWindow -ExportCfg $ExportCfg
            Write-ExportFlowState $state
            if ($state.State -in @('ListReady', 'ExportSaveDialog', 'Unknown')) {
                Write-ExportProbeDiagnostics -Tag '验证码状态矛盾'
                throw ("验证码流程状态矛盾：期望 CaptchaDialog，实际为 {0}（{1}）。已停止。" -f $state.State, $state.Method)
            }
            if ($state.State -eq 'Loading') {
                Write-Step '  等待加载完成后再识别验证码...'
                Wait-LoadingGone -MainWindow $MainWindow -TimeoutSeconds 30 -Fast -MinWaitMilliseconds 150 | Out-Null
                continue
            }
            Write-Step ("  {0}：当前不在验证码弹窗状态，跳过。" -f $attemptLabel)
            continue
        }

        $state = Get-ExportFlowState -MainWindow $MainWindow -ExportCfg $ExportCfg
        if ($state.State -eq 'CaptchaError') {
            Write-ExportFlowState $state
            Report-CaptchaInputError -ExportCfg $ExportCfg | Out-Null
            continue
        }

        $code = Wait-ForCaptchaCode -ExportCfg $ExportCfg -TimeoutSeconds $(if ($attempt -eq 1) { 30 } else { 12 })
        if ([string]::IsNullOrWhiteSpace($code)) {
            Write-Step ("  {0}：未能识别验证码。" -f $attemptLabel)
            Register-ExportCaptchaEmptyOcr -Context $attemptLabel
            continue
        }
        Reset-ExportCaptchaEmptyStreak

        Write-Step ("  {0}：识别为 {1}，填入并确定。" -f $attemptLabel, $code)

        Write-ExportProbeDiagnostics -Tag '验证码填入前'
        $inputOk = Invoke-ClickAndPasteText -X ([int]$ExportCfg.CaptchaInputX) -Y ([int]$ExportCfg.CaptchaInputY) `
            -Text $code -FocusWindow $MainWindow -LogSteps
        Write-ExportProbeDiagnostics -Tag '验证码填入后'

        if (-not $inputOk) {
            Write-ExportProbeDiagnostics -Tag '输入框硬故障'
            throw ("验证码输入框未能写入内容（回读为空），已立即停止。识别码='{0}'。" -f $code)
        }

        Start-SleepWithPause -Milliseconds 150

        Invoke-ScreenClick -X ([int]$ExportCfg.ConfirmX) -Y ([int]$ExportCfg.ConfirmY) -FocusWindow $MainWindow

        if (Wait-CaptchaSubmitSuccess -ExportCfg $ExportCfg -MainWindow $MainWindow -ListBaselineHash $ListBaselineHash) {
            $state = Get-ExportFlowState -MainWindow $MainWindow -ExportCfg $ExportCfg
            Write-ExportFlowState $state
            Write-Step '  验证码通过。'
            return $true
        }

        $state = Get-ExportFlowState -MainWindow $MainWindow -ExportCfg $ExportCfg
        Write-ExportFlowState $state
        Write-Step '  验证码未通过（识别错误或弹窗仍在）。'
    }
}

function Complete-ExportSaveDialog {
    param(
        [string]$Entry,
        [string]$OutDir
    )

    $fileName = Get-ExportFileName -Entry $Entry
    $fullPath = Join-Path $OutDir $fileName

    if (-not (Save-ExportDialog -FullPath $fullPath)) {
        return $null
    }
    return $fullPath
}

function Invoke-MainExportFlow {
    try {
        Initialize-CaptchaOcrWarmup

        $exportCfg = Get-ExportCalibration
        if ($null -eq $exportCfg) {
            throw '未找到有效导出坐标。请先运行 cmd\automation\export-calibrate.cmd 完成校准。'
        }

        $outDir = Get-ExportOutputDir
        Write-Step ("导出目录：{0}" -f $outDir)

        Wait-IfPauseRequested
        $main = Enter-ExportListPage -EntryLabel '主执业'

        Write-Step '检测列表页状态...'
        $state = Get-ExportFlowState -MainWindow $main -ExportCfg $exportCfg -QuickCheck
        Write-ExportFlowState $state
        if ($state.State -ne 'ListReady') {
            throw ("进入列表页后状态异常：{0} — {1}。请确认页面是否正确。" -f $state.State, $state.Detail)
        }

        Wait-IfPauseRequested

        $baselineHash = Get-CaptchaRegionHash -ExportCfg $exportCfg
        Write-Step '点击【获取最新】。'
        Wait-IfPauseRequested
        Invoke-ScreenClick -X ([int]$exportCfg.GetLatestX) -Y ([int]$exportCfg.GetLatestY) -FocusWindow $main
        # 移开鼠标，避免停留在按钮上触发悬停提示浮窗，干扰验证码弹窗与状态检测
        Move-CursorAway -MainWindow $main
        $main = Find-MainApplicationWindow $MainWindowTitleRegex
        if ($null -ne $main) { Bring-ToFront $main }

        $captchaWait = Wait-ForCaptchaDialog -MainWindow $main -ExportCfg $exportCfg -BaselineHash $baselineHash
        if ($captchaWait -eq 'Captcha') {
            Write-Step '识别并提交验证码...'
            if (-not (Resolve-CaptchaForExport -ExportCfg $exportCfg -MainWindow $main -ListBaselineHash $baselineHash)) {
                $state = Get-ExportFlowState -MainWindow $main -ExportCfg $exportCfg -DeepCheck
                Write-ExportFlowState $state
                throw '验证码识别失败（已用尽重试次数）。可查看 logs\captcha-last.png 核对截图区域，或去掉 -MaxCaptchaRetries 限制后重试。'
            }
        }
        elseif ($captchaWait -eq 'NoCaptcha') {
            Write-Step '获取最新无需验证码，直接进入导出。'
        }
        else {
            $state = Get-ExportFlowState -MainWindow $main -ExportCfg $exportCfg -DeepCheck
            Write-ExportFlowState $state
            throw ("等待验证码弹窗超时，当前状态：{0} — {1}" -f $state.State, $state.Detail)
        }

        $main = Find-MainApplicationWindow $MainWindowTitleRegex
        if ($null -eq $main) { throw '验证码通过后主窗口丢失。' }
        Bring-ToFront $main

        if (-not (Wait-UntilListReadyForExport -MainWindow $main -ExportCfg $exportCfg)) {
            throw '验证码仍未关闭或列表未就绪，无法导出。请重新运行 cmd\automation\export.cmd。'
        }

        Write-Step '点击【导出】。'
        Wait-IfPauseRequested
        Invoke-ScreenClick -X ([int]$exportCfg.ExportX) -Y ([int]$exportCfg.ExportY) -FocusWindow $main
        Move-CursorAway -MainWindow $main

        $fullPath = Complete-ExportSaveDialog -Entry 'Main' -OutDir $outDir
        if ($null -eq $fullPath) {
            $state = Get-ExportFlowState -MainWindow $main -ExportCfg $exportCfg -DeepCheck
            Write-ExportFlowState $state
            if ($state.State -eq 'CaptchaDialog') {
                throw '验证码输入错误，导出未开始。请重新运行 cmd\automation\export.cmd。'
            }
            throw '保存导出文件失败，请检查另存为对话框或导出目录权限。'
        }

        Write-Step ("主执业导出完成：{0}" -f $fullPath)
        Invoke-OptionalExportValidation -ExportPath $fullPath

        if (-not $KeepAppOpen) {
            Stop-DoctorApplication
        }
        return $fullPath
    }
    finally {
        Stop-CaptchaOcrServer
    }
}

function Invoke-MultiExportFlow {
    Initialize-Ocr | Out-Null

    $exportCfg = Get-ExportCalibration -RequireMulti
    if ($null -eq $exportCfg) {
        throw '未找到多执业导出坐标（MultiExportX/Y）。请运行 cmd\automation\export-calibrate.cmd 完成第 8 步校准。'
    }

    $outDir = Get-ExportOutputDir
    Write-Step ("导出目录：{0}" -f $outDir)

    Wait-IfPauseRequested
    $main = Enter-ExportListPage -EntryLabel '多执业'

    Write-Step '检测列表页状态...'
    $state = Get-ExportFlowState -MainWindow $main -ExportCfg $exportCfg -QuickCheck
    Write-ExportFlowState $state
    if ($state.State -ne 'ListReady') {
        throw ("进入列表页后状态异常：{0} — {1}。请确认页面是否正确。" -f $state.State, $state.Detail)
    }

    Wait-IfPauseRequested

    Write-Step '多执业列表无需验证码，直接点击【导出】。'
    Wait-IfPauseRequested
    Invoke-ScreenClick -X ([int]$exportCfg.MultiExportX) -Y ([int]$exportCfg.MultiExportY) -FocusWindow $main
    Move-CursorAway -MainWindow $main
    Start-SleepWithPause -Milliseconds 600

    # 部分情况下导出前会有短暂 loading
    Wait-LoadingGone -MainWindow $main -TimeoutSeconds 30 -Fast -MinWaitMilliseconds 150 | Out-Null

    $fullPath = Complete-ExportSaveDialog -Entry 'Multi' -OutDir $outDir
    if ($null -eq $fullPath) {
        throw '保存导出文件失败，请检查另存为对话框或导出目录权限。'
    }

    Write-Step ("多执业导出完成：{0}" -f $fullPath)

    if (-not $KeepAppOpen) {
        Stop-DoctorApplication
    }
    return $fullPath
}

function Invoke-ExportWithLogin {
    # 导出流程不启动 WinForms 全局热键线程（避免与 WinRT/UI Automation 在 STA 线程冲突导致原生层崩溃）。
    # 暂停/恢复改由 Wait-IfPauseRequested 中的按键轮询（GetAsyncKeyState）实现，全局有效。
    Initialize-PauseHotkey -DeferGlobalHotkey
    try {
        if ($ListEntry -eq 'Multi') {
            Invoke-MultiExportFlow | Out-Null
        }
        else {
            Invoke-MainExportFlow | Out-Null
        }
    }
    finally {
        Stop-GlobalPauseHotkey
    }
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
    'ExportCalibrate' { Invoke-ExportCalibration }
    'Export' { Invoke-ExportWithLogin }
}
