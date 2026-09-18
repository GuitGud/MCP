param(
    [switch]$SmokeTest,
    [string]$ScreenshotPath,
    [string]$InitialPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName Microsoft.VisualBasic

$appRoot = Split-Path -Parent $PSScriptRoot
$coreModule = Join-Path $PSScriptRoot 'Mcp.Core.psm1'
$xamlPath = Join-Path $PSScriptRoot 'App.xaml'
Import-Module $coreModule -Force

[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$namedControls = [regex]::Matches(($xaml.OuterXml), 'x:Name="([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Select-Object -Unique
foreach ($controlName in $namedControls) {
    Set-Variable -Name $controlName -Value $window.FindName($controlName) -Scope Script
}

$script:currentPath = if ($InitialPath) {
    $InitialPath
}
elseif ($SmokeTest -or $ScreenshotPath) {
    $appRoot
}
elseif ($env:USERPROFILE) {
    $env:USERPROFILE
}
else {
    (Get-Location).Path
}

# Some managed or redirected Windows profiles deny enumeration at the profile
# root. Fall back to the application folder instead of failing startup.
try {
    Get-ChildItem -LiteralPath $script:currentPath -Force -ErrorAction Stop | Select-Object -First 1 | Out-Null
}
catch {
    $script:currentPath = $appRoot
}
$script:pathHistory = [System.Collections.Generic.List[string]]::new()
$script:allFiles = @()
$script:allProcesses = @()
$script:previousCpu = @{}
$script:lastCpuSample = [datetime]::UtcNow
$script:steamPath = $null
$script:steamGames = @()
$script:steamJob = $null
$script:processRefreshInProgress = $false
$script:captureError = $null

function Set-McpStatus {
    param([string]$Message)
    $script:StatusText.Text = $Message.ToUpperInvariant()
}

function Show-McpError {
    param([string]$Message)
    Set-McpStatus $Message
    [System.Windows.MessageBox]::Show(
        $window,
        $Message,
        'Master Control Program',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
    ) | Out-Null
}

function Set-McpTheme {
    param([bool]$SteamMode)

    if ($SteamMode) {
        $colors = @('#17B9FF', '#163E56', '#0B2330')
        $window.Title = 'Master Control Program - Steam Mode'
        Set-McpStatus 'Steam mode online'
    }
    else {
        $colors = @('#FF2B35', '#441219', '#221014')
        $window.Title = 'Master Control Program'
        Set-McpStatus 'MCP mode online'
    }

    $window.Resources['AccentColor'] = [Windows.Media.ColorConverter]::ConvertFromString($colors[0])
    $window.Resources['AccentDimColor'] = [Windows.Media.ColorConverter]::ConvertFromString($colors[1])
    $window.Resources['AccentSoftColor'] = [Windows.Media.ColorConverter]::ConvertFromString($colors[2])
}

function Show-McpPage {
    param(
        [Parameter(Mandatory)][Windows.FrameworkElement]$Page,
        [Parameter(Mandatory)][string]$Context
    )

    foreach ($candidate in @($OverviewPage, $FilesPage, $ProcessesPage, $SteamPage)) {
        $candidate.Visibility = if ($candidate -eq $Page) { 'Visible' } else { 'Collapsed' }
    }
    $TitleContext.Text = $Context.ToUpperInvariant()
}

function Update-McpOverview {
    try {
        $drives = @(Get-McpDrives)
        $DriveList.ItemsSource = $drives
        $DriveCountText.Text = $drives.Count.ToString()

        if ($script:allProcesses.Count -eq 0) {
            $script:allProcesses = @(Get-McpProcesses)
        }
        $ProcessCountText.Text = $script:allProcesses.Count.ToString('N0')
        [long]$memory = ($script:allProcesses | Measure-Object -Property MemoryBytes -Sum).Sum
        $MemoryUsedText.Text = Format-McpBytes $memory
        Set-McpStatus 'System overview refreshed'
    }
    catch {
        Set-McpStatus "Overview refresh failed: $($_.Exception.Message)"
    }
}

function New-McpTreeHeader {
    param([string]$Text, [bool]$IsDrive = $false)
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    $icon = [Windows.Controls.TextBlock]::new()
    $icon.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
    $icon.Text = if ($IsDrive) { [char]0xEDA2 } else { [char]0xE8B7 }
    $icon.Foreground = $window.FindResource('AccentBrush')
    $icon.Margin = '0,0,8,0'
    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = $Text
    [void]$panel.Children.Add($icon)
    [void]$panel.Children.Add($label)
    return $panel
}

function Add-McpTreePlaceholder {
    param([Windows.Controls.TreeViewItem]$Node)
    $placeholder = [Windows.Controls.TreeViewItem]::new()
    $placeholder.Header = 'Loading...'
    $placeholder.Tag = '__placeholder__'
    [void]$Node.Items.Add($placeholder)
}

function Expand-McpTreeNode {
    param([Windows.Controls.TreeViewItem]$Node)

    if ($Node.Items.Count -ne 1 -or $Node.Items[0].Tag -ne '__placeholder__') { return }
    $Node.Items.Clear()

    try {
        foreach ($directory in Get-ChildItem -LiteralPath ([string]$Node.Tag) -Directory -Force -ErrorAction Stop | Sort-Object Name) {
            $child = [Windows.Controls.TreeViewItem]::new()
            $child.Header = New-McpTreeHeader -Text $directory.Name
            $child.Tag = $directory.FullName
            Add-McpTreePlaceholder -Node $child
            $child.Add_Expanded({ Expand-McpTreeNode -Node $this })
            $child.Add_Selected({
                param($sender, $eventArgs)
                if ($eventArgs.OriginalSource -eq $sender) { Open-McpFolder -Path ([string]$sender.Tag) }
            })
            [void]$Node.Items.Add($child)
        }
    }
    catch {
        Set-McpStatus "Cannot read $($Node.Tag)"
    }
}

function Initialize-McpFileTree {
    $FileTree.Items.Clear()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $node = [Windows.Controls.TreeViewItem]::new()
        $label = if ($drive.VolumeLabel) { "$($drive.Name)  $($drive.VolumeLabel)" } else { $drive.Name }
        $node.Header = New-McpTreeHeader -Text $label -IsDrive $true
        $node.Tag = $drive.RootDirectory.FullName
        Add-McpTreePlaceholder -Node $node
        $node.Add_Expanded({ Expand-McpTreeNode -Node $this })
        $node.Add_Selected({
            param($sender, $eventArgs)
            if ($eventArgs.OriginalSource -eq $sender) { Open-McpFolder -Path ([string]$sender.Tag) }
        })
        [void]$FileTree.Items.Add($node)
    }
}

function Apply-McpFileFilter {
    $query = $FileSearchBox.Text.Trim()
    $filtered = if ($query) {
        @($script:allFiles | Where-Object { $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    else { @($script:allFiles) }
    $FileGrid.ItemsSource = $filtered
    Set-McpStatus "$($filtered.Count) items shown"
}

function Open-McpFolder {
    param([Parameter(Mandatory)][string]$Path, [bool]$AddToHistory = $true)

    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw 'The path is not a folder.' }
        if ($AddToHistory -and $script:currentPath -and $script:currentPath -ne $resolved) {
            $script:pathHistory.Add($script:currentPath)
        }
        $script:currentPath = $resolved
        $PathBox.Text = $resolved
        $script:allFiles = @(Get-McpDirectoryEntries -Path $resolved | Sort-Object @{ Expression = 'IsFolder'; Descending = $true }, Name)
        Apply-McpFileFilter
        $FileSelectionText.Text = "$($script:allFiles.Count) items // $resolved"
    }
    catch {
        Show-McpError "Unable to open this location.`n`n$($_.Exception.Message)"
    }
}

function Open-McpFilesAt {
    param([Parameter(Mandatory)][string]$Path)
    $FilesNav.IsChecked = $true
    Show-McpPage -Page $FilesPage -Context 'File tree'
    Open-McpFolder -Path $Path
}

function Get-McpSelectedFile {
    return $FileGrid.SelectedItem
}

function Test-McpLeafName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -in @('.', '..')) { return $false }
    if ([System.IO.Path]::GetFileName($Name) -ne $Name) { return $false }
    return $Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -lt 0
}

function Apply-McpProcessFilter {
    $query = $ProcessSearchBox.Text.Trim()
    $filtered = if ($query) {
        @($script:allProcesses | Where-Object {
            $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.Description.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$_.Id).Contains($query)
        })
    }
    else { @($script:allProcesses) }
    $ProcessGrid.ItemsSource = $filtered
}

