param(
    [ValidateSet('default')]
    [string]$Topology = 'default'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot

if ($Topology -ne 'default') {
    throw "Unknown topology: $Topology"
}

Write-Host 'Starting default lab topology: STP'
& (Join-Path $ProjectRoot 'stp\start-stp.ps1')

