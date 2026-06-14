#requires -Version 5.1
<#
    诊断脚本：定位“点击了输入框但输入不进去”的真因。
    挂接到已经打开的“医师电子化注册信息系统”，对一个输入框坐标，按顺序尝试多种输入方式，
    每一步都打日志（控制台 + logs\diagnose-input.log），并在每次输入后用 UI Automation 回读输入框的值做校验。
    任意一种方式成功即停止；全部失败也会停止并给出结论。绝不无限重试。

    用法（app 需已打开并停在列表页）：
      默认测姓名搜索框：
        powershell -NoProfile -ExecutionPolicy Bypass -STA -File automation\ps1\diagnose-input.ps1
      测验证码（会自动点【获取最新】打开验证码弹窗）：
        powershell -NoProfile -ExecutionPolicy Bypass -STA -File automation\ps1\diagnose-input.ps1 -Captcha
      手动指定坐标：
        ... -X 890 -Y 510 -Label "验证码输入框"
#>

param(
    [int]$X = 0,
    [int]$Y = 0,
    [string]$Label = '',
    [switch]$Captcha,
    [string]$TestText = 'CESHI123',
    [string]$MainWindowTitleRegex = '医师电子化注册信息系统|机构版'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DiagWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("imm32.dll")] public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
    public const uint WM_IME_CONTROL = 0x0283;
    public const int IMC_SETOPENSTATUS = 0x0006;
}
"@

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LogsDir = Join-Path $ProjectRoot 'logs'
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }
$LogFile = Join-Path $LogsDir 'diagnose-input.log'
"==== diagnose-input 开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" | Out-File -FilePath $LogFile -Encoding UTF8

function Log {
    param([string]$Msg)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-ForegroundInfo {
    $h = [DiagWin32]::GetForegroundWindow()
    $len = [DiagWin32]::GetWindowTextLength($h)
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [void][DiagWin32]::GetWindowText($h, $sb, $sb.Capacity)
    $procId = 0
    [void][DiagWin32]::GetWindowThreadProcessId($h, [ref]$procId)
    return ("hwnd={0} pid={1} title='{2}'" -f $h, $procId, $sb.ToString())
}

function Describe-Element {
    param($el)
    if ($null -eq $el) { return '<null>' }
    try {
        $name = $el.Current.Name
        $ct = $el.Current.ControlType.ProgrammaticName
        $cls = $el.Current.ClassName
        $hwnd = $el.Current.NativeWindowHandle
        $enabled = $el.Current.IsEnabled
        $kbd = $el.Current.IsKeyboardFocusable
        $hasFocus = $el.Current.HasKeyboardFocus
        $vp = $null
        $valInfo = 'ValuePattern=NO'
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
            $valInfo = ("ValuePattern=YES value='{0}' readonly={1}" -f $vp.Current.Value, $vp.Current.IsReadOnly)
        }
        return ("Name='{0}' Type={1} Class='{2}' hwnd={3} enabled={4} kbdFocusable={5} hasFocus={6} {7}" -f `
            $name, $ct, $cls, $hwnd, $enabled, $kbd, $hasFocus, $valInfo)
    }
    catch {
        return ("<描述元素出错: {0}>" -f $_.Exception.Message)
    }
}

function Get-ElementValue {
    param($el)
    if ($null -eq $el) { return $null }
    try {
        $vp = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
            return $vp.Current.Value
        }
    }
    catch { }
    return $null
}

function Get-TopLevelWindowOf {
    param($el)
    if ($null -eq $el) { return $null }
    try {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $cur = $el
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        while ($null -ne $cur) {
            $parent = $walker.GetParent($cur)
            if ($null -eq $parent -or $parent.Equals($root)) { return $cur }
            $cur = $parent
        }
    }
    catch { }
    return $null
}

function Bring-ToFront {
    param($el)
    try {
        $handle = [IntPtr]([int]$el.Current.NativeWindowHandle)
        if ($handle -eq [IntPtr]::Zero) { return }
        [DiagWin32]::ShowWindow($handle, 5) | Out-Null
        [DiagWin32]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, 0x0043) | Out-Null
        Start-Sleep -Milliseconds 80
        [DiagWin32]::SetWindowPos($handle, [IntPtr](-2), 0, 0, 0, 0, 0x0043) | Out-Null
        [DiagWin32]::SetForegroundWindow($handle) | Out-Null
        Start-Sleep -Milliseconds 250
    }
    catch { Log ("Bring-ToFront 出错: {0}" -f $_.Exception.Message) }
}

function Click-At {
    param([int]$cx, [int]$cy)
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($cx, $cy)
    Start-Sleep -Milliseconds 150
    [DiagWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [DiagWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}

function Get-FocusedAutomationElement {
    try { return [System.Windows.Automation.AutomationElement]::FocusedElement }
    catch { Log ("取焦点元素出错: {0}" -f $_.Exception.Message); return $null }
}

function Get-RootWindows {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Window)
    return $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
}

function Fmt-Num {
    param($n)
    if ($null -eq $n -or [double]::IsInfinity([double]$n) -or [double]::IsNaN([double]$n)) { return 'inf' }
    if ([double]$n -gt 2147483000 -or [double]$n -lt -2147483000) { return 'big' }
    return [string][int][double]$n
}

function Log-AllTopWindows {
    param([string]$tag)
    Log ("  [{0}] 当前所有顶层窗口：" -f $tag)
    foreach ($w in Get-RootWindows) {
        $t = $w.Current.Name
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $r = $w.Current.BoundingRectangle
        Log ("    - hwnd={0} '{1}' [L={2} T={3} W={4} H={5}]" -f `
            $w.Current.NativeWindowHandle, $t, (Fmt-Num $r.Left), (Fmt-Num $r.Top), (Fmt-Num $r.Width), (Fmt-Num $r.Height))
    }
}

