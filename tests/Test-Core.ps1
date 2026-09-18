[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Mcp.Core.psm1'
Import-Module $modulePath -Force

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-Equal '0 B' (Format-McpBytes 0) 'Zero-byte formatting failed.'
Assert-Equal '1.0 KB' (Format-McpBytes 1024) 'Kilobyte formatting failed.'
Assert-Equal '1.0 GB' (Format-McpBytes 1GB) 'Gigabyte formatting failed.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mcp-core-test-" + [guid]::NewGuid().ToString('N'))
try {
    $steamApps = Join-Path $testRoot 'steamapps'
    $gamePath = Join-Path $steamApps 'common\Test Game'
    $workshopPath = Join-Path $steamApps 'workshop\content\1234'
    $userDataPath = Join-Path $testRoot 'userdata\1001\1234'
    New-Item -ItemType Directory -Path $gamePath -Force | Out-Null
    New-Item -ItemType Directory -Path $workshopPath -Force | Out-Null
    New-Item -ItemType Directory -Path $userDataPath -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $workshopPath 'payload.bin'), [byte[]]::new(2048))
    [System.IO.File]::WriteAllBytes((Join-Path $userDataPath 'cloud-save.bin'), [byte[]]::new(1024))

    $manifest = @'
"AppState"
{
    "appid"        "1234"
    "name"         "MCP Test Game"
    "installdir"   "Test Game"
    "SizeOnDisk"   "4096"
}
'@
    Set-Content -LiteralPath (Join-Path $steamApps 'appmanifest_1234.acf') -Value $manifest -Encoding UTF8

    $libraries = @(Get-McpSteamLibraries -SteamPath $testRoot)
    Assert-Equal 1 $libraries.Count 'Steam root library was not detected.'

    $games = @(Get-McpSteamGames -SteamPath $testRoot)
    Assert-Equal 1 $games.Count 'Steam manifest was not parsed.'
    Assert-Equal 'MCP Test Game' $games[0].Name 'Game name was parsed incorrectly.'
    Assert-Equal 4096 $games[0].InstallBytes 'Install size was parsed incorrectly.'
    Assert-Equal 3072 $games[0].DataBytes 'Game data size was calculated incorrectly.'
    Assert-Equal 1024 $games[0].UserDataBytes 'Steam user data size was calculated incorrectly.'
    Assert-Equal 7168 $games[0].TotalBytes 'Total game footprint was calculated incorrectly.'
    Assert-True (Test-Path -LiteralPath $games[0].GamePath) 'Game install path is incorrect.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'MCP core tests passed.'
