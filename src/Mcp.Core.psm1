Set-StrictMode -Version Latest

function Format-McpBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Bytes)

    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return [string]::Format($culture, '{0:N1} KB', ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return [string]::Format($culture, '{0:N1} MB', ($Bytes / 1MB)) }
    if ($Bytes -lt 1TB) { return [string]::Format($culture, '{0:N1} GB', ($Bytes / 1GB)) }
    return [string]::Format($culture, '{0:N2} TB', ($Bytes / 1TB))
}

function Get-McpDirectorySize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [long]0 }

    [long]$total = 0
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($current)) {
                try { $total += [System.IO.FileInfo]::new($file).Length } catch { }
            }
            foreach ($directory in [System.IO.Directory]::EnumerateDirectories($current)) {
                try {
                    $info = [System.IO.DirectoryInfo]::new($directory)
                    if (-not ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                        $pending.Push($directory)
                    }
                }
                catch { }
            }
        }
        catch { }
    }

    return $total
}

function Get-McpDrives {
    [CmdletBinding()]
    param()

    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $used = [long]($drive.TotalSize - $drive.AvailableFreeSpace)
        [pscustomobject]@{
            Name       = $drive.Name
            Label      = if ($drive.VolumeLabel) { $drive.VolumeLabel } else { 'Local Disk' }
            DriveType  = $drive.DriveType.ToString()
            TotalBytes = [long]$drive.TotalSize
            FreeBytes  = [long]$drive.AvailableFreeSpace
            UsedBytes  = $used
            UsedText   = Format-McpBytes $used
            FreeText   = Format-McpBytes ([long]$drive.AvailableFreeSpace)
            TotalText  = Format-McpBytes ([long]$drive.TotalSize)
            UsedPct    = if ($drive.TotalSize -gt 0) { [math]::Round(($used / $drive.TotalSize) * 100, 1) } else { 0 }
        }
    }
}

function Get-McpDirectoryEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Folder not found: $Path"
    }

    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop
    foreach ($item in $items) {
        $isFolder = $item.PSIsContainer
        [pscustomobject]@{
            Icon         = if ($isFolder) { [char]0xE8B7 } else { [char]0xE7C3 }
            Name         = $item.Name
            Type         = if ($isFolder) { 'Folder' } elseif ($item.Extension) { "$($item.Extension.TrimStart('.').ToUpperInvariant()) file" } else { 'File' }
            Size         = if ($isFolder) { '' } else { Format-McpBytes ([long]$item.Length) }
            SizeBytes    = if ($isFolder) { [long]0 } else { [long]$item.Length }
            Modified     = $item.LastWriteTime.ToString('yyyy-MM-dd  HH:mm')
            ModifiedDate = $item.LastWriteTime
            FullPath     = $item.FullName
            IsFolder     = $isFolder
            Attributes   = $item.Attributes.ToString()
        }
    }
}

function Get-McpProcesses {
    [CmdletBinding()]
    param()

    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try { $path = $process.Path } catch { $path = $null }
        try { $started = $process.StartTime } catch { $started = $null }
        try { $cpu = [double]$process.CPU } catch { $cpu = 0 }
        try { $description = $process.Description } catch { $description = '' }
        if (-not $description) { $description = '' }
        [pscustomobject]@{
            Name        = $process.ProcessName
            Id          = $process.Id
            Description = $description
            CpuSeconds  = $cpu
            MemoryBytes = [long]$process.WorkingSet64
            Memory      = Format-McpBytes ([long]$process.WorkingSet64)
            Threads     = $process.Threads.Count
            Started     = if ($started) { $started.ToString('yyyy-MM-dd HH:mm') } else { 'System' }
            Path        = $path
            Responding  = $process.Responding
        }
    }
}

function Get-McpSteamPath {
    [CmdletBinding()]
    param()

    $candidates = [System.Collections.Generic.List[string]]::new()
    $registryPaths = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )

    foreach ($key in $registryPaths) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($property in @('SteamPath', 'InstallPath')) {
                if ($props.$property) { $candidates.Add([string]$props.$property) }
            }
        }
        catch { }
    }

    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Steam')) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Steam')) }

    return $candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'steam.exe') -PathType Leaf) } |
        Select-Object -First 1
}

