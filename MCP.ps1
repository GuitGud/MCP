[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$entryPoint = Join-Path $PSScriptRoot 'src\MasterControlProgram.ps1'

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
    [System.Windows.MessageBox]::Show(
        "MCP could not find its application files.`n`nExpected: $entryPoint",
        'Master Control Program',
        'OK',
        'Error'
    ) | Out-Null
    exit 1
}

try {
    & $entryPoint
}
catch {
    $message = "MCP encountered an unexpected error:`n`n$($_.Exception.Message)"
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($message, 'Master Control Program', 'OK', 'Error') | Out-Null
    }
    catch {
        Write-Error $message
    }
    exit 1
}