function Update-McpProcesses {
    if ($script:processRefreshInProgress) { return }
    $script:processRefreshInProgress = $true
    try {
        $now = [datetime]::UtcNow
        $elapsed = [math]::Max(0.1, ($now - $script:lastCpuSample).TotalSeconds)
        $cores = [Environment]::ProcessorCount
        $nextCpu = @{}
        $processes = @(Get-McpProcesses)
        foreach ($process in $processes) {
            $cpuPercent = 0.0
            if ($script:previousCpu.ContainsKey($process.Id)) {
                $delta = $process.CpuSeconds - [double]$script:previousCpu[$process.Id]
                $cpuPercent = [math]::Max(0, [math]::Min(100, ($delta / $elapsed / $cores) * 100))
            }
            $process | Add-Member -NotePropertyName CpuPercent -NotePropertyValue ([math]::Round($cpuPercent, 1))
            $nextCpu[$process.Id] = $process.CpuSeconds
        }
        $script:previousCpu = $nextCpu
        $script:lastCpuSample = $now
        $script:allProcesses = @($processes | Sort-Object MemoryBytes -Descending)
        Apply-McpProcessFilter
        [long]$memory = ($processes | Measure-Object -Property MemoryBytes -Sum).Sum
        $ProcessSummaryText.Text = "$($processes.Count) ACTIVE"
        $ProcessMemoryText.Text = "$(Format-McpBytes $memory) MEMORY"
        $ProcessCountText.Text = $processes.Count.ToString('N0')
        $MemoryUsedText.Text = Format-McpBytes $memory
    }
    catch {
        Set-McpStatus "Process refresh failed: $($_.Exception.Message)"
    }
    finally {
        $script:processRefreshInProgress = $false
    }
}

