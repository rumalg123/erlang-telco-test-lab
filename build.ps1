param(
    [ValidateSet('all', 'stp', 'msc', 'smsc', 'hlr')]
    [string]$Component = 'all',
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot

function Build-Stp {
    if ($Test) {
        & (Join-Path $ProjectRoot 'stp\build.ps1') -Test
    } else {
        & (Join-Path $ProjectRoot 'stp\build.ps1')
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'STP build failed.'
    }
}

switch ($Component) {
    'all' {
        Build-Stp
        Write-Host 'MSC, SMSC, and HLR are scaffolds and have no build yet.'
    }
    'stp' {
        Build-Stp
    }
    default {
        throw "Component '$Component' is scaffolded but not implemented yet."
    }
}
