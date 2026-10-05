#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
foreach ($tool in @('ffmpeg.exe','ffprobe.exe')) {
    if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "Tests require an existing $tool on PATH. Nothing was installed."
    }
}
& (Join-Path $PSScriptRoot 'Test-Join-Mp4.ps1')
& (Join-Path $PSScriptRoot 'Test-Avcc-Normalization.ps1')
Write-Host 'All 30 checks passed. Generated artifacts are retained under tests/artifacts/.'
