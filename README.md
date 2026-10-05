# Join MP4 files

`Join-Mp4.ps1` joins two or more local MP4 files in the order you supply. It keeps the originals and refuses to overwrite an existing output.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- `ffmpeg.exe` and `ffprobe.exe` on `PATH`, or explicit paths to those executables. Reencode mode needs FFmpeg's `libx264` and `aac` encoders.
- An existing output folder with enough free space for the joined video and retained work files.

The script installs nothing and requires no PowerShell modules or administrator access. It leaves execution policy unchanged. If your policy blocks scripts, use your usual approved process for running them.

## Quick start

Open PowerShell in the folder containing the script:

```powershell
.\Join-Mp4.ps1 -InputPaths @('C:\Videos\part 1.mp4', 'C:\Videos\part 2.mp4') -OutputPath 'C:\Videos\joined.mp4'
```

The array sets playback order. This command uses the default `Copy` mode, which joins compatible clips without reencoding.

Run `.\Join-Mp4.ps1` without arguments to enter paths at prompts. Supply at least two input paths, enter a blank line to end the list, then enter the output path. At the prompts, enter paths without surrounding quotes. There is no file picker.

Spaces, apostrophes, and Unicode paths are supported. In PowerShell single-quoted strings, double an embedded apostrophe, for example `'C:\Videos\O''Brien.mp4'`. Relative paths resolve from the current PowerShell folder. Use a PowerShell array as shown; passing a comma-separated string through `cmd.exe -File` does not supply an array.

## Copy and reencode modes

### Copy

Copy mode compares stream layout, codec settings, dimensions, base frame rates, time bases, audio format, codec headers, and display information. A mismatch stops the join and lists the differing fields. Review those differences before choosing Reencode. The check is conservative, so it can reject files that FFmpeg could otherwise join.

Different average frame rates are allowed. Frame gaps can change that average without changing the codec settings, base frame rate, or time base. Copy mode preserves relative packet timing within each clip, including those gaps.

For 8-bit 4:2:0 H.264 High-profile MP4s, the check treats an absent AVC configuration extension as equivalent to the exact `FD F8 F8 00` extension added by some remuxers. It validates the header structure and compares all SPS/PPS bytes and the other settings. Unknown extensions and meaningful header differences still require matching hashes of the complete headers.

Copy mode preserves existing audio/video duration differences. Container timing, AAC priming, or damaged packets can still cause problems even when probe data matches.

### Reencode

Use `-Mode Reencode` for mismatched clips or a timestamp error in Copy mode:

```powershell
.\Join-Mp4.ps1 -InputPaths @('C:\Videos\part 1.mp4', 'C:\Videos\part 2.mp4') -OutputPath 'C:\Videos\joined-normalized.mp4' -Mode Reencode
```

Reencoding takes longer and changes quality. By default, it:

- Produces H.264 video at 30 fps with square pixels.
- Fits each clip into the first video's coded width and height, rounded up to even numbers, and pads unused space.
- Produces AAC stereo at 48 kHz if any input has audio. Clips without audio get silence; if all inputs lack audio, the output has no audio track.
- Pads or trims audio to each clip's video duration.

Reencode mode requires a valid, positive video duration for every clip. It resets each stream's starting timestamp, so intentional audio/video start offsets are not preserved. FFmpeg applies its normal autorotation to rotated footage. Supply explicit dimensions if the first clip's coded dimensions are not the canvas you want.

HDR reencoding is rejected because the script has no tone-mapping workflow. Use Reencode for ordinary SDR clips. Copy mode may preserve compatible HDR files.

## Options

To set the Reencode output dimensions and frame rate:

```powershell
.\Join-Mp4.ps1 -InputPaths @('a.mp4', 'b.mp4') -OutputPath 'joined.mp4' `
    -Mode Reencode -Width 1920 -Height 1080 -FrameRate '30000/1001'
```

| Option | Default | Use |
| --- | --- | --- |
| `-Width`, `-Height` | First video's coded dimensions, rounded up to even numbers | Supply both as positive even integers up to 16384, or omit both. Requires Reencode. |
| `-FrameRate` | `30` | A positive integer or fraction, such as `'30000/1001'`. Requires Reencode. |
| `-Crf` | `20` | H.264 quality setting from 0 to 51. Lower values use more space for better quality. Requires Reencode. |
| `-Threads` | `2` | Encoding and decoding threads in Reencode mode, from 1 to 16. The filter graph uses one thread. |

More inputs can increase resource use even with low thread counts.

To use executable paths instead of `PATH`, supply `-FFmpegPath` and `-FFprobePath`. These work in either mode:

```powershell
.\Join-Mp4.ps1 -InputPaths @('a.mp4', 'b.mp4') -OutputPath 'joined.mp4' `
    -FFmpegPath 'C:\tools\ffmpeg\bin\ffmpeg.exe' `
    -FFprobePath 'C:\tools\ffmpeg\bin\ffprobe.exe'
```

## Supported files

Each input must be a local `.mp4` file with exactly one video stream and at most one audio stream. Extra tracks, subtitles, data streams, and cover art are rejected. Both modes omit chapters and container metadata. The output path must also end in `.mp4`.

## Output and logs

The script writes to `Join-Mp4-work-<unique-id>` beside the destination first. It moves the result to the requested name only after FFmpeg succeeds, the file is nonempty, and ffprobe confirms one video stream. The move refuses to overwrite a file, including one created by another process during the join.

Known timestamp warnings stop the join before that move. In Copy mode, the error suggests retrying with `-Mode Reencode`. Other FFmpeg warnings appear in PowerShell and in the logs. The output check does not fully decode the video. Check playback around the join before relying on the result.

The script prints the work folder's path and keeps all probe results, command arguments, FFmpeg logs, and any failed partial output. These files include media paths. The script never deletes them; remove retained folders yourself when you no longer need them.

Errors terminate the script and produce a nonzero exit code when you invoke it with `powershell.exe -File` or `pwsh -File`.

## Tests

Run the 30 checks from the repository root:

```powershell
.\tests\Run-Tests.ps1
```

The suite uses small synthetic clips and requires no Python or user media. It keeps fixtures, outputs, logs, and JSON reports in the Git-ignored `tests/artifacts/` folder. See the [test instructions](tests/README.md) for FFmpeg prerequisites, coverage, and commands for both PowerShell versions.

The suite has passed with FFmpeg 6.1, Windows PowerShell 5.1.19041.7725, and PowerShell 7.6.5. Each run records its PowerShell version and results in the retained JSON reports.

## References

The FFmpeg documentation explains the operations used by the script:

- [Concat demuxer](https://ffmpeg.org/ffmpeg-formats.html#concat): matching stream requirements, path quoting, and timestamp/duration limitations.
- [Concat filter](https://www.ffmpeg.org/ffmpeg-filters.html#concat): zero-based segment timestamps and explicit resolution conversion.
- [Main options](https://ffmpeg.org/ffmpeg.html#Main-options): stream copy and the `-n` refusal to overwrite.
- [AVC configuration writer](https://ffmpeg.org/doxygen/trunk/avc_8c_source.html): the optional High-profile chroma and bit-depth extension.
