[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$entryPoint = Join-Path $PSScriptRoot 'src\MasterControlProgram.ps1'
$startupLog = $null

try {
    $logFolder = Join-Path $env:LOCALAPPDATA 'MasterControlProgram'
    New-Item -ItemType Directory -Path $logFolder -Force -ErrorAction Stop | Out-Null
    $startupLog = Join-Path $logFolder 'mcp-startup.log'
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting MCP from $PSScriptRoot" |
        Set-Content -LiteralPath $startupLog -Encoding UTF8
}
catch {
    # Logging is helpful but must never prevent the app from starting.
    $startupLog = $null
}

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
    $details = $_ | Out-String
    if ($startupLog) {
        try { $details | Add-Content -LiteralPath $startupLog -Encoding UTF8 } catch { }
    }
    $logHint = if ($startupLog) { "`n`nDiagnostic log:`n$startupLog" } else { '' }
    $message = "MCP encountered an unexpected error:`n`n$($_.Exception.Message)$logHint"
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($message, 'Master Control Program', 'OK', 'Error') | Out-Null
    }
    catch {
        Write-Error $message
    }
    exit 1
}
