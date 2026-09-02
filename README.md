# yt-dlp-ps

A PowerShell 7 front end for [yt-dlp](https://github.com/yt-dlp/yt-dlp) on Windows.

`yt-dlp` is excellent, but a long command line is not something you want to retype or paste
from a note every time. This wraps one opinionated, repeatable option set into a script and
a desktop shortcut: double click, paste a link or a bare video ID, and the file lands in
your download folder with thumbnail, chapters and metadata embedded.

It is a launcher, not a fork or a module. Every download is still done by `yt-dlp` itself.

```
=== [1/2] M-CdImxl9XI =================================================
[youtube] Extracting URL: https://www.youtube.com/watch?v=M-CdImxl9XI
[download] 100% of 1.07GiB in 00:03:53 at 4.71MiB/s
[Merger] Merging formats into "...[M-CdImxl9XI].mkv"
  -> done

=== Summary ===========================================================

Target      Status  Attempts Seconds Reason
------      ------  -------- ------- ------
M-CdImxl9XI Success        1   233.9
alpAGBQBIFs Skipped        1     1.2

  files are in: C:\TEMP\_YT-DLP
```

## Why not just run yt-dlp?

Because a bare command line has no answer for the things that actually go wrong:

- **Bare IDs.** Paste `M-CdImxl9XI` instead of a full URL. Playlist IDs, channel IDs and
  `@handles` work too, and an ID that starts with `-` no longer confuses PowerShell.
- **Preflight.** Checks that `yt-dlp` and `ffmpeg` exist, warns when `yt-dlp` is old (the
  usual cause of "formats have been skipped"), creates folders, and reports free space
  where the files actually land, following directory symlinks onto network shares.
- **One process per link.** A dead video in a batch cannot kill the rest.
- **Retry and classification.** Transient failures retry, permanent ones (removed, private,
  geo-blocked, bad option) do not, and every link is reported in a summary table.
- **Hints, not stack traces.** A bot check suggests cookies, a 429 suggests slowing down, a
  locked file says which one.
- **Structured logs.** One event per line, kept 30 days, for when you need to look back.
- **A download archive.** Finished IDs are recorded, so re-running skips what you have.
- **A lock.** Two copies cannot race the same archive file.

## Requirements

| | |
| --- | --- |
| **PowerShell 7.2+** (`pwsh`) | `winget install Microsoft.PowerShell` |
| **yt-dlp** on PATH | `winget install yt-dlp.yt-dlp` |
| **ffmpeg** on PATH | `winget install Gyan.FFmpeg` |

Windows PowerShell 5.1 is not supported. Without `ffmpeg` there is no merging, no embedded
thumbnail and no chapters, so the script warns you before it starts.

## Install

```powershell
git clone https://github.com/Rouzax/yt-dlp-ps.git
cd yt-dlp-ps
```

There is nothing to install and nothing is written to the registry. It is two scripts and
their tests.

## Quick start

```powershell
# a full URL
.\Invoke-YtDlp.ps1 https://www.youtube.com/watch?v=alpAGBQBIFs

# just the video ID
.\Invoke-YtDlp.ps1 M-CdImxl9XI

# an ID that starts with a dash: quote it (see below)
.\Invoke-YtDlp.ps1 '-CdImxl9XI'

# several at once, or a file with one link per line
.\Invoke-YtDlp.ps1 M-CdImxl9XI, alpAGBQBIFs
.\Invoke-YtDlp.ps1 -InputFile .\links.txt

# no arguments in a console: it asks
.\Invoke-YtDlp.ps1
```

By default files land in `C:\TEMP\_YT-DLP` and finished video IDs are recorded in
`C:\TEMP\yt-dlp_downloaded.txt`. Change both with `-OutputPath` and `-ArchivePath`.

## The desktop shortcut

```powershell
.\Install-YtDlpShortcut.ps1
```

Creates **`YT-DLP - Download.lnk`** on your desktop. Double click it, paste a URL or an ID,
press Enter on the empty line, and it downloads. The window stays open at the end so you can
read the summary. Nothing to escape at that prompt, so dash-leading IDs just work.

Point it somewhere else, or make a second one with different options:

```powershell
# audio only, into another folder
.\Install-YtDlpShortcut.ps1 -ShortcutName 'YT-DLP - Music' `
                            -OutputPath 'C:\TEMP\_YT-MUSIC' `
                            -ExtraScriptArguments '-AudioOnly'

# desktop and Start menu
.\Install-YtDlpShortcut.ps1 -Location Both
```

A shortcut of that name that already points at `Invoke-YtDlp.ps1` is updated in place. One
that points anywhere else is left untouched and reported: `WScript.Shell` opens an existing
`.lnk` and `Save()` would replace it silently. Pass `-Force` only when you really do mean to
take over that name.

Delete the `.lnk` to uninstall it.

## What it accepts

| You paste | It downloads |
| --- | --- |
| `https://www.youtube.com/watch?v=alpAGBQBIFs` | that video |
| `youtu.be/alpAGBQBIFs` (no scheme) | that video |
| `M-CdImxl9XI` | that video |
| `-CdImxl9XI` | that video (quote it on the command line) |
| `PLbpi6ZahtOH6Blw...` | that playlist |
| `UCHnyfMqiRRG1u-2MsSQLbXA` | that channel |
| `@veritasium` | that channel |
| `https://vimeo.com/123456789` | anything else yt-dlp supports |

Anything it cannot read is reported and skipped instead of being handed to `yt-dlp`.

### IDs that start with a dash

PowerShell reads a bare `-CdImxl9XI` as a parameter name, not as a value. Three ways around it:

- use the shortcut or `-Interactive` and paste it at the prompt, where nothing is parsed
- quote it: `.\Invoke-YtDlp.ps1 '-CdImxl9XI'`
- name the parameter: `.\Invoke-YtDlp.ps1 -Target '-CdImxl9XI'`

## What it runs

Every download is `yt-dlp` with this option set. `-WhatIf` prints the exact command line
without downloading anything.

| Option | Why |
| --- | --- |
| `--merge-output-format mkv` | one container that holds everything below |
| `--embed-thumbnail --convert-thumbnails png` | cover art inside the file |
| `--embed-chapters --embed-metadata` | chapters, title, uploader, date, description |
| `--sponsorblock-mark all` | sponsor segments marked as chapters, not removed |
| `--download-archive` | finished IDs recorded, so re-runs skip them |
| `--no-overwrites --no-post-overwrites --no-continue` | never clobber or resume into an existing file |
| `--windows-filenames` | strips characters Windows rejects |
| `--limit-rate 10M --sleep-interval 3 --max-sleep-interval 10` | stay polite, avoid rate limits |
| `--retries 10 --fragment-retries 10 --concurrent-fragments 2` | survive flaky connections |
| `--force-ipv4` | avoids broken IPv6 paths, disable with `-NoForceIPv4` |
| `--no-abort-on-error` | one dead video does not stop a playlist |
| `--newline` | lets the script draw its own progress line and log the rest |

## Options

| Option | Default | What it does |
| --- | --- | --- |
| `-OutputPath` | `C:\TEMP\_YT-DLP` | where the files go |
| `-ArchivePath` | `C:\TEMP\yt-dlp_downloaded.txt` | the "already downloaded" list |
| `-NoArchive` | off | ignore that list, download again |
| `-InputFile` | | a text file with one link per line (`#` starts a comment) |
| `-Interactive` | off | prompt for links, pause at the end |
| `-AudioOnly` `-AudioFormat` | off, `m4a` | extract audio instead of video |
| `-Subtitles` `-SubtitleLanguages` | off, `en.*` | write and embed subtitles |
| `-CookiesFromBrowser` | | `edge`, `chrome`, `firefox`, ... for age or bot checks |
| `-CookieFile` | | a `cookies.txt` instead of a browser |
| `-LimitRate` | `10M` | bandwidth cap |
| `-SleepInterval` `-MaxSleepInterval` | 3, 10 | delay between videos |
| `-ConcurrentFragments` | 2 | parallel fragments per video |
| `-MaxAttempts` | 2 | whole-video retries on a transient failure |
| `-TrimFilenames` | 0 (off) | cap the file name length when paths get too long |
| `-OutputTemplate` | yt-dlp default | custom `-o` template, see the recipe below |
| `-MergeFormat` | `mkv` | `mkv`, `mp4` or `webm` |
| `-NoSponsorBlock` | off | skip the SponsorBlock lookup |
| `-NoForceIPv4` | off | allow IPv6 |
| `-NoUpdate` | off | skip the `yt-dlp -U` that runs before every download |
| `-YtDlpPath` `-FfmpegLocation` | found on PATH | point at specific binaries |
| `-LogPath` | `%LOCALAPPDATA%\yt-dlp-ps\logs` | where the log goes |
| `-ExtraArgs` | | anything else, passed straight to yt-dlp |
| `-KeepOpen` | off | pause before the window closes |
| `-WhatIf` | off | show the command, download nothing |

`Get-Help .\Invoke-YtDlp.ps1 -Full` has the same list with more detail.

### Recipe: one subfolder per playlist

```powershell
.\Invoke-YtDlp.ps1 PLbpi6ZahtOH6Blw3RGYpWkSByi_T7Rygb `
    -OutputTemplate '%(playlist_title|)s/%(playlist_index&{} - |)s%(title)s [%(id)s].%(ext)s'
```

### Recipe: downloading to a network share

If `-OutputPath` is on an SMB share (including a local folder that is really a directory
symlink to one), merging and thumbnail embedding rewrite the whole file across the network.
Keep the intermediate files on a local disk and only send the finished file over:

```powershell
.\Invoke-YtDlp.ps1 M-CdImxl9XI -ExtraArgs '--paths', 'temp:C:\yt-dlp-work'
```

The free space line tells you which volume you are really writing to, so it is easy to spot
when a path like `C:\TEMP` is actually a share.

### Recipe: cap the quality

```powershell
.\Invoke-YtDlp.ps1 M-CdImxl9XI -ExtraArgs '-f', 'bv*[height<=1080]+ba/b'
```

## When something fails

The run ends with a per-link summary, a hint for the failures it recognises, and a log path:

```
Target      Status  Attempts Seconds Reason
------      ------  -------- ------- ------
alpAGBQBIFs Success        1    42.1
-CdImxl9XI1 Failed         1     2.5 ERROR: This video is unavailable

  hint: The video is removed, private or geo-blocked. Retrying will not help.
  log : C:\Users\<you>\AppData\Local\yt-dlp-ps\logs\yt-dlp-ps_20260902.log
```

Exit code is `0` when everything succeeded or was already in the archive, `1` when at least
one link failed, `130` when you pressed Ctrl+C.

| Symptom | What to do |
| --- | --- |
| "Sign in to confirm you're not a bot" | `-CookiesFromBrowser edge`, with that browser fully closed (it locks its cookie database) |
| Formats missing, signature or `nsig` errors | yt-dlp is too old: run without `-NoUpdate` so it can update itself |
| `HTTP Error 429` | raise `-SleepInterval` / `-MaxSleepInterval`, lower `-ConcurrentFragments`, wait |
| Nothing happens, "already been recorded" | it is in the archive; use `-NoArchive` to force |
| Path or file name too long | shorter `-OutputPath`, or `-TrimFilenames 120` |
| "another download is already running" | a second copy is using the same archive file; it waits up to 10 minutes |

Logs are structured, one event per line, kept for 30 days in
`%LOCALAPPDATA%\yt-dlp-ps\logs`:

```
2026-09-02T07:50:20.935Z INFO run=cbaa42dc download_end attempt=1 duration_ms=233900 exit_code=0 outcome=success target=M-CdImxl9XI
```

Never commit a `cookies.txt`: it is a live session credential. `.gitignore` already blocks it.

## Development

```powershell
.\tools\Invoke-Analyzer.ps1          # PSScriptAnalyzer over the whole repo
.\tools\Invoke-Tests.ps1             # Pester + coverage floor
.\tools\Invoke-Tests.ps1 -NoCoverage # faster loop while writing tests
```

The tests dot-source both scripts, which loads their functions without downloading anything
or touching your desktop. They cover URL/ID parsing, argument building, the process runner
(against a stand-in executable), exit-code classification, hints, logging and the shortcut
overwrite guard.

### Hooks

```powershell
pre-commit install --install-hooks
```

Both hooks are `repo: local` and shell out to `pwsh`, so no third-party hook code runs in
the commit path.

| Stage | Hook | What it does |
| --- | --- | --- |
| pre-commit | `psscriptanalyzer` | analyses the staged `.ps1` / `.psd1` files (fast) |
| pre-push | `pester` | full suite plus the coverage floor (slower) |

### Quality floor

Raise these, never lower them. Lowering one, or weakening a rule to make a change pass,
needs a deliberate decision and its own commit.

| Gate | Current | Target |
| --- | --- | --- |
| PSScriptAnalyzer | 0 Error, 0 Warning (`PSAvoidUsingWriteHost` excluded by design) | keep at 0 |
| Pester | 80 tests, all green | grows with each behaviour change |
| Statement coverage of `Invoke-YtDlp.ps1` | 46% | raise the floor whenever a change earns it |

Coverage is deliberately not chased to 100%: `Invoke-Main` and the interactive prompt would
need heavy mocking for little value. Everything else is held by the tests.

## Keeping yt-dlp current

`yt-dlp -U` runs before every download, by default. YouTube changes often and a stale
binary is the usual cause of "formats have been skipped", `nsig` errors and sudden
failures, so the couple of seconds it costs is worth it. If the binary is somehow still
more than 45 days old, the script says so.

```powershell
.\Invoke-YtDlp.ps1 -NoUpdate M-CdImxl9XI   # skip it: offline, in a hurry, or pinning a version
```

Prefer this self update over a package manager upgrade. `yt-dlp -U` replaces the binary in
place, which your package manager does not see, so its tracked version can drift well
behind what is actually installed and "upgrading" can move you backwards.

## License

MIT, see [LICENSE](LICENSE).

## Credits

All the hard work is done by [yt-dlp](https://github.com/yt-dlp/yt-dlp) and
[ffmpeg](https://ffmpeg.org/). This repository is only a front end.