function Apply-McpSteamFilter {
    $query = $SteamSearchBox.Text.Trim()
    $filtered = if ($query) {
        @($script:steamGames | Where-Object {
            $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.AppId.Contains($query)
        })
    }
    else { @($script:steamGames) }
    $SteamGrid.ItemsSource = $filtered
}

function Start-McpSteamScan {
    if (-not $script:steamPath) { return }
    if ($script:steamJob -and $script:steamJob.State -eq 'Running') {
        Set-McpStatus 'Steam scan already running'
        return
    }
    if ($script:steamJob) { Remove-Job -Job $script:steamJob -Force -ErrorAction SilentlyContinue }

    $SteamCountSummary.Text = 'SCANNING LIBRARIES'
    $SteamSizeSummary.Text = 'CALCULATING STORAGE'
    $RefreshSteamButton.IsEnabled = $false
    Set-McpStatus 'Reading Steam manifests and data folders'
    $moduleForJob = $coreModule
    $pathForJob = $script:steamPath
    $script:steamJob = Start-Job -ScriptBlock {
        param($ModulePath, $SteamRoot)
        Import-Module $ModulePath -Force
        @(Get-McpSteamGames -SteamPath $SteamRoot | Sort-Object Name)
    } -ArgumentList $moduleForJob, $pathForJob
}

