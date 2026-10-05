# Tests

Run from the repository root on Windows with existing `ffmpeg.exe` and `ffprobe.exe` on PATH. FFmpeg needs `libx264`, `aac`, and `libmp3lame` encoders plus the `lavfi` input. The suite was verified with FFmpeg 6.1, Windows PowerShell 5.1, and PowerShell 7. No Python, extra PowerShell modules, network share, or real media is needed.

```powershell
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1
```

An assertion or native-process failure terminates the run with a nonzero exit code. No execution-policy changes are made.

`Test-Join-Mp4.ps1` runs 19 regression checks for ordered copy/reencoding, different streams, silent clips, timestamp failures, incompatible inputs, output protection, native errors, and paths containing spaces, apostrophes, and Unicode. It checks decoded output, durations, frame counts, packet timing, and unchanged input hashes.

`Test-Avcc-Normalization.ps1` runs 11 focused checks against the production comparison functions. `New-AvccFixtures.ps1` generates a one-second MP4 and creates a second synthetic fixture with the optional AVC extension omitted. The tests verify that equivalent headers join correctly, genuine parameter-set changes remain incompatible, and unsupported or malformed data retains strict hash comparison. They also check mismatch messages and missing header data.

All generated files stay in unique subfolders of `tests/artifacts/`, including probe logs and JSON reports. Git ignores that folder. The suite never deletes artifacts or opens user media. It uses small 96x64 through 192x128 clips and low thread counts; run the two PowerShell versions sequentially.
