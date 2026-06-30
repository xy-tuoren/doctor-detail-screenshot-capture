# 对用户提供的详情截图跑 WinRT OCR，验证识别能力
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$imgPath = 'C:\Users\28958\.cursor\projects\c-Users-28958-doctor-detail-screenshot-capture\assets\c__Users_28958_AppData_Roaming_Cursor_User_workspaceStorage_625213d1c2cc400f3aaf9e2c65f06927_images_image-190e8425-5694-487c-9cb5-20e884352783.png'
if (-not (Test-Path $imgPath)) { throw "图片不存在: $imgPath" }

$script:WinRtAsTaskGeneric = $null
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

[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language('zh-Hans'))) }
if ($null -eq $engine) { throw 'WinRT OCR engine 不可用' }

$bmp = [System.Drawing.Image]::FromFile($imgPath)
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$bytes = $ms.ToArray()
$bmp.Dispose(); $ms.Dispose()

$stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
$writer = New-Object Windows.Storage.Streams.DataWriter($stream)
$writer.WriteBytes($bytes)
Invoke-WinRtAwait ($writer.StoreAsync()) ([uint32]) | Out-Null
$writer.DetachStream() | Out-Null
$stream.Seek(0)
$decoder = Invoke-WinRtAwait ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$softwareBitmap = Invoke-WinRtAwait ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$result = Invoke-WinRtAwait ($engine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
$text = $result.Text
"=== WinRT OCR 识别结果 ==="
$text
"=== 提取证书编码 ==="
$compact = ($text -replace '\s+', '')
if ($compact -match '执业证书编码[:：]?([0-9A-Za-z]+)') {
    "匹配成功: $($Matches[1])"
} else {
    "未匹配到「执业证书编码」"
}
"含「编码」: $($compact -match '编码')  含「编号」: $($compact -match '编号')"
"含「执业证书」: $($compact -match '执业证书')"