function Find-Main {
    foreach ($w in Get-RootWindows) {
        $t = $w.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($t) -and $t -match $MainWindowTitleRegex) { return $w }
    }
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        if ($proc.MainWindowHandle -eq 0) { continue }
        if ([string]::IsNullOrWhiteSpace($proc.MainWindowTitle)) { continue }
        if ($proc.MainWindowTitle -match $MainWindowTitleRegex) {
            return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]($proc.MainWindowHandle))
        }
    }
    return $null
}

function Read-BackValue {
    param([string]$tag)
    $f = Get-FocusedAutomationElement
    $v = Get-ElementValue $f
    if ($null -eq $v) {
        Log ("  [{0}] 回读: <该控件不支持 ValuePattern，无法读值> 焦点={1}" -f $tag, (Describe-Element $f))
        return $null
    }
    Log ("  [{0}] 回读输入框值 = '{1}'" -f $tag, $v)
    return $v
}

# ---- 对某坐标执行完整输入测试，返回是否成功 ----
function Test-InputAt {
    param(
        [int]$tx, [int]$ty, [string]$tlabel,
        $targetWindow
    )
    Log ("===== 目标: {0}  点击坐标 X={1} Y={2}  测试文本='{3}' =====" -f $tlabel, $tx, $ty, $TestText)

    Log '--- 探针: AutomationElement.FromPoint（看坐标下是什么控件 + 它属于哪个顶层窗口）---'
    try {
        $pt = New-Object System.Windows.Point($tx, $ty)
        $atPoint = [System.Windows.Automation.AutomationElement]::FromPoint($pt)
        Log ("  坐标下元素: {0}" -f (Describe-Element $atPoint))
        $owner = Get-TopLevelWindowOf $atPoint
        if ($null -ne $owner) {
            Log ("  该元素所属顶层窗口: '{0}' hwnd={1}" -f $owner.Current.Name, $owner.Current.NativeWindowHandle)
        }
    }
    catch { Log ("  FromPoint 出错: {0}" -f $_.Exception.Message) }

    Log ("  前台窗口（点击前）: {0}" -f (Get-ForegroundInfo))
    if ($null -ne $targetWindow) {
        Log ("  把目标窗口拉到前台: '{0}' hwnd={1}" -f $targetWindow.Current.Name, $targetWindow.Current.NativeWindowHandle)
        Bring-ToFront $targetWindow
    }
    Log ("  前台窗口（拉前台后、点击前）: {0}" -f (Get-ForegroundInfo))
    Click-At -cx $tx -cy $ty
    Log ("  前台窗口（点击后）: {0}" -f (Get-ForegroundInfo))

    $focused = Get-FocusedAutomationElement
    Log ("  点击后焦点元素: {0}" -f (Describe-Element $focused))
    $canVerify = ($null -ne (Get-ElementValue $focused))
    if ($canVerify) { Log '  -> 焦点元素支持 ValuePattern，可自动回读校验。' }
    else { Log '  -> 焦点元素不支持 ValuePattern（无法自动回读；依赖肉眼观察）。' }

    $okMethod = ''

    # 方法1: 关IME + 剪贴板 + SendKeys ^a/{DEL}/^v（脚本现有方式）
    Log '--- 方法1: Set-ImeEnglish + Set-Clipboard + SendKeys(^a,{DEL},^v) ---'
    try {
        $hwndFg = [DiagWin32]::GetForegroundWindow()
        $ime = [DiagWin32]::ImmGetDefaultIMEWnd($hwndFg)
        Log ("  前台 hwnd={0} 默认IME窗口={1}" -f $hwndFg, $ime)
        if ($ime -ne [IntPtr]::Zero) {
            [DiagWin32]::SendMessage($ime, [DiagWin32]::WM_IME_CONTROL, [IntPtr][DiagWin32]::IMC_SETOPENSTATUS, [IntPtr]0) | Out-Null
            Log '  已发送关闭IME(英文态)消息。'
        }
        Start-Sleep -Milliseconds 80
        [System.Windows.Forms.SendKeys]::SendWait('^a'); Start-Sleep -Milliseconds 80
        [System.Windows.Forms.SendKeys]::SendWait('{DEL}'); Start-Sleep -Milliseconds 80
        Set-Clipboard -Value $TestText
        $cb = Get-Clipboard -Raw
        Log ("  Set-Clipboard 后 Get-Clipboard 读回 = '{0}'" -f $cb)
        Start-Sleep -Milliseconds 80
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Start-Sleep -Milliseconds 250
        $v = Read-BackValue -tag '方法1'
        if ($null -ne $v -and $v -match [regex]::Escape($TestText)) { $okMethod = '方法1(剪贴板粘贴)' }
    }
    catch { Log ("  方法1 出错: {0}" -f $_.Exception.Message) }

    if ($okMethod -eq '') {
        Log '--- 方法2: 重新点击 + ValuePattern.SetValue（绕过键盘和剪贴板）---'
        try {
            Click-At -cx $tx -cy $ty
            $f = Get-FocusedAutomationElement
            Log ("  焦点元素: {0}" -f (Describe-Element $f))
            $vp = $null
            if ($null -ne $f -and $f.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
                $vp.SetValue($TestText)
                Start-Sleep -Milliseconds 200
                $v = Read-BackValue -tag '方法2'
                if ($null -ne $v -and $v -match [regex]::Escape($TestText)) { $okMethod = '方法2(ValuePattern.SetValue)' }
            }
            else { Log '  焦点元素不支持 ValuePattern，方法2 跳过。' }
        }
        catch { Log ("  方法2 出错: {0}" -f $_.Exception.Message) }
    }

    if ($okMethod -eq '') {
        Log '--- 方法3: 重新点击 + 逐字符 SendKeys 键入（不走剪贴板）---'
        try {
            Click-At -cx $tx -cy $ty
            $hwndFg = [DiagWin32]::GetForegroundWindow()
            $ime = [DiagWin32]::ImmGetDefaultIMEWnd($hwndFg)
            if ($ime -ne [IntPtr]::Zero) {
                [DiagWin32]::SendMessage($ime, [DiagWin32]::WM_IME_CONTROL, [IntPtr][DiagWin32]::IMC_SETOPENSTATUS, [IntPtr]0) | Out-Null
            }
            Start-Sleep -Milliseconds 80
            [System.Windows.Forms.SendKeys]::SendWait('^a'); Start-Sleep -Milliseconds 60
            [System.Windows.Forms.SendKeys]::SendWait('{DEL}'); Start-Sleep -Milliseconds 60
            foreach ($ch in $TestText.ToCharArray()) {
                [System.Windows.Forms.SendKeys]::SendWait([string]$ch)
                Start-Sleep -Milliseconds 60
            }
            Start-Sleep -Milliseconds 200
            $v = Read-BackValue -tag '方法3'
            if ($null -ne $v -and $v -match [regex]::Escape($TestText)) { $okMethod = '方法3(逐字符键入)' }
        }
        catch { Log ("  方法3 出错: {0}" -f $_.Exception.Message) }
    }

    Log '===== 诊断结论 ====='
    if ($okMethod -ne '') {
        Log ("  成功的方式: {0}" -f $okMethod)
        return $true
    }
    if ($canVerify) {
        Log '  三种方式回读均为空：键盘/剪贴板与 ValuePattern 都没能改变输入框的值。'
        Log '  可能：点击没落在真正可编辑控件 / 焦点被别的窗口抢走 / 该控件不响应模拟输入。'
    }
    else {
        Log ('  焦点控件不支持 ValuePattern，无法自动回读。请肉眼确认输入框里是否出现 ' + $TestText)
    }
    return $false
}

