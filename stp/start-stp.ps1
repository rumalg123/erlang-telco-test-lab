$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot

& (Join-Path $ProjectRoot 'build.ps1')

$Candidates = @()
if ($env:ERLANG_HOME) {
    $Candidates += (Join-Path $env:ERLANG_HOME 'bin\erl.exe')
}
$Candidates += 'C:\Program Files\Erlang OTP\bin\erl.exe'
$Erl = $null
foreach ($Candidate in $Candidates | Select-Object -Unique) {
    if (Test-Path -LiteralPath $Candidate) {
        & $Candidate -noshell -eval 'halt(case erlang:system_info(otp_release) of [50,57] -> 0; _ -> 29 end).'
        if ($LASTEXITCODE -eq 0) {
            $Erl = $Candidate
            break
        }
    }
}
if (-not $Erl) {
    throw 'Erlang/OTP 29 was not found.'
}

$Ebin = Join-Path $ProjectRoot '_build\default\lib\telco_stp\ebin'
$Config = Join-Path $ProjectRoot 'config\sys'

& $Erl -pa $Ebin -config $Config -s telco_stp_console boot