function Get-McpVdfValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    $match = [regex]::Match($Text, '(?im)^\s*"' + $escapedKey + '"\s+"([^"]*)"')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-McpSteamLibraries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SteamPath)

    $libraries = [System.Collections.Generic.List[string]]::new()
    $libraries.Add($SteamPath)
    $libraryFile = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'

    if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
        try {
            $text = Get-Content -LiteralPath $libraryFile -Raw -ErrorAction Stop
            foreach ($match in [regex]::Matches($text, '(?im)^\s*"path"\s+"([^"]+)"')) {
                $path = $match.Groups[1].Value -replace '\\\\', '\'
                if ($path) { $libraries.Add($path) }
            }
        }
        catch { }
    }

    return $libraries |
        ForEach-Object { try { [System.IO.Path]::GetFullPath($_) } catch { $_ } } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'steamapps') -PathType Container } |
        Select-Object -Unique
}

function Get-McpSteamGames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SteamPath)

    foreach ($library in Get-McpSteamLibraries -SteamPath $SteamPath) {
        $steamApps = Join-Path $library 'steamapps'
        foreach ($manifest in Get-ChildItem -LiteralPath $steamApps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
            try {
                $text = Get-Content -LiteralPath $manifest.FullName -Raw -ErrorAction Stop
                $appId = Get-McpVdfValue -Text $text -Key 'appid'
                $name = Get-McpVdfValue -Text $text -Key 'name'
                $installDir = Get-McpVdfValue -Text $text -Key 'installdir'
                $declaredSize = Get-McpVdfValue -Text $text -Key 'SizeOnDisk'

                if (-not $appId -or -not $name) { continue }

                $gamePath = if ($installDir) { Join-Path $steamApps "common\$installDir" } else { $null }
                [long]$installBytes = 0
                if ($declaredSize -as [long]) { $installBytes = [long]$declaredSize }
                elseif ($gamePath) { $installBytes = Get-McpDirectorySize -Path $gamePath }

                $workshopPath = Join-Path $steamApps "workshop\content\$appId"
                $shaderPath = Join-Path $steamApps "shadercache\$appId"
                $compatPath = Join-Path $steamApps "compatdata\$appId"
                [long]$workshopBytes = Get-McpDirectorySize -Path $workshopPath
                [long]$shaderBytes = Get-McpDirectorySize -Path $shaderPath
                [long]$compatBytes = Get-McpDirectorySize -Path $compatPath
                [long]$userDataBytes = 0
                $userDataRoot = Join-Path $SteamPath 'userdata'
                if (Test-Path -LiteralPath $userDataRoot -PathType Container) {
                    foreach ($account in Get-ChildItem -LiteralPath $userDataRoot -Directory -ErrorAction SilentlyContinue) {
                        $userGamePath = Join-Path $account.FullName $appId
                        $userDataBytes += Get-McpDirectorySize -Path $userGamePath
                    }
                }
                [long]$dataBytes = $workshopBytes + $shaderBytes + $compatBytes + $userDataBytes
                [long]$totalBytes = $installBytes + $dataBytes

                [pscustomobject]@{
                    Name          = $name
                    AppId         = $appId
                    Install       = Format-McpBytes $installBytes
                    Data          = Format-McpBytes $dataBytes
                    Total         = Format-McpBytes $totalBytes
                    InstallBytes  = $installBytes
                    DataBytes     = $dataBytes
                    TotalBytes    = $totalBytes
                    WorkshopBytes = $workshopBytes
                    ShaderBytes   = $shaderBytes
                    CompatBytes   = $compatBytes
                    UserDataBytes = $userDataBytes
                    GamePath      = $gamePath
                    Library       = $library
                    Manifest      = $manifest.FullName
                }
            }
            catch { }
        }
    }
}

Export-ModuleMember -Function @(
    'Format-McpBytes',
    'Get-McpDirectorySize',
    'Get-McpDrives',
    'Get-McpDirectoryEntries',
    'Get-McpProcesses',
    'Get-McpSteamPath',
    'Get-McpSteamLibraries',
    'Get-McpSteamGames'
)
