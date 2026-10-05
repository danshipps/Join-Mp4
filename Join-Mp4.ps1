#requires -Version 5.1
<#
.SYNOPSIS
Joins local MP4 files in the supplied order. Originals and existing outputs are never overwritten.
.EXAMPLE
.\Join-Mp4.ps1 -InputPaths @('C:\Videos\part 1.mp4','C:\Videos\part 2.mp4') -OutputPath 'C:\Videos\joined.mp4'
.EXAMPLE
.\Join-Mp4.ps1 -InputPaths @('a.mp4','b.mp4') -OutputPath 'joined.mp4' -Mode Reencode
#>
[CmdletBinding()]
param(
    [string[]] $InputPaths,
    [string] $OutputPath,
    [ValidateSet('Copy','Reencode')] [string] $Mode = 'Copy',
    [string] $FFmpegPath = 'ffmpeg.exe',
    [string] $FFprobePath = 'ffprobe.exe',
    [ValidateRange(0,16384)] [int] $Width = 0,
    [ValidateRange(0,16384)] [int] $Height = 0,
    [ValidatePattern('^([1-9][0-9]*)(/[1-9][0-9]*)?$')] [string] $FrameRate = '30',
    [ValidateRange(0,51)] [int] $Crf = 20,
    [ValidateRange(1,16)] [int] $Threads = 2
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$culture = [Globalization.CultureInfo]::InvariantCulture

function Resolve-Tool([string] $Name) {
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "Cannot find $Name. Supply its executable path or put existing FFmpeg tools on PATH. Nothing was installed." }
    return $command.Source
}

function Quote-NativeArgument([string] $Value) {
    # Windows CRT quoting, independent of PowerShell's native argument mode.
    $Value = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $Value = [regex]::Replace($Value, '(\\+)$', '$1$1')
    return '"' + $Value + '"'
}

function Invoke-Native([string] $Executable, [string[]] $Arguments, [string] $LogBase) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start $Executable" }
        # Drain both pipes concurrently to avoid native stderr deadlocks.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(200)) { }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($LogBase + '.stdout.txt', $stdout, $utf8)
        [IO.File]::WriteAllText($LogBase + '.stderr.txt', $stderr, $utf8)
        if ($process.ExitCode -ne 0) {
            throw "$(Split-Path -Leaf $Executable) failed with exit code $($process.ExitCode). See $LogBase.stderr.txt`n$stderr"
        }
        if ($stderr.Trim()) { Write-Warning $stderr.Trim() }
        return $stdout
    }
    finally {
        # On cancellation stop only the child we started. Never delete its partial output.
        try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch { }
        $process.Dispose()
    }
}