function Complete-McpSteamScan {
    if (-not $script:steamJob -or $script:steamJob.State -eq 'Running') { return }
    try {
        if ($script:steamJob.State -eq 'Completed') {
            $script:steamGames = @(Receive-Job -Job $script:steamJob -ErrorAction Stop)
            Apply-McpSteamFilter
            [long]$total = ($script:steamGames | Measure-Object -Property TotalBytes -Sum).Sum
            $SteamGameCountText.Text = $script:steamGames.Count.ToString('N0')
            $SteamStatusText.Text = 'installed locally'
            $SteamCountSummary.Text = "$($script:steamGames.Count) INSTALLED GAMES"
            $SteamSizeSummary.Text = "$(Format-McpBytes $total) TOTAL FOOTPRINT"
            Set-McpStatus 'Steam library scan complete'
        }
        else {
            $reason = ($script:steamJob.ChildJobs[0].JobStateInfo.Reason.Message)
            if (-not $reason) { $reason = 'Unknown scan error' }
            Set-McpStatus "Steam scan failed: $reason"
        }
    }
    catch {
        Set-McpStatus "Steam scan failed: $($_.Exception.Message)"
    }
    finally {
        Remove-Job -Job $script:steamJob -Force -ErrorAction SilentlyContinue
        $script:steamJob = $null
        $RefreshSteamButton.IsEnabled = $true
    }
}

function Initialize-McpSteam {
    $script:steamPath = Get-McpSteamPath
    if ($script:steamPath) {
        $SteamModeContainer.Visibility = 'Visible'
        $SteamNav.Visibility = 'Visible'
        $SteamQuickButton.Visibility = 'Visible'
        $SteamPathText.Text = $script:steamPath
        $SteamGameCountText.Text = '...'
        $SteamStatusText.Text = 'client detected'
        Start-McpSteamScan
    }
    else {
        $SteamGameCountText.Text = '0'
        $SteamStatusText.Text = 'client not detected'
        $SteamModeContainer.Visibility = 'Collapsed'
        $SteamNav.Visibility = 'Collapsed'
        Set-McpStatus 'Steam not detected - standard MCP mode'
    }
}