# ================= 主流程 =================
Log ("PowerShell 版本: {0}; ApartmentState: {1}" -f $PSVersionTable.PSVersion, [System.Threading.Thread]::CurrentThread.GetApartmentState())
Log ("项目根目录: {0}" -f $ProjectRoot)

$main = Find-Main
if ($null -eq $main) {
    Log "未找到主窗口。请确认 app 已打开并停在列表页，标题匹配 $MainWindowTitleRegex。"
    Log-AllTopWindows -tag '当前'
    exit 1
}
Log ("已找到主窗口: '{0}' hwnd={1}" -f $main.Current.Name, $main.Current.NativeWindowHandle)
$mr = $main.Current.BoundingRectangle
Log ("主窗口矩形: Left={0} Top={1} W={2} H={3}" -f $mr.Left, $mr.Top, $mr.Width, $mr.Height)

$cfgPath = Join-Path $ProjectRoot 'config.json'
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Captcha) {
    $exp = $cfg.exportCalibration
    if ($null -eq $exp) { $exp = $cfg.ExportCalibration }
    if ($null -eq $exp) { Log '配置缺少 exportCalibration，无法测验证码。'; exit 1 }

    Log '===== 验证码模式：先点击【获取最新】打开验证码弹窗 ====='
    Log-AllTopWindows -tag '点获取最新前'
    Bring-ToFront $main
    Log ("点击【获取最新】坐标 X={0} Y={1}" -f [int]$exp.GetLatestX, [int]$exp.GetLatestY)
    Click-At -cx ([int]$exp.GetLatestX) -cy ([int]$exp.GetLatestY)
    # 移开鼠标，避免悬停提示干扰
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point([int]($mr.Left + 40), [int]($mr.Top + $mr.Height * 0.85))

    Log '等待验证码弹窗出现（最多 12 秒，每秒枚举窗口）...'
    $captchaWin = $null
    for ($i = 1; $i -le 12; $i++) {
        Start-Sleep -Seconds 1
        foreach ($w in Get-RootWindows) {
            $t = $w.Current.Name
            if ($t -match '验证码|请输入验证码') { $captchaWin = $w; break }
        }
        if ($null -ne $captchaWin) {
            Log ("  第{0}秒：检测到验证码弹窗 '{1}' hwnd={2}" -f $i, $captchaWin.Current.Name, $captchaWin.Current.NativeWindowHandle)
            break
        }
        Log ("  第{0}秒：尚未发现验证码弹窗。" -f $i)
    }
    Log-AllTopWindows -tag '点获取最新后'

    $X = [int]$exp.CaptchaInputX
    $Y = [int]$exp.CaptchaInputY
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = '验证码输入框 (exportCalibration)' }

    # 目标窗口：优先用验证码弹窗（若它是独立窗口），否则用主窗口
    $targetWin = if ($null -ne $captchaWin) { $captchaWin } else { $main }
    if ($null -eq $captchaWin) {
        Log '  注意：没有找到标题含“验证码”的独立窗口。验证码可能是主窗口内的内嵌弹层；目标窗口用主窗口。'
    }

    [void](Test-InputAt -tx $X -ty $Y -tlabel $Label -targetWindow $targetWin)
}
else {
    if ($X -le 0 -or $Y -le 0) {
        $list = $cfg.listCalibration
        if ($null -eq $list) { $list = $cfg.ListCalibration }
        if ($null -ne $list -and $list.SearchBoxX -and $list.SearchBoxY) {
            $X = [int]$list.SearchBoxX
            $Y = [int]$list.SearchBoxY
            if ([string]::IsNullOrWhiteSpace($Label)) { $Label = '姓名搜索框 (listCalibration)' }
        }
        else { Log '配置没有 listCalibration.SearchBoxX/Y，请用 -X -Y 指定坐标。'; exit 1 }
    }
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = ("坐标({0},{1})" -f $X, $Y) }
    [void](Test-InputAt -tx $X -ty $Y -tlabel $Label -targetWindow $main)
}

Log ("详细日志已保存: {0}" -f $LogFile)