function Get-Property($Object, [string] $Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Read-Probe([string] $Path, [string] $LogBase) {
    $json = Invoke-Native $probe @('-v','error','-show_streams','-show_format','-show_data','-show_data_hash','sha256','-of','json',$Path) $LogBase
    return ($json | ConvertFrom-Json)
}

function Get-CodecHeaderSignature($Stream) {
    $original = Get-Property $Stream 'extradata_hash'
    # Only recognize one known equivalent avcC representation. Every other codec
    # or unsupported structure retains the original strict whole-header hash.
    if ((Get-Property $Stream 'codec_name') -cne 'h264' -or
        (Get-Property $Stream 'codec_tag_string') -cne 'avc1' -or
        (Get-Property $Stream 'profile') -cne 'High' -or
        (Get-Property $Stream 'pix_fmt') -cne 'yuv420p' -or
        [string](Get-Property $Stream 'bits_per_raw_sample') -cne '8') { return $original }
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($line in ([string](Get-Property $Stream 'extradata') -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        # ffprobe hex rows have an eight-digit offset and a 39-character hex column.
        if ($line -notmatch '^([0-9a-fA-F]{8}): (.{39})') { return $original }
        if ([Convert]::ToInt64($Matches[1],16) -ne $bytes.Count) { return $original }
        $hex = $Matches[2].Replace(' ','')
        if ($hex -notmatch '^(?:[0-9a-fA-F]{2})+$') { return $original }
        for ($j=0; $j -lt $hex.Length; $j+=2) { $bytes.Add([Convert]::ToByte($hex.Substring($j,2),16)) }
    }
    if ($bytes.Count -ne (Get-Property $Stream 'extradata_size') -or $bytes.Count -lt 7) { return $original }
    # High profile, avcC version 1, four-byte NAL lengths, valid reserved bits.
    if ($bytes[0] -ne 1 -or $bytes[1] -ne 100 -or $bytes[4] -ne 255 -or ($bytes[5] -band 224) -ne 224) { return $original }
    $offset = 6
    $count = $bytes[5] -band 31
    if ($count -eq 0) { return $original }
    foreach ($nalType in @(7,8)) {
        if ($nalType -eq 8) {
            if ($offset -ge $bytes.Count) { return $original }
            $count = $bytes[$offset]
            $offset++
            if ($count -eq 0) { return $original }
        }
        for ($j=0; $j -lt $count; $j++) {
            if ($offset + 2 -gt $bytes.Count) { return $original }
            $length = [int]$bytes[$offset] * 256 + [int]$bytes[$offset+1]
            $offset += 2
            if ($length -eq 0 -or $offset + $length -gt $bytes.Count) { return $original }
            if (($bytes[$offset] -band 31) -ne $nalType) { return $original }
            $offset += $length
        }
    }
    $remaining = $bytes.Count - $offset
    if ($remaining -ne 0) {
        if ($remaining -ne 4 -or $bytes[$offset] -ne 253 -or $bytes[$offset+1] -ne 248 -or
            $bytes[$offset+2] -ne 248 -or $bytes[$offset+3] -ne 0) { return $original }
    }
    # FD F8 F8 00 repeats 4:2:0 / 8-bit and has no SPS extension. Hash every
    # prefix, SPS and PPS byte; never discard meaningful parameter-set changes.
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return 'AVCC-BASE-SHA256:' + [BitConverter]::ToString($sha.ComputeHash($bytes.GetRange(0,$offset).ToArray())).Replace('-','')
    }
    finally { $sha.Dispose() }
}

function Get-SignatureDifferences([string] $First, [string] $Second) {
    # Assign first: Windows PowerShell 5.1 emits a JSON array as one pipeline
    # object. Wrapping the command directly in @() would add an array layer.
    $left = ConvertFrom-Json -InputObject $First
    $right = ConvertFrom-Json -InputObject $Second
    $left = @($left)
    $right = @($right)
    if ($left.Count -ne $right.Count) { "stream count: $($left.Count) -> $($right.Count)" }
    for ($i=0; $i -lt [Math]::Min($left.Count,$right.Count); $i++) {
        foreach ($property in $left[$i].PSObject.Properties) {
            $a = ConvertTo-Json -InputObject $property.Value -Depth 20 -Compress
            $b = ConvertTo-Json -InputObject (Get-Property $right[$i] $property.Name) -Depth 20 -Compress
            if ($a -cne $b) { "stream[$i].$($property.Name): $a -> $b" }
        }
    }
}

function Get-Signature($Media) {
    # Deliberately conservative. Matching metadata cannot prove every packet is valid.
    # avg_frame_rate is a clip-wide statistic, not a codec constraint. Frame gaps
    # can change it while codec headers, base frame rate and time base still match.
    # Copy preserves those packet timestamps; keep r_frame_rate and all codec checks.
    $fields = @('codec_type','codec_name','codec_tag_string','profile','level','time_base',
        'width','height','pix_fmt','sample_aspect_ratio','r_frame_rate',
        'field_order','color_range','color_space','color_transfer','color_primaries',
        'sample_fmt','sample_rate','channels','channel_layout','bits_per_raw_sample','extradata_hash')
    $result = foreach ($stream in $Media.streams) {
        $record = [ordered]@{}
        foreach ($field in $fields) { $record[$field] = Get-Property $stream $field }
        $record['extradata_hash'] = Get-CodecHeaderSignature $stream
        $record['side_data_list'] = Get-Property $stream 'side_data_list'
        $record['disposition'] = Get-Property $stream 'disposition'
        [pscustomobject]$record
    }
    return (ConvertTo-Json -InputObject @($result) -Depth 20 -Compress)
}

function Get-PositiveDuration($Stream, [string] $Path) {
    $duration = 0.0
    if (-not [double]::TryParse([string](Get-Property $Stream 'duration'), [Globalization.NumberStyles]::Float, $culture, [ref]$duration) -or
        [double]::IsInfinity($duration) -or [double]::IsNaN($duration) -or $duration -le 0) {
        throw "No reliable positive video duration in $Path. Cannot safely normalize its audio length."
    }
    return $duration
}

if (-not $InputPaths -or $InputPaths.Count -eq 0) {
    $entered = New-Object 'System.Collections.Generic.List[string]'
    Write-Host 'Enter MP4 paths in playback order, without surrounding quotes. Enter a blank line when finished.'
    do {
        $next = Read-Host ('Input ' + ($entered.Count + 1))
        if (-not [string]::IsNullOrWhiteSpace($next)) { $entered.Add($next) }
    } while (-not [string]::IsNullOrWhiteSpace($next))
    $InputPaths = $entered.ToArray()
}
if ($InputPaths.Count -lt 2) { throw 'Supply at least two MP4 inputs in playback order.' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Read-Host 'New output MP4 path, without surrounding quotes' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'An output path is required.' }
if ($env:OS -ne 'Windows_NT') { throw 'This script targets Windows PowerShell 5.1 and PowerShell 7 on Windows.' }

$inputs = @($InputPaths | ForEach-Object {
    $item = Get-Item -LiteralPath $_ -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Extension -ine '.mp4') { throw "Input must be a local .mp4 file: $_" }
    if ($item.FullName -match '[\r\n]') { throw 'Newlines in paths are not supported.' }
    $item.FullName
})
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([IO.Path]::GetExtension($output) -ine '.mp4') { throw 'Output must have the .mp4 extension.' }
if ($output -match '[\r\n]' -or $output.Substring(2).Contains(':')) { throw 'Output must be a regular Windows file path.' }
if ($inputs -contains $output) { throw 'Output cannot be an input file.' }
if (Test-Path -LiteralPath $output) { throw "Output already exists; refusing to overwrite: $output" }
$parent = Split-Path -Parent $output
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output directory does not exist: $parent" }
if (($Width -eq 0) -ne ($Height -eq 0)) { throw 'Supply both Width and Height, or omit both.' }
if (($Width % 2) -ne 0 -or ($Height % 2) -ne 0) { throw 'Width and Height must be even for H.264 yuv420p output.' }
if ($Mode -eq 'Copy' -and ($PSBoundParameters.ContainsKey('Width') -or $PSBoundParameters.ContainsKey('Height') -or
    $PSBoundParameters.ContainsKey('FrameRate') -or $PSBoundParameters.ContainsKey('Crf'))) {
    throw 'Width, Height, FrameRate and Crf require -Mode Reencode.'
}
$ffmpeg = Resolve-Tool $FFmpegPath
$probe = Resolve-Tool $FFprobePath
$work = Join-Path $parent ('Join-Mp4-work-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
Write-Host "Retained work files: $work"
$stage = Join-Path $work 'joined.partial.mp4'
try {
    $media = @()
    foreach ($path in $inputs) {
        $index = $media.Count
        $item = Read-Probe $path (Join-Path $work "input-$index")
        $videos = @($item.streams | Where-Object { $_.codec_type -eq 'video' })
        $audios = @($item.streams | Where-Object { $_.codec_type -eq 'audio' })
        if ($videos.Count -ne 1 -or $audios.Count -gt 1 -or @($item.streams).Count -ne (1 + $audios.Count) -or
            $videos[0].disposition.attached_pic -eq 1) {
            throw "Expected one video and at most one audio stream, without subtitles/data/cover art: $path. No streams were silently dropped."
        }
        $media += $item
    }
    $arguments = @('-hide_banner','-nostdin','-n','-v','warning')
    if ($Mode -eq 'Copy') {
        $signature = Get-Signature $media[0]
        for ($i = 1; $i -lt $media.Count; $i++) {
            $candidate = Get-Signature $media[$i]
            if ($candidate -cne $signature) {
                $differences = (Get-SignatureDifferences $signature $candidate) -join '; '
                throw "Copy compatibility check failed for input $($i + 1). Differences: $differences. See probe logs in $work. No output was published. Review the differences before choosing -Mode Reencode."
            }
            for ($streamIndex=0; $streamIndex -lt @($media[0].streams).Count; $streamIndex++) {
                if ((Get-Property $media[0].streams[$streamIndex] 'extradata_hash') -cne
                    (Get-Property $media[$i].streams[$streamIndex] 'extradata_hash')) {
                    Write-Host "Input $($i + 1), stream ${streamIndex}: equivalent AVC configuration extension; SPS/PPS and other compatibility fields match."
                }
            }
        }
        $lines = @('ffconcat version 1.0')
        foreach ($path in $inputs) {
            # ffconcat quoting is separate from native command-line quoting.
            $escaped = $path.Replace('\','/').Replace("'", "'\''")
            $lines += "file '$escaped'"
        }
        $list = Join-Path $work 'inputs.ffconcat'
        [IO.File]::WriteAllLines($list, $lines, $utf8)
        $arguments += @('-f','concat','-safe','0','-i',$list,'-map','0','-c','copy')
    }
    else {
        $firstVideo = @($media[0].streams | Where-Object { $_.codec_type -eq 'video' })[0]
        if ($Width -eq 0) {
            $Width = [int]([math]::Ceiling($firstVideo.width / 2.0) * 2)
            $Height = [int]([math]::Ceiling($firstVideo.height / 2.0) * 2)
        }
        Write-Host "Reencoding to ${Width}x${Height}, $FrameRate fps, H.264 / AAC stereo."
        $filters = @()
        $labels = ''
        $hasAudio = @($media | ForEach-Object { $_.streams } | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0
        for ($i = 0; $i -lt $inputs.Count; $i++) {
            $arguments += @('-threads',"$Threads",'-i',$inputs[$i])
            $video = @($media[$i].streams | Where-Object { $_.codec_type -eq 'video' })[0]
            if ((Get-Property $video 'color_transfer') -in @('smpte2084','arib-std-b67')) {
                throw 'HDR reencoding needs a separate color conversion workflow. Copy mode may preserve compatible HDR files.'
            }
            $duration = (Get-PositiveDuration $video $inputs[$i]).ToString('0.#########', $culture)
            $filters += "[$($i):v:0]setpts=PTS-STARTPTS,scale=w='trunc(ih*dar/2)*2':h=ih,setsar=1,scale=${Width}:${Height}:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=${Width}:${Height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$FrameRate,format=yuv420p[v$i]"
            $labels += "[v$i]"
            if ($hasAudio) {
                $audio = @($media[$i].streams | Where-Object { $_.codec_type -eq 'audio' })
                if ($audio.Count -gt 0) {
                    $filters += "[$($i):a:0]asetpts=PTS-STARTPTS,aresample=48000:async=1:first_pts=0,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=duration=$duration,asetpts=PTS-STARTPTS[a$i]"
                }
                else { $filters += "anullsrc=r=48000:cl=stereo,atrim=duration=$duration,asetpts=PTS-STARTPTS[a$i]" }
                $labels += "[a$i]"
            }
        }
        $audioCount = [int]$hasAudio
        $endLabels = '[vout]'
        if ($hasAudio) { $endLabels += '[aout]' }
        $filters += $labels + "concat=n=$($inputs.Count):v=1:a=$audioCount" + $endLabels
        $filterPath = Join-Path $work 'normalize.filter.txt'
        [IO.File]::WriteAllText($filterPath, ($filters -join ';'), $utf8)
        $arguments += @('-filter_complex_threads','1','-filter_complex_script',$filterPath,'-map','[vout]',
            '-c:v','libx264','-preset','veryfast','-crf',"$Crf",'-threads',"$Threads",'-pix_fmt','yuv420p')
        if ($hasAudio) { $arguments += @('-map','[aout]','-c:a','aac','-ar','48000','-ac','2','-b:a','192k') }
    }
    $arguments += @('-map_metadata','-1','-map_chapters','-1','-movflags','+faststart',$stage)
    [IO.File]::WriteAllText((Join-Path $work 'arguments.json'), (ConvertTo-Json -InputObject $arguments), $utf8)
    $null = Invoke-Native $ffmpeg $arguments (Join-Path $work 'ffmpeg')
    $diagnostics = [IO.File]::ReadAllText((Join-Path $work 'ffmpeg.stderr.txt'), $utf8)
    if ($diagnostics -match '(?i)non[- ]monoton|DTS.*out of order|invalid.*timestamp') {
        throw 'FFmpeg reported a timestamp problem. The output was not published. For Copy mode, retry explicitly with -Mode Reencode.'
    }
    $verified = Read-Probe $stage (Join-Path $work 'output')
    if ((Get-Item -LiteralPath $stage).Length -eq 0 -or @($verified.streams | Where-Object { $_.codec_type -eq 'video' }).Count -ne 1) {
        throw 'FFmpeg output did not pass the basic video check.'
    }
    # Same-volume rename; the two-argument Move fails if destination exists, even after a race.
    [IO.File]::Move($stage, $output)
    Write-Host "Joined file: $output"
    Write-Host "Logs retained: $work"
    [pscustomobject]@{ OutputPath = $output; Mode = $Mode; WorkDirectory = $work }
}
catch {
    throw "Join failed. Originals are unchanged; work files and any partial output remain in $work.`n$($_.Exception.Message)"
}