# Window chrome
$TitleBar.Add_MouseLeftButtonDown({
    $eventArgs = $args[1]
    if ($eventArgs.ClickCount -eq 2) {
        $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    }
    else { $window.DragMove() }
})
$MinimizeButton.Add_Click({ $window.WindowState = 'Minimized' })
$MaximizeButton.Add_Click({ $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$CloseButton.Add_Click({ $window.Close() })

# Navigation
$OverviewNav.Add_Checked({ Show-McpPage -Page $OverviewPage -Context 'System overview'; Update-McpOverview })
$FilesNav.Add_Checked({ Show-McpPage -Page $FilesPage -Context 'File tree' })
$ProcessesNav.Add_Checked({ Show-McpPage -Page $ProcessesPage -Context 'Background processes'; Update-McpProcesses })
$SteamNav.Add_Checked({ Show-McpPage -Page $SteamPage -Context 'Steam storage' })
$SteamModeToggle.Add_Checked({ Set-McpTheme -SteamMode $true })
$SteamModeToggle.Add_Unchecked({ Set-McpTheme -SteamMode $false })

# Overview
$RefreshOverviewButton.Add_Click({ Update-McpProcesses; Update-McpOverview })
$DesktopQuickButton.Add_Click({ Open-McpFilesAt -Path ([Environment]::GetFolderPath('Desktop')) })
$DocumentsQuickButton.Add_Click({ Open-McpFilesAt -Path ([Environment]::GetFolderPath('MyDocuments')) })
$DownloadsQuickButton.Add_Click({
    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    Open-McpFilesAt -Path $downloads
})
$SteamQuickButton.Add_Click({ if ($script:steamPath) { Open-McpFilesAt -Path $script:steamPath } })

# File tree actions
$PathGoButton.Add_Click({ Open-McpFolder -Path $PathBox.Text })
$PathBox.Add_KeyDown({ if ($args[1].Key -eq 'Enter') { Open-McpFolder -Path $PathBox.Text } })
$FileSearchBox.Add_TextChanged({ Apply-McpFileFilter })
$FileBackButton.Add_Click({
    if ($script:pathHistory.Count -gt 0) {
        $index = $script:pathHistory.Count - 1
        $target = $script:pathHistory[$index]
        $script:pathHistory.RemoveAt($index)
        Open-McpFolder -Path $target -AddToHistory $false
    }
})
$FileUpButton.Add_Click({
    $parent = [System.IO.Directory]::GetParent($script:currentPath)
    if ($parent) { Open-McpFolder -Path $parent.FullName }
})
$FileGrid.Add_SelectionChanged({
    $selected = Get-McpSelectedFile
    if ($selected) { $FileSelectionText.Text = "$($selected.Type) // $($selected.FullPath)" }
})
$FileGrid.Add_MouseDoubleClick({
    $selected = Get-McpSelectedFile
    if (-not $selected) { return }
    if ($selected.IsFolder) { Open-McpFolder -Path $selected.FullPath }
    else { Start-Process -FilePath $selected.FullPath -ErrorAction SilentlyContinue }
})
$OpenFileButton.Add_Click({
    $selected = Get-McpSelectedFile
    if (-not $selected) { return }
    if ($selected.IsFolder) { Open-McpFolder -Path $selected.FullPath }
    else { Start-Process -FilePath $selected.FullPath -ErrorAction SilentlyContinue }
})
$CopyPathButton.Add_Click({
    $selected = Get-McpSelectedFile
    $copyValue = if ($selected) { $selected.FullPath } else { $script:currentPath }
    [Windows.Clipboard]::SetText($copyValue)
    Set-McpStatus 'Path copied to clipboard'
})
$NewFolderButton.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Name the new folder:', 'MCP // New Folder', 'New folder')
    if ($name) {
        if (-not (Test-McpLeafName -Name $name)) {
            Show-McpError 'Enter a valid folder name without path separators.'
            return
        }
        try {
            $target = Join-Path $script:currentPath $name
            New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
            Open-McpFolder -Path $script:currentPath -AddToHistory $false
            Set-McpStatus "Folder created: $name"
        }
        catch { Show-McpError "Could not create the folder.`n`n$($_.Exception.Message)" }
    }
})
$RenameFileButton.Add_Click({
    $selected = Get-McpSelectedFile
    if (-not $selected) { return }
    $newName = [Microsoft.VisualBasic.Interaction]::InputBox('Enter a new name:', 'MCP // Rename', $selected.Name)
    if ($newName -and $newName -ne $selected.Name) {
        if (-not (Test-McpLeafName -Name $newName)) {
            Show-McpError 'Enter a valid item name without path separators.'
            return
        }
        try {
            Rename-Item -LiteralPath $selected.FullPath -NewName $newName -ErrorAction Stop
            Open-McpFolder -Path $script:currentPath -AddToHistory $false
            Set-McpStatus "Renamed to $newName"
        }
        catch { Show-McpError "Could not rename this item.`n`n$($_.Exception.Message)" }
    }
})
$RecycleFileButton.Add_Click({
    $selected = Get-McpSelectedFile
    if (-not $selected) { return }
    $answer = [System.Windows.MessageBox]::Show(
        $window,
        "Send '$($selected.Name)' to the Recycle Bin?",
        'MCP // Confirm recycle',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        if ($selected.IsFolder) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $selected.FullPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        }
        else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $selected.FullPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        }
        Open-McpFolder -Path $script:currentPath -AddToHistory $false
        Set-McpStatus 'Item moved to Recycle Bin'
    }
    catch { Show-McpError "Could not recycle this item.`n`n$($_.Exception.Message)" }
})

