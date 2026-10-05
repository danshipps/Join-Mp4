#requires -Version 5.1
<# Creates two tiny MP4 fixtures with equivalent AVC configuration records. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)] [string] $Directory)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory($Directory)
$modernPath=Join-Path $Directory 'modern.mp4'
$legacyPath=Join-Path $Directory 'legacy.mp4'
if ((Test-Path -LiteralPath $modernPath) -or (Test-Path -LiteralPath $legacyPath)) { throw 'Fixture output already exists' }
& ffmpeg.exe -hide_banner -nostdin -n -v error -f lavfi -i 'color=c=red:s=160x90:r=60:d=1' -c:v libx264 -threads 1 -pix_fmt yuv420p -an $modernPath
if ($LASTEXITCODE -ne 0) { throw 'AVC fixture generation failed' }
$bytes=[IO.File]::ReadAllBytes($modernPath)
function Read-U32([int] $Offset) {
    return [long]$bytes[$Offset]*16777216 + [long]$bytes[$Offset+1]*65536 + [long]$bytes[$Offset+2]*256 + [long]$bytes[$Offset+3]
}
function Find-Avcc([int] $Start,[int] $End,[int[]] $Ancestors) {
    $offset=$Start
    while ($offset -lt $End) {
        if ($offset+8 -gt $End) { throw 'Truncated fixture box' }
        $size=Read-U32 $offset
        if ($size -lt 8 -or $offset+$size -gt $End) { throw 'Invalid fixture box' }
        $name=[Text.Encoding]::ASCII.GetString($bytes,$offset+4,4)
        $chain=@($Ancestors)+@($offset)
        if ($name -eq 'avcC') { return [pscustomobject]@{Offset=$offset;Size=$size;Ancestors=$chain} }
        $child=$null
        if ($name -in @('moov','trak','mdia','minf','stbl')) { $child=$offset+8 }
        elseif ($name -eq 'stsd') { $child=$offset+16 }
        elseif ($name -eq 'avc1') { $child=$offset+86 }
        if ($null -ne $child) {
            $found=Find-Avcc $child ($offset+$size) $chain
            if ($null -ne $found) { return $found }
        }
        $offset += $size
    }
    return $null
}
$avcc=Find-Avcc 0 $bytes.Length @()
if ($null -eq $avcc) { throw 'Fixture has no AVC configuration box' }
$modernHeader=[byte[]]$bytes[($avcc.Offset+8)..($avcc.Offset+$avcc.Size-1)]
if ([BitConverter]::ToString($modernHeader[($modernHeader.Length-4)..($modernHeader.Length-1)]) -ne 'FD-F8-F8-00') {
    throw 'This FFmpeg build did not generate the expected High-profile fixture extension'
}
# The generated MP4 stores media before moov, so shrinking avcC leaves media
# chunk offsets unchanged. Reject another layout rather than guessing offsets.
$offset=0; $seenMedia=$false; $validLayout=$false
while ($offset -lt $bytes.Length) {
    $size=Read-U32 $offset
    $name=[Text.Encoding]::ASCII.GetString($bytes,$offset+4,4)
    if ($name -eq 'mdat') { $seenMedia=$true }
    if ($name -eq 'moov') { $validLayout=$seenMedia; break }
    $offset += $size
}
if (-not $validLayout) { throw 'Unexpected fixture media layout' }
$modified=[byte[]]$bytes.Clone()
foreach ($parentOffset in $avcc.Ancestors) {
    $newSize=(Read-U32 $parentOffset)-4
    for ($i=0; $i -lt 4; $i++) { $modified[$parentOffset+$i]=[byte](($newSize -shr ((3-$i)*8)) -band 255) }
}
$cut=$avcc.Offset+$avcc.Size-4
$legacyBytes=New-Object byte[] ($modified.Length-4)
[Array]::Copy($modified,0,$legacyBytes,0,$cut)
[Array]::Copy($modified,$cut+4,$legacyBytes,$cut,$modified.Length-$cut-4)
$handle=[IO.File]::Open($legacyPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $handle.Write($legacyBytes,0,$legacyBytes.Length) } finally { $handle.Dispose() }
[pscustomobject]@{
    ModernPath=$modernPath
    LegacyPath=$legacyPath
    ModernHeader=$modernHeader
    LegacyHeader=[byte[]]$modernHeader[0..($modernHeader.Length-5)]
}
