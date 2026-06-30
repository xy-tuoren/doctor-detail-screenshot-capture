<#
.SYNOPSIS
  只读 UI Automation 控件树探测脚本。

.DESCRIPTION
  枚举机构端当前前台窗口（或按标题正则匹配的窗口）的 UIA 控件树，
  输出每个控件的 ControlType / Name / AutomationId / BoundingRectangle / 可用 Pattern，
  并汇总重点控件（Button/Edit/DataItem/ListItem/Hyperlink/Image/Text）。

  不点击、不写入、不删除任何东西，纯只读。

.PARAMETER State
  探测场景标注，仅用于输出文件名：home / list / detail / any。

.PARAMETER MainWindowTitleRegex
  主窗口标题正则（默认与 capture-doctor-details.ps1 一致）。
  若匹配到则探测该窗口；否则探测当前前台窗口。

.PARAMETER MaxDepth
  控件树枚举最大深度，默认 5。

.EXAMPLE
  # 机构端停在主页时运行
  .\probe-uia-tree.ps1 -State home
  # 机构端停在列表页时运行
  .\probe-uia-tree.ps1 -State list
  # 机构端停在某个医生详情窗口时运行
  .\probe-uia-tree.ps1 -State detail
#>
param(
    [string]$State = 'any',
    [string]$MainWindowTitleRegex = '医师电子化注册信息系统|机构版',
    [string]$DetailWindowTitleRegex = '信息展示|执业信息|详细信息',
    [int]$MaxDepth = 5
)

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$ErrorActionPreference = 'Continue'

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LogsDir = Join-Path $ProjectRoot 'logs'
if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}
$stamp = (Get-Date -Format 'yyyyMMdd_HHmmss')
$outFile = Join-Path $LogsDir ("uia-probe-{0}-{1}.txt" -f $State, $stamp)

# ---------- 找目标窗口 ----------
function Get-ForegroundHwnd {
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ProbeWin32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowTextLength(IntPtr hWnd);
}
"@
        $hwnd = [ProbeWin32]::GetForegroundWindow()
        $len = [ProbeWin32]::GetWindowTextLength($hwnd)
        $sb = New-Object System.Text.StringBuilder($len + 2)
        [void][ProbeWin32]::GetWindowText($hwnd, $sb, $sb.Capacity)
        return @{ Hwnd = $hwnd; Title = $sb.ToString() }
    }
    catch {
        return @{ Hwnd = [IntPtr]::Zero; Title = '' }
    }
}

function Find-WindowByTitleRegex {
    param([string]$Regex)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Window
    )
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        try {
            $name = [string]$w.Current.Name
            if ($name -match $Regex) { return $w }
        }
        catch { }
    }
    return $null
}

# 优先按标题正则找主窗口；找不到则用前台窗口
$target = $null
$targetTitle = ''
$targetHwnd = [IntPtr]::Zero

$byRegex = Find-WindowByTitleRegex -Regex $MainWindowTitleRegex
if ($null -ne $byRegex) {
    $target = $byRegex
    try { $targetTitle = [string]$byRegex.Current.Name } catch { }
    try { $targetHwnd = $byRegex.Current.NativeWindowHandle } catch { }
    $source = "标题正则匹配: $MainWindowTitleRegex"
}
else {
    $fg = Get-ForegroundHwnd
    if ($fg.Hwnd -ne [IntPtr]::Zero) {
        try {
            $target = [System.Windows.Automation.AutomationElement]::FromHandle($fg.Hwnd)
            $targetTitle = $fg.Title
            $targetHwnd = $fg.Hwnd
        }
        catch { }
    }
    $source = "前台窗口（未匹配主窗口正则，回退前台）"
}

if ($null -eq $target) {
    Write-Host "[ERROR] 未找到目标窗口。请先把机构端对应窗口切到前台再运行。" -ForegroundColor Red
    Write-Host "  主窗口正则: $MainWindowTitleRegex"
    return
}

# ---------- 控件树枚举 ----------
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

$allControls = New-Object System.Collections.ArrayList
$lines = New-Object System.Collections.ArrayList

