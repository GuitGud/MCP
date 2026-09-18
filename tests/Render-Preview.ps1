[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$SteamMode
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) {
    $fileName = if ($SteamMode) { 'MCP-steam-preview.png' } else { 'MCP-preview.png' }
    $OutputPath = Join-Path $projectRoot $fileName
}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$xamlPath = Join-Path $projectRoot 'src\App.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$window.FindName('ComputerNameText').Text = 'MCP-DECK'
$window.FindName('SteamModeContainer').Visibility = 'Visible'
$window.FindName('SteamNav').Visibility = 'Visible'
$window.FindName('SteamQuickButton').Visibility = 'Visible'
$window.FindName('ProcessCountText').Text = '164'
$window.FindName('MemoryUsedText').Text = '8.4 GB'
$window.FindName('DriveCountText').Text = '3'
$window.FindName('SteamGameCountText').Text = '42'
$window.FindName('SteamStatusText').Text = 'installed locally'
$window.FindName('DriveList').ItemsSource = @(
    [pscustomobject]@{ Name = 'C:\'; Label = 'Windows'; UsedPct = 62.4; FreeText = '361.2 GB' },
    [pscustomobject]@{ Name = 'D:\'; Label = 'Game Library'; UsedPct = 78.1; FreeText = '448.7 GB' },
    [pscustomobject]@{ Name = 'E:\'; Label = 'Archive'; UsedPct = 34.8; FreeText = '1.3 TB' }
)

if ($SteamMode) {
    $window.Resources['AccentColor'] = [Windows.Media.ColorConverter]::ConvertFromString('#17B9FF')
    $window.Resources['AccentDimColor'] = [Windows.Media.ColorConverter]::ConvertFromString('#163E56')
    $window.Resources['AccentSoftColor'] = [Windows.Media.ColorConverter]::ConvertFromString('#0B2330')
    $window.FindName('SteamModeToggle').IsChecked = $true
}

$window.Show()
$window.UpdateLayout()

$width = [math]::Max(1, [int]$window.ActualWidth)
$height = [math]::Max(1, [int]$window.ActualHeight)
$bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
    $width,
    $height,
    96,
    96,
    [Windows.Media.PixelFormats]::Pbgra32
)
$bitmap.Render($window)
$encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create)
try { $encoder.Save($stream) } finally { $stream.Dispose() }
$window.Close()

Write-Output "Rendered $OutputPath"
