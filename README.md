# Join MP4 files

`Join-Mp4.ps1` joins two or more local MP4s in the order supplied. It preserves the originals and refuses to overwrite an input or any existing output.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- Existing `ffmpeg.exe` and `ffprobe.exe` on PATH, or explicit executable paths. Reencode mode needs FFmpeg's `libx264` and `aac` encoders.
- An existing output directory with enough free space for the joined video.

No modules, installation, administrator access, or security setting changes are required. The script does not change execution policy. If your policy blocks scripts, follow your normal approved script-running process.

## Run it

Open PowerShell in the folder containing the script. Paths inside the array determine playback order.

```powershell
.\Join-Mp4.ps1 -InputPaths @('C:\Videos\part 1.mp4', 'C:\Videos\part 2.mp4') -OutputPath 'C:\Videos\joined.mp4'
```

Running ` .\Join-Mp4.ps1 ` without arguments prompts for paths one at a time, then the output. Enter paths without surrounding quotes at the prompts. A blank input ends the list. There is no file picker.

The default `Copy` mode is fast and does not reencode. It compares stream layout, codec settings, dimensions, base frame rates, time bases, audio format, codec headers, and display information. It allows differing average frame rates, which can reflect frame gaps in otherwise compatible captures, and preserves packet timing. A mismatch in the checked fields stops the job. Some compatible files may be rejected because this check is conservative.

For 8-bit 4:2:0 H.264 High-profile MP4s, Copy also recognizes an absent AVC configuration extension as equivalent to the exact `FD F8 F8 00` extension added by some remuxers. It validates the header structure and still compares all SPS/PPS bytes and other settings. Unknown extensions and meaningful header differences retain the strict hash check. A rejected join now lists the differing fields; review them before deciding to reencode.

For mismatched files or a copy timestamp error, explicitly select reencoding:

```powershell
.\Join-Mp4.ps1 -InputPaths @('C:\Videos\part 1.mp4', 'C:\Videos\part 2.mp4') -OutputPath 'C:\Videos\joined-normalized.mp4' -Mode Reencode
```

Reencode mode produces H.264 video at 30 fps with AAC stereo at 48 kHz when any input has audio. It fits each clip into the first video's coded width and height, rounded up to even numbers, and pads unused space. It converts non-square pixels to square pixels. Silent clips get silence; if all inputs lack audio, the result has no audio track. Audio is padded or trimmed to each clip's video duration. Reencoding changes quality and takes longer.

Optional settings:

```powershell
.\Join-Mp4.ps1 -InputPaths @('a.mp4', 'b.mp4') -OutputPath 'joined.mp4' -Mode Reencode -Width 1920 -Height 1080 -FrameRate '30000/1001' -Crf 20 -Threads 2

.\Join-Mp4.ps1 -InputPaths @('a.mp4', 'b.mp4') -OutputPath 'joined.mp4' -FFmpegPath 'C:\tools\ffmpeg\bin\ffmpeg.exe' -FFprobePath 'C:\tools\ffmpeg\bin\ffprobe.exe'
```

Supply both width and height as even integers, or omit both. CRF defaults to 20; lower values use more space for better quality. Encoding and decoding use two threads by default, and the filter graph uses one. More inputs can still increase resource use.

Spaces, apostrophes, and Unicode paths are supported. In PowerShell single-quoted strings, double an embedded apostrophe, for example `'C:\Videos\O''Brien.mp4'`. Relative paths resolve from the current PowerShell directory. Use a PowerShell array as shown, rather than a comma-separated string passed through `cmd.exe -File`.

## Safety and limits

Each input must have exactly one video stream and at most one audio stream. Extra tracks, subtitles, data streams, and cover art are rejected. Chapters and container metadata are not carried over. HDR reencoding is rejected; this script has no HDR tone-mapping workflow. It is intended for ordinary SDR clips, not color-managed mastering.

Copy mode preserves encoded streams, including existing audio/video duration differences. Container timing, AAC priming, or damaged packets can still cause problems despite matching probe data. Known timestamp warnings stop publication and suggest Reencode. Other FFmpeg warnings remain visible and are logged. The script checks the completed file with ffprobe; it does not fully decode or watch your media. Check the join before relying on the result.

Reencode mode resets each stream's starting timestamp. Unusual intentional audio/video start offsets are not preserved. Audio beyond the video endpoint is trimmed. Clips with missing or invalid video durations are rejected. Rotated footage is decoded with FFmpeg's normal autorotation; use explicit dimensions if the first clip's coded dimensions are not your desired canvas.

The output is first written inside `Join-Mp4-work-<unique-id>` beside the destination. It is moved to the requested name only after FFmpeg and the basic output check succeed. This move also refuses an output created by another process during the job. A failure leaves any partial MP4 in the work directory. Errors terminate the script and produce a nonzero exit when invoked with `powershell.exe -File` or `pwsh -File`.

The script never deletes work files. Every run prints the retained folder containing probe results, command arguments, FFmpeg logs, and any failed partial output. These files include media paths. Review and manage retained folders yourself when appropriate.

## Verification and sources

Run ` .\tests\Run-Tests.ps1 ` from the repository root to execute 30 checks using tiny synthetic clips. The portable suite requires no Python or user media. It retains all fixtures, outputs, logs, and JSON reports under the Git-ignored `tests/artifacts/` folder. See [test instructions](tests/README.md) for prerequisites and commands for both PowerShell versions.

Official FFmpeg documentation checked on 2026-10-04:

- [Concat demuxer](https://ffmpeg.org/ffmpeg-formats.html#concat): matching stream requirements, path quoting, and timestamp/duration limitations.
- [Concat filter](https://ffmpeg.org/ffmpeg-filters.html#concat): zero-based segment timestamps and explicit resolution conversion.
- [Main options](https://ffmpeg.org/ffmpeg.html#Main-options): stream copy and the `-n` refusal to overwrite.
- [AVC configuration writer](https://ffmpeg.org/doxygen/trunk/avc_8c_source.html), checked 2026-10-05: the optional High-profile chroma/bit-depth extension.

The suite was verified with FFmpeg 6.1, Windows PowerShell 5.1.19041.7725, and PowerShell 7.6.5. Each run records its PowerShell version and results in retained JSON reports.
