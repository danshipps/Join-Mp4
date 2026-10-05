#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Join-Mp4.ps1'
$root = Join-Path (Join-Path $PSScriptRoot 'artifacts') ('avcc-powershell-' + $PSVersionTable.PSVersion.Major + '-' + [guid]::NewGuid().ToString('N').Substring(0,12))
[void][IO.Directory]::CreateDirectory($root)
$results = New-Object 'System.Collections.Generic.List[object]'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw $errors }
# Load only pure comparison functions, never the media-processing body.
foreach ($name in @('Get-Property','Get-CodecHeaderSignature','Get-SignatureDifferences','Get-Signature')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message } }
function Passed([string] $Name) { $results.Add([pscustomobject]@{Test=$Name;Result='PASS'}) }
function Stream([byte[]] $Bytes) {
    $rows=@()
    for ($i=0; $i -lt $Bytes.Length; $i+=16) {
        $pairs=@()
        for ($j=$i; $j -lt [Math]::Min($i+16,$Bytes.Length); $j+=2) {
            $pair=$Bytes[$j].ToString('x2')
            if ($j+1 -lt $Bytes.Length) { $pair += $Bytes[$j+1].ToString('x2') }
            $pairs += $pair
        }
        $rows += ('{0:x8}: {1}  test' -f $i,($pairs -join ' ').PadRight(39))
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash='SHA256:' + [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    return [pscustomobject]@{codec_name='h264';codec_tag_string='avc1';profile='High';pix_fmt='yuv420p';bits_per_raw_sample='8';extradata_size=$Bytes.Length;extradata_hash=$hash;extradata="`n"+($rows -join "`n")+"`n"}
}
$fixtures=& (Join-Path $PSScriptRoot 'New-AvccFixtures.ps1') -Directory $root
$legacy=[byte[]]$fixtures.LegacyHeader
$modern=[byte[]]$fixtures.ModernHeader
$legacyStream=Stream $legacy
$modernStream=Stream $modern
$canonical=Get-CodecHeaderSignature $modernStream
Assert ($canonical -like 'AVCC-BASE-SHA256:*') 'Expected known configuration normalization'
Assert ($canonical -ceq (Get-CodecHeaderSignature $legacyStream)) 'Equivalent extension did not match'
Passed 'Recognize missing versus FD F8 F8 00 extension'
foreach ($case in @(@('Changed SPS remains incompatible',10),@('Changed PPS remains incompatible',($legacy.Length-1)))) {
    $changed=[byte[]]$legacy.Clone(); $changed[$case[1]]=$changed[$case[1]] -bxor 1
    Assert ((Get-CodecHeaderSignature (Stream $changed)) -cne $canonical) $case[0]
    Passed $case[0]
}
$cases=@(
    @{Name='Unknown extension rejected';Bytes=[byte[]]($legacy+@(253,248,248,1))},
    @{Name='Different chroma extension rejected';Bytes=[byte[]]($legacy+@(254,248,248,0))},
    @{Name='Different bit depth extension rejected';Bytes=[byte[]]($legacy+@(253,249,248,0))},
    @{Name='Truncated NAL rejected';Bytes=[byte[]]$legacy[0..($legacy.Length-2)]},
    @{Name='Extra trailing bytes rejected';Bytes=[byte[]]($modern+@(0))}
)
foreach ($case in $cases) {
    $candidate=Stream $case.Bytes
    Assert ((Get-CodecHeaderSignature $candidate) -ceq $candidate.extradata_hash) $case.Name
    Assert ((Get-CodecHeaderSignature $candidate) -cne $canonical) $case.Name
    Passed $case.Name
}
function Probe([string] $Path) {
    $json=& ffprobe.exe -v error -show_streams -show_data -show_data_hash sha256 -of json $Path
    Assert ($LASTEXITCODE -eq 0) 'Probe failed'
    return (($json -join "`n") | ConvertFrom-Json)
}
$modernPath=$fixtures.ModernPath
$legacyPath=$fixtures.LegacyPath
$a=Probe $modernPath; $b=Probe $legacyPath
$hashesBefore=@((Get-FileHash -LiteralPath $modernPath).Hash,(Get-FileHash -LiteralPath $legacyPath).Hash)
Assert ($a.streams[0].extradata_hash -cne $b.streams[0].extradata_hash) 'Fixtures need differing raw hashes'
Assert ((Get-Signature $a) -ceq (Get-Signature $b)) 'Fixture signatures failed'
# Genuine property differences remain visible in the error diagnostic.
$changedMedia=($b | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
$changedMedia.streams[0].width=192
$diff=(Get-SignatureDifferences (Get-Signature $a) (Get-Signature $changedMedia)) -join '; '
Assert ($diff -match 'stream\[0\]\.width: 160 -> 192') 'Mismatch diagnostic omitted width'
$unsupported=Stream $modern; $unsupported.profile='Main'
Assert ((Get-CodecHeaderSignature $unsupported) -ceq $unsupported.extradata_hash) 'Unsupported profile did not retain strict hash'
Passed 'Raw hashes differ while core stream properties match'
$output=Join-Path $root 'copy-joined.mp4'
$null=& $scriptPath -InputPaths @($modernPath,$legacyPath) -OutputPath $output
$out=Probe $output
Assert ($out.streams[0].nb_frames -eq '120') 'Expected 120 copied frames'
Assert ([Math]::Abs([double]::Parse($out.streams[0].duration,[Globalization.CultureInfo]::InvariantCulture)-2) -lt 0.02) 'Wrong output duration'
& ffmpeg.exe -hide_banner -nostdin -v error -xerror -threads 1 -i $output -f null -
Assert ($LASTEXITCODE -eq 0) 'Joined output decode failed'
Assert ((Get-FileHash -LiteralPath $modernPath).Hash -eq $hashesBefore[0] -and (Get-FileHash -LiteralPath $legacyPath).Hash -eq $hashesBefore[1]) 'Fixture modified'
Passed 'Production concat copy decodes cleanly with 120 frames and unchanged originals'
Assert ($legacyStream.extradata_hash -ceq $b.streams[0].extradata_hash) 'Generated legacy header hash differs from ffprobe'
Assert ($modernStream.extradata_hash -ceq $a.streams[0].extradata_hash) 'Generated modern header hash differs from ffprobe'
$missing=Stream $modern; $missing.extradata=''
Assert ((Get-CodecHeaderSignature $missing) -ceq $missing.extradata_hash) 'Missing data must retain strict hash'
$wrongSize=Stream $modern; $wrongSize.extradata_size++
Assert ((Get-CodecHeaderSignature $wrongSize) -ceq $wrongSize.extradata_hash) 'Incorrect data size must retain strict hash'
Passed 'Generated headers match ffprobe; missing or inconsistent data retains strict hash'
[pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString();Results=$results.ToArray();ArtifactDirectory=$root} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'test-results.json') -Encoding UTF8
$results | Format-Table -AutoSize
Write-Host "Retained test report: $root\test-results.json"
