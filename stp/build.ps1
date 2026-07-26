param(
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$Ebin = Join-Path $ProjectRoot '_build\default\lib\telco_stp\ebin'
$TestEbin = Join-Path $ProjectRoot '_build\test\lib\telco_stp\test'

function Find-Otp29Home {
    $Candidates = @()
    if ($env:ERLANG_HOME) {
        $Candidates += $env:ERLANG_HOME
    }
    $Candidates += 'C:\Program Files\Erlang OTP'

    foreach ($Candidate in $Candidates | Select-Object -Unique) {
        $Erl = Join-Path $Candidate 'bin\erl.exe'
        if (Test-Path -LiteralPath $Erl) {
            & $Erl -noshell -eval 'halt(case erlang:system_info(otp_release) of [50,57] -> 0; _ -> 29 end).'
            if ($LASTEXITCODE -eq 0) {
                return $Candidate
            }
        }
    }
    throw 'Erlang/OTP 29 was not found. Set ERLANG_HOME to the OTP 29 installation.'
}

$OtpHome = Find-Otp29Home
$Erl = Join-Path $OtpHome 'bin\erl.exe'
$Erlc = Join-Path $OtpHome 'bin\erlc.exe'

New-Item -ItemType Directory -Force -Path $Ebin | Out-Null

& $Erlc -Werror -o $Ebin (Join-Path $ProjectRoot 'src\telco_stp_transport.erl')
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to compile transport behaviour.'
}

$Sources = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src') -Filter '*.erl' |
    Where-Object Name -ne 'telco_stp_transport.erl' |
    ForEach-Object FullName
& $Erlc -Werror -pa $Ebin -o $Ebin $Sources
if ($LASTEXITCODE -ne 0) {
    throw 'Source compilation failed.'
}

Copy-Item -LiteralPath (Join-Path $ProjectRoot 'src\telco_stp.app.src') `
    -Destination (Join-Path $Ebin 'telco_stp.app') -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'src\telco_stp.appup.src') `
    -Destination (Join-Path $Ebin 'telco_stp.appup') -Force

Write-Host "Built telco_stp with Erlang/OTP 29 from $OtpHome"

if ($Test) {
    New-Item -ItemType Directory -Force -Path $TestEbin | Out-Null
    $Tests = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'test') -Filter '*.erl' |
        ForEach-Object FullName
    & $Erlc -Werror -pa $Ebin -o $TestEbin $Tests
    if ($LASTEXITCODE -ne 0) {
        throw 'Test compilation failed.'
    }
    & $Erl -pa $TestEbin -pa $Ebin -noshell -s telco_stp_test_runner run
    if ($LASTEXITCODE -ne 0) {
        throw 'Tests failed.'
    }
}