function Format-Rect {
    param($r)
    if ($null -eq $r) { return "" }
    try {
        return ("{0},{1} {2}x{3}" -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
    }
    catch { return "" }
}

function Get-PatternMarks {
    param($el)
    $marks = @()
    foreach ($p in @(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [System.Windows.Automation.ValuePattern]::Pattern,
        [System.Windows.Automation.ScrollPattern]::Pattern,
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [System.Windows.Automation.TextPattern]::Pattern
    )) {
        try {
            $obj = $null
            if ($el.TryGetCurrentPattern($p, [ref]$obj) -and $null -ne $obj) {
                $marks += $p.ProgrammaticName.Replace('Pattern', '')
            }
        }
        catch { }
    }
    if ($marks.Count -gt 0) { return "[" + ($marks -join ',') + "]" }
    return ""
}

function Describe-Element {
    param($el)
    try {
        $ct = [string]$el.Current.ControlType.ProgrammaticName
    }
    catch { $ct = "?" }
    try {
        $name = [string]$el.Current.Name
    }
    catch { $name = "" }
    try {
        $aid = [string]$el.Current.AutomationId
    }
    catch { $aid = "" }
    try {
        $rect = $el.Current.BoundingRectangle
    }
    catch { $rect = $null }
    $marks = Get-PatternMarks -el $el
    return @{
        ControlType  = $ct
        Name         = $name
        AutomationId = $aid
        Rect         = Format-Rect -r $rect
        Marks        = $marks
        RawRect      = $rect
    }
}

function Walk-Tree {
    param($el, [int]$depth)
    if ($null -eq $el) { return }
    if ($depth -gt $MaxDepth) { return }

    $info = Describe-Element -el $el
    $indent = ("  " * $depth)
    $line = ("{0}{1} | name='{2}' | aid='{3}' | rect={4} {5}" -f `
            $indent, $info.ControlType, $info.Name, $info.AutomationId, $info.Rect, $info.Marks)
    [void]$lines.Add($line)

    $rec = [PSCustomObject]@{
        Depth        = $depth
        ControlType  = $info.ControlType
        Name         = $info.Name
        AutomationId = $info.AutomationId
        Rect         = $info.Rect
        Marks        = $info.Marks
    }
    [void]$allControls.Add($rec)

    try {
        $child = $walker.GetFirstChild($el)
        while ($null -ne $child) {
            Walk-Tree -el $child -depth ($depth + 1)
            try { $child = $walker.GetNextSibling($child) }
            catch { break }
        }
    }
    catch { }
}

# ---------- 运行探测 ----------
$header = @"
============================================================
UIA 探测 (State=$State)
时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
窗口来源: $source
窗口标题: $targetTitle
窗口句柄: $targetHwnd
最大深度: $MaxDepth
============================================================
"@
Write-Host $header
[void]$lines.Add($header)

Write-Host "正在枚举控件树（深度 <= $MaxDepth），请稍候..." -ForegroundColor Yellow
Walk-Tree -el $target -depth 0
Write-Host ("枚举完成，共 {0} 个控件。" -f $allControls.Count) -ForegroundColor Green

# ---------- 重点控件汇总 ----------
$focusTypes = 'Button', 'Edit', 'DataItem', 'ListItem', 'DataGrid', 'List', 'Hyperlink', 'Image', 'Pane', 'Text', 'MenuItem', 'TabItem', 'Custom'
$summary = New-Object System.Collections.ArrayList
[void]$summary.Add("")
[void]$summary.Add("========== 重点控件汇总 ==========")
foreach ($t in $focusTypes) {
    $matches = @($allControls | Where-Object { $_.ControlType -eq $t })
    if ($matches.Count -eq 0) { continue }
    [void]$summary.Add("")
    [void]$summary.Add(("--- {0} ({1} 个) ---" -f $t, $matches.Count))
    foreach ($m in $matches) {
        [void]$summary.Add(("  d{0} name='{1}' aid='{2}' rect={3} {4}" -f `
                $m.Depth, $m.Name, $m.AutomationId, $m.Rect, $m.Marks))
    }
}

# 额外：含「查看详」「主执业」「多执业」「搜索」「姓名」「验证」「获取」关键词的控件
[void]$summary.Add("")
[void]$summary.Add("========== 关键词命中控件 ==========")
$kwRegex = '查看详|主执业|多执业|外院|本院|搜索|姓名|查询|验证|获取|刷新|确定|导出|另存'
$kwMatches = @($allControls | Where-Object { $_.Name -match $kwRegex })
foreach ($m in $kwMatches) {
    [void]$summary.Add(("  d{0} {1} name='{2}' aid='{3}' rect={4} {5}" -f `
            $m.Depth, $m.ControlType, $m.Name, $m.AutomationId, $m.Rect, $m.Marks))
}

# ---------- 输出 ----------
$fullText = ($lines -join "`r`n") + "`r`n" + ($summary -join "`r`n")
Set-Content -Path $outFile -Value $fullText -Encoding UTF8

Write-Host ""
Write-Host "========== 控件树 ==========" -ForegroundColor Cyan
Write-Host ($lines -join "`r`n")
Write-Host ($summary -join "`r`n")
Write-Host ""
Write-Host ("完整结果已写入: {0}" -f $outFile) -ForegroundColor Green
Write-Host "请把该文件发回，用于制定 UIA 化改造方案。" -ForegroundColor Green
