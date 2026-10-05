#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path (Join-Path $PSScriptRoot 'artifacts') ('regression-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
[void][IO.Directory]::CreateDirectory($root)
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Join-Mp4.ps1'
$ffmpeg = (Get-Command ffmpeg.exe).Source
$probe = (Get-Command ffprobe.exe).Source
$unicode = [string][char]0x65E5 + [string][char]0x672C
$one = Join-Path $root ("01 O'Brien $unicode red.mp4")
$two = Join-Path $root '02 blue.mp4'
$different = Join-Path $root '03 different green.mp4'
$silent = Join-Path $root '04 no audio yellow.mp4'
$audioOnly = Join-Path $root '05 audio only.mp4'
$invalid = Join-Path $root '06 corrupt.mp4'
$overlap = Join-Path $root '07 AAC timestamp overlap.mp4'
$base60 = Join-Path $root '08 base 60 fps.mp4'
$gapped60 = Join-Path $root '09 base 60 fps one missing frame.mp4'
$results = New-Object 'System.Collections.Generic.List[object]'
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Generate([string[]] $Arguments) {
    & $ffmpeg -hide_banner -nostdin -n -v error @Arguments
    Assert ($LASTEXITCODE -eq 0) 'Fixture generation failed'
}
function Probe([string] $Path) {
    $json = & $probe -v error -show_streams -show_format -of json $Path
    Assert ($LASTEXITCODE -eq 0) 'Output probe failed'
    return (($json -join "`n") | ConvertFrom-Json)
}
function Success([string] $Name, [string[]] $Paths, [string] $Mode, [bool] $ExpectAudio, [int] $ExpectedWidth) {
    $out = Join-Path $root ($Name + '.mp4')
    $null = & $script -InputPaths $Paths -OutputPath $out -Mode $Mode
    $info = Probe $out
    $v = @($info.streams | Where-Object codec_type -eq video)[0]
    $a = @($info.streams | Where-Object codec_type -eq audio)
    Assert ($v.width -eq $ExpectedWidth) "$Name width"
    Assert (($a.Count -gt 0) -eq $ExpectAudio) "$Name audio presence"
    $duration = [double]::Parse($info.format.duration,[Globalization.CultureInfo]::InvariantCulture)
    Assert ([math]::Abs($duration - $Paths.Count) -lt 0.15) "$Name duration $duration"
    & $ffmpeg -hide_banner -nostdin -v error -xerror -threads 1 -i $out -f null -
    Assert ($LASTEXITCODE -eq 0) "$Name decode failed"
    $results.Add([pscustomobject]@{Test=$Name; Result='PASS'; Duration=$duration; Output=$out})
    return $out
}
function Failure([string] $Name, [scriptblock] $Action, [string] $Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "$Name did not fail as expected: $message"
    $results.Add([pscustomobject]@{Test=$Name; Result='PASS'; Detail=$message})
}
Generate @('-f','lavfi','-i','color=c=red:s=160x90:r=30:d=1','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=0.95','-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-c:a','aac','-ac','2',$one)
Generate @('-f','lavfi','-i','color=c=blue:s=160x90:r=30:d=1','-f','lavfi','-i','sine=frequency=880:sample_rate=48000:duration=0.95','-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-c:a','aac','-ac','2',$two)
Generate @('-f','lavfi','-i','color=c=red:s=160x90:r=30:d=1','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=1','-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-c:a','aac','-ac','2',$overlap)
Generate @('-f','lavfi','-i','color=c=green:s=192x128:r=15:d=1','-f','lavfi','-i','sine=frequency=220:sample_rate=44100:duration=1','-c:v','mpeg4','-threads','1','-c:a','libmp3lame','-ac','1',$different)
Generate @('-f','lavfi','-i','color=c=yellow:s=96x64:r=24:d=1','-c:v','libx264','-threads','1','-an',$silent)
Generate @('-f','lavfi','-i','sine=duration=1','-c:a','aac',$audioOnly)
Generate @('-f','lavfi','-i','color=c=red:s=160x90:r=60:d=1','-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-fps_mode','vfr','-video_track_timescale','15360',$base60)
Generate @('-f','lavfi','-i','color=c=blue:s=160x90:r=60:d=1','-vf','select=not(eq(n\,20))','-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-fps_mode','vfr','-video_track_timescale','15360',$gapped60)
[IO.File]::WriteAllText($invalid,'intentionally invalid MP4 test fixture')
$before = @($one,$two,$different,$silent,$audioOnly,$invalid,$overlap,$base60,$gapped60 | ForEach-Object { Get-FileHash -LiteralPath $_ })
$copy = Success 'compatible copy' @($one,$two) 'Copy' $true 160
$null = Success 'mixed codecs dimensions fps audio' @($one,$different) 'Reencode' $true 160
$null = Success 'missing audio' @($one,$silent) 'Reencode' $true 160
$null = Success 'all silent copy' @($silent,$silent) 'Copy' $false 96
$null = Success 'all silent reencode' @($silent,$silent) 'Reencode' $false 96
$null = Success 'three ordered clips' @($one,$different,$silent) 'Reencode' $true 160
Failure 'copy mismatch' { & $script -InputPaths @($one,$different) -OutputPath (Join-Path $root 'rejected-mismatch.mp4') } 'compatibility check failed'
Failure 'copy audio mismatch' { & $script -InputPaths @($one,$silent) -OutputPath (Join-Path $root 'rejected-audio.mp4') } 'compatibility check failed'
$existingHash = (Get-FileHash -LiteralPath $copy).Hash
Failure 'existing output' { & $script -InputPaths @($one,$two) -OutputPath $copy } 'already exists'
Assert ((Get-FileHash -LiteralPath $copy).Hash -eq $existingHash) 'Existing output changed'
Failure 'output is input' { & $script -InputPaths @($one,$two) -OutputPath $one } 'cannot be an input'
Failure 'corrupt input native failure' { & $script -InputPaths @($one,$invalid) -OutputPath (Join-Path $root 'rejected-corrupt.mp4') } 'exit code'
Failure 'encoder native failure' { & $script -InputPaths @($one,$two) -OutputPath (Join-Path $root 'rejected-encoder.mp4') -FFmpegPath $probe } 'exit code'
Failure 'missing executable' { & $script -InputPaths @($one,$two) -OutputPath (Join-Path $root 'rejected-tool.mp4') -FFprobePath 'definitely-not-installed-ffprobe.exe' } 'Cannot find'
Failure 'unsupported audio only input' { & $script -InputPaths @($one,$audioOnly) -OutputPath (Join-Path $root 'rejected-audio-only.mp4') } 'Expected one video'
$overlapOutput = Join-Path $root 'rejected-timestamps.mp4'
Failure 'AAC copy timestamp warning' { & $script -InputPaths @($overlap,$overlap) -OutputPath $overlapOutput } 'timestamp problem'
Assert (-not (Test-Path -LiteralPath $overlapOutput)) 'Timestamp warning output was published'
$null = Success 'AAC timestamp reencode fallback' @($overlap,$overlap) 'Reencode' $true 160
$first60 = (Probe $base60).streams[0]
$second60 = (Probe $gapped60).streams[0]
Assert ($first60.avg_frame_rate -ne $second60.avg_frame_rate) 'Regression fixtures need different average frame rates'
Assert ($first60.r_frame_rate -eq $second60.r_frame_rate -and $first60.time_base -eq $second60.time_base) 'Regression fixtures must share base frame rate and time base'
$vfrCopy = Success 'copy differing average fps' @($base60,$gapped60) 'Copy' $false 160
$vfrInfo = (Probe $vfrCopy).streams[0]
Assert ([int]$vfrInfo.nb_frames -eq 119) 'Frame-gap copy changed the frame count'
function PacketTimes([string] $Path) {
    $json = & $probe -v error -select_streams v:0 -show_packets -show_entries packet=pts,dts -of json $Path
    Assert ($LASTEXITCODE -eq 0) 'Packet probe failed'
    return @(($json -join "`n" | ConvertFrom-Json).packets)
}
$sourcePackets = @(PacketTimes $gapped60)
$joinedPackets = @(PacketTimes $vfrCopy)
for ($i=0; $i -lt $sourcePackets.Count; $i++) {
    Assert (($joinedPackets[$i+60].pts - $joinedPackets[60].pts) -eq ($sourcePackets[$i].pts - $sourcePackets[0].pts)) 'Copy changed relative presentation timing'
    Assert (($joinedPackets[$i+60].dts - $joinedPackets[60].dts) -eq ($sourcePackets[$i].dts - $sourcePackets[0].dts)) 'Copy changed relative decode timing'
}
$results.Add([pscustomobject]@{Test='frame gaps and packet timing preserved'; Result='PASS'})
foreach ($entry in $before) { Assert ((Get-FileHash -LiteralPath $entry.Path).Hash -eq $entry.Hash) 'Original fixture changed' }
# Verify playback order by comparing first/second segment decoded frame hashes to sources.
function FrameHash([string] $Path, [string] $Time) {
    $text = & $ffmpeg -hide_banner -v error -threads 1 -ss $Time -i $Path -frames:v 1 -map 0:v:0 -f md5 -
    Assert ($LASTEXITCODE -eq 0) 'Frame hash failed'
    return ($text -join '')
}
Assert ((FrameHash $copy '0.3') -eq (FrameHash $one '0.3')) 'First segment order incorrect'
Assert ((FrameHash $copy '1.3') -eq (FrameHash $two '0.3')) 'Second segment order incorrect'
$results.Add([pscustomobject]@{Test='input hashes and playback order'; Result='PASS'})
$report = [pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString(); ArtifactDirectory=$root; Results=$results.ToArray()}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'test-results.json') -Encoding UTF8
$results | Select-Object Test,Result | Format-Table -AutoSize
Write-Host "Retained test report: $root\test-results.json"