# Process actions
$ProcessSearchBox.Add_TextChanged({ Apply-McpProcessFilter })
$RefreshProcessesButton.Add_Click({ Update-McpProcesses; Set-McpStatus 'Process list refreshed' })
$ProcessGrid.Add_SelectionChanged({
    $selected = $ProcessGrid.SelectedItem
    if ($selected) { $ProcessSelectionText.Text = "$($selected.Name) // PID $($selected.Id) // $($selected.Path)" }
})
$OpenProcessLocationButton.Add_Click({
    $selected = $ProcessGrid.SelectedItem
    if (-not $selected -or -not $selected.Path) {
        Show-McpError 'Windows does not expose a file location for this process.'
        return
    }
    Start-Process explorer.exe -ArgumentList "/select,`"$($selected.Path)`""
})
$EndProcessButton.Add_Click({
    $selected = $ProcessGrid.SelectedItem
    if (-not $selected) { return }
    $protectedProcesses = @('system', 'registry', 'smss', 'csrss', 'wininit', 'services', 'lsass', 'winlogon')
    if ($selected.Id -le 4 -or $selected.Id -eq $PID -or $selected.Name.ToLowerInvariant() -in $protectedProcesses) {
        Show-McpError 'MCP will not terminate this protected process.'
        return
    }
    $answer = [System.Windows.MessageBox]::Show(
        $window,
        "End '$($selected.Name)' (PID $($selected.Id))?`n`nUnsaved work in that application may be lost.",
        'MCP // Confirm end task',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        Stop-Process -Id $selected.Id -Force -ErrorAction Stop
        Set-McpStatus "Ended $($selected.Name)"
        Update-McpProcesses
    }
    catch { Show-McpError "Could not end this process.`n`n$($_.Exception.Message)" }
})

# Steam actions
$SteamSearchBox.Add_TextChanged({ Apply-McpSteamFilter })
$RefreshSteamButton.Add_Click({ Start-McpSteamScan })
$SteamGrid.Add_SelectionChanged({
    $selected = $SteamGrid.SelectedItem
    if ($selected) {
        $details = "INSTALL $($selected.Install) // WORKSHOP $(Format-McpBytes $selected.WorkshopBytes) // SHADERS $(Format-McpBytes $selected.ShaderBytes) // USER DATA $(Format-McpBytes $selected.UserDataBytes) // TOTAL $($selected.Total)"
        $SteamSelectionText.Text = $details
    }
})
$OpenSteamGameButton.Add_Click({
    $selected = $SteamGrid.SelectedItem
    if ($selected -and $selected.GamePath -and (Test-Path -LiteralPath $selected.GamePath)) {
        Start-Process explorer.exe -ArgumentList "`"$($selected.GamePath)`""
    }
})
$LaunchSteamGameButton.Add_Click({
    $selected = $SteamGrid.SelectedItem
    if ($selected) { Start-Process "steam://rungameid/$($selected.AppId)" }
})

# Timers keep process data live and poll the isolated Steam scan job.
$processTimer = [Windows.Threading.DispatcherTimer]::new()
$processTimer.Interval = [timespan]::FromSeconds(4)
$processTimer.Add_Tick({ Update-McpProcesses })
$processTimer.Start()

$steamTimer = [Windows.Threading.DispatcherTimer]::new()
$steamTimer.Interval = [timespan]::FromMilliseconds(600)
$steamTimer.Add_Tick({ Complete-McpSteamScan })
$steamTimer.Start()

$window.Add_Closed({
    $processTimer.Stop()
    $steamTimer.Stop()
    # Do not wait on a deep directory scan during shutdown. Windows PowerShell
    # owns the background job process and tears it down with this session.
})

# Initial state
$ComputerNameText.Text = $env:COMPUTERNAME
Initialize-McpFileTree
Open-McpFolder -Path $script:currentPath -AddToHistory $false
Update-McpProcesses
Update-McpOverview
Initialize-McpSteam

if ($SmokeTest -or $ScreenshotPath) {
    $script:screenshotTarget = $ScreenshotPath
    $script:captureError = $null
    $script:captureTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:captureTimer.Interval = [timespan]::FromSeconds(1)
    $script:captureTimer.Add_Tick({
        $script:captureTimer.Stop()
        try {
            if ($script:screenshotTarget) {
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
                $stream = [System.IO.File]::Open($script:screenshotTarget, [System.IO.FileMode]::Create)
                try { $encoder.Save($stream) } finally { $stream.Dispose() }
            }
        }
        catch {
            $script:captureError = $_
        }
        finally {
            $window.Close()
        }
    })
    $script:captureTimer.Start()
}

[void]$window.ShowDialog()

if ($script:captureError) {
    throw $script:captureError
}
