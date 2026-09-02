#Requires -Version 7.2

<#
.SYNOPSIS
    Downloads YouTube (or any yt-dlp supported) video with a safe, repeatable option set.

.DESCRIPTION
    Wrapper around yt-dlp.exe that adds the parts a bare command line does not give you:

      * accepts a full URL, a bare video ID (also one starting with '-'), a playlist ID,
        a channel ID or an @handle, and normalises it into a real URL
      * checks that yt-dlp and ffmpeg exist before starting, and warns when yt-dlp is stale
      * creates the output and archive folders, checks free disk space
      * runs one yt-dlp process per target so a single bad link cannot kill the batch
      * retries a failed target, then prints a per-target summary and actionable hints
      * writes a structured log file for post-mortem
      * refuses to run two copies against the same download archive at the same time

.PARAMETER Target
    One or more URLs / IDs. Quote anything that starts with a dash, otherwise PowerShell
    reads it as a parameter name: .\Invoke-YtDlp.ps1 '-CdImxl9XI'

.PARAMETER OutputPath
    Folder the finished files are written to. Created if missing.

.PARAMETER ArchivePath
    yt-dlp download archive. Every completed video ID is appended here and skipped on
    later runs. Use -NoArchive to ignore it for one run.

.PARAMETER InputFile
    Text file with one URL / ID per line (# starts a comment).

.EXAMPLE
    .\Invoke-YtDlp.ps1 https://www.youtube.com/watch?v=alpAGBQBIFs

.EXAMPLE
    .\Invoke-YtDlp.ps1 M-CdImxl9XI, '-CdImxl9XI' -OutputPath 'D:\Video'

.EXAMPLE
    .\Invoke-YtDlp.ps1 -Interactive
    Asks for the URLs, then downloads. This is what the desktop shortcut runs.

.EXAMPLE
    .\Invoke-YtDlp.ps1 PLxxxxxxxxxxxxxxxxx -CookiesFromBrowser edge -Subtitles

.NOTES
    Author : Rouzax
    Needs  : PowerShell 7.2+ (pwsh), yt-dlp.exe and ffmpeg.exe on PATH
             (or -YtDlpPath / -FfmpegLocation)
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'Script parameters are read from script scope inside Invoke-Main, which the rule cannot follow.')]
param(
    [Parameter(Position = 0)]
    [Alias('Url', 'Id')]
    [string[]] $Target,

    [Alias('P', 'Output')]
    [string] $OutputPath = 'C:\TEMP\_YT-DLP',

    [Alias('Archive')]
    [string] $ArchivePath = 'C:\TEMP\yt-dlp_downloaded.txt',

    [string] $InputFile,

    [switch] $Interactive,

    [switch] $NoArchive,

    [ValidateSet('mkv', 'mp4', 'webm')]
    [string] $MergeFormat = 'mkv',

    [switch] $AudioOnly,

    [ValidateSet('m4a', 'mp3', 'opus', 'flac', 'wav', 'vorbis', 'aac', 'best')]
    [string] $AudioFormat = 'm4a',

    [ValidatePattern('^\d+(\.\d+)?[KMGkmg]?$')]
    [string] $LimitRate = '10M',

    [ValidateRange(0, 3600)]
    [int] $SleepInterval = 3,

    [ValidateRange(0, 3600)]
    [int] $MaxSleepInterval = 10,

    [ValidateRange(0, 100)]
    [int] $Retries = 10,

    [ValidateRange(0, 100)]
    [int] $FragmentRetries = 10,

    [ValidateRange(1, 16)]
    [int] $ConcurrentFragments = 2,

    [ValidateRange(1, 10)]
    [int] $MaxAttempts = 2,

    [ValidateRange(0, 250)]
    [int] $TrimFilenames = 0,

    [string] $OutputTemplate,

    [switch] $Subtitles,

    [string] $SubtitleLanguages = 'en.*',

    [ValidateSet('brave', 'chrome', 'chromium', 'edge', 'firefox', 'opera', 'safari', 'vivaldi', 'whale')]
    [string] $CookiesFromBrowser,

    [string] $CookieFile,

    [switch] $NoSponsorBlock,

    [switch] $NoForceIPv4,

    [string] $YtDlpPath,

    [string] $FfmpegLocation,

    [string] $LogPath,

    [switch] $Update,

    [switch] $KeepOpen,

    [string[]] $ExtraArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Run state
# ---------------------------------------------------------------------------
$script:RunId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$script:LogFile = $null
$script:StaleAfterDays = 45

# Ordered: every matching pattern in the captured yt-dlp output produces a hint.
$script:FailureHints = @(
    @{
        Pattern = 'Sign in to confirm|not a bot|Use --cookies|age-restricted|Private video'
        Hint    = 'YouTube wants a signed-in session. Re-run with -CookiesFromBrowser edge (close that browser first) or -CookieFile cookies.txt.'
    }
    @{
        Pattern = 'video (is )?unavailable|has been removed|is not available in your country|blocked it in your country'
        Hint    = 'The video is removed, private or geo-blocked. Retrying will not help.'
    }
    @{
        Pattern = 'HTTP Error 429|Too Many Requests|throttl'
        Hint    = 'Rate limited. Raise -SleepInterval / -MaxSleepInterval, lower -ConcurrentFragments and -LimitRate, and try again later.'
    }
    @{
        Pattern = 'nsig extraction failed|Signature extraction failed|formats have been skipped'
        Hint    = 'yt-dlp is out of date for the current YouTube player. Update it and retry.'
    }
    @{
        Pattern = 'ffmpeg not found|ffprobe and ffmpeg not found|You have requested merging'
        Hint    = 'ffmpeg is required for merging, thumbnails and chapters. Install with: winget install Gyan.FFmpeg'
    }
    @{
        Pattern = 'Requested format is not available'
        Hint    = "That format does not exist for this video. List formats with -ExtraArgs '-F', then pick one with -ExtraArgs '-f','<id>'."
    }
    @{
        Pattern = 'being used by another process|Access is denied|Unable to rename file|Permission denied'
        Hint    = 'A file in the output folder is locked (player, antivirus, indexer, or a network share). Close it and retry.'
    }
    @{
        Pattern = 'filename or extension is too long|path too long|No such file or directory'
        Hint    = 'Windows path length limit. Use a shorter -OutputPath or add -TrimFilenames 120.'
    }
    @{
        Pattern = 'Unable to download webpage|getaddrinfo failed|Connection reset|timed out|SSLError'
        Hint    = 'Network or DNS problem. Check the connection, VPN or proxy, then retry.'
    }
    @{
        Pattern = 'No space left|There is not enough space'
        Hint    = 'The target drive is full.'
    }
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Initialize-Log {
    [CmdletBinding()]
    param([string] $Path)

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $Path = Join-Path (Join-Path $env:LOCALAPPDATA 'yt-dlp-ps\logs') ('yt-dlp-ps_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        }
        # Housekeeping is exempt from -WhatIf: the log describes the run either way.
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false
        }
        Add-Content -LiteralPath $Path -Value '' -Encoding UTF8 -WhatIf:$false
        $script:LogFile = $Path

        # Best effort retention, never fatal.
        if ($dir) {
            Get-ChildItem -LiteralPath $dir -Filter 'yt-dlp-ps_*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
                Remove-Item -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    } catch {
        $script:LogFile = $null
        Write-Host ('  [warn] file logging disabled: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Write-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory)]
        [string] $EventName,

        [hashtable] $Data,

        [string] $Message,

        [switch] $NoConsole
    )

    $fields = ''
    if ($Data -and $Data.Count -gt 0) {
        $pairs = foreach ($key in ($Data.Keys | Sort-Object)) {
            $value = [string]$Data[$key]
            if ($value -match '[\s"=]') { $value = '"' + ($value -replace '"', "'") + '"' }
            "$key=$value"
        }
        $fields = ' ' + ($pairs -join ' ')
    }

    $line = '{0} {1} run={2} {3}{4}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'), $Level, $script:RunId, $EventName, $fields

    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
        } catch {
            $script:LogFile = $null
            Write-Host '  [warn] file logging disabled after a write error' -ForegroundColor DarkYellow
        }
    }

    if ($NoConsole) { return }
    if ($Level -eq 'DEBUG' -and $VerbosePreference -eq 'SilentlyContinue') { return }

    $text = if ($Message) { $Message } else { $line }
    switch ($Level) {
        'ERROR' { Write-Host "  [x] $text" -ForegroundColor Red }
        'WARN' { Write-Host "  [!] $text" -ForegroundColor Yellow }
        'DEBUG' { Write-Host "  [d] $text" -ForegroundColor DarkGray }
        default { Write-Host "  [i] $text" -ForegroundColor Gray }
    }
}

function Write-Section {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Text)

    Write-Host ''
    Write-Host ('=== {0} {1}' -f $Text, ('=' * [Math]::Max(3, 66 - $Text.Length))) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------
function ConvertTo-YtDlpTarget {
    <#
    .SYNOPSIS
        Turns user input (URL, video ID, playlist ID, channel ID, @handle) into a URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $InputValue
    )

    $value = if ($null -eq $InputValue) { '' } else { $InputValue }
    $value = $value.Trim().Trim('"', "'", '<', '>').Trim()

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Empty target.'
    }

    # Already an absolute URL.
    if ($value -match '^(?<scheme>[a-z][a-z0-9+.\-]*)://') {
        if ($Matches.scheme -notin @('http', 'https')) {
            throw ("Unsupported URL scheme '{0}' in '{1}'. Only http and https are accepted." -f $Matches.scheme, $value)
        }
        return $value
    }

    # Scheme-less URL, e.g. www.youtube.com/watch?v=... or youtu.be/ID
    if ($value -match '^[a-z0-9][a-z0-9\-]*(\.[a-z0-9\-]+)+(/|\?)') {
        return "https://$value"
    }

    # Channel handle, e.g. @veritasium
    if ($value -match '^@[A-Za-z0-9._\-]{3,30}$') {
        return "https://www.youtube.com/$value"
    }

    # A video ID is exactly 11 characters and may start with '-' or '_'.
    if ($value -match '^[A-Za-z0-9_\-]{11}$') {
        return "https://www.youtube.com/watch?v=$value"
    }

    # Channel ID.
    if ($value -match '^UC[A-Za-z0-9_\-]{22}$') {
        return "https://www.youtube.com/channel/$value"
    }

    # Playlist ID (always longer than a video ID).
    if ($value -match '^(PL|UU|OL|RD|LL|FL|TL|UL|SP)[A-Za-z0-9_\-]{10,}$') {
        return "https://www.youtube.com/playlist?list=$value"
    }

    throw ("Cannot read '{0}' as a URL, video ID, playlist ID, channel ID or @handle." -f $InputValue)
}

function Get-TargetLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Url)

    if ($Url -match '[?&]list=([A-Za-z0-9_\-]+)') { return 'list:' + $Matches[1] }
    if ($Url -match '[?&]v=([A-Za-z0-9_\-]{11})') { return $Matches[1] }
    if ($Url -match 'youtu\.be/([A-Za-z0-9_\-]{11})') { return $Matches[1] }
    if ($Url.Length -le 60) { return $Url }
    return $Url.Substring(0, 57) + '...'
}

function Read-TargetFromFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Input file not found: $Path"
    }
    return @(Get-Content -LiteralPath $Path |
            ForEach-Object { ($_ -split '#', 2)[0].Trim() } |
            Where-Object { $_ })
}

function Read-InteractiveTarget {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $collected = New-Object System.Collections.Generic.List[string]

    Write-Host ''
    Write-Host '  Paste a YouTube URL or ID (for example M-CdImxl9XI or -CdImxl9XI).' -ForegroundColor White
    Write-Host '  More than one is fine: one per line, or separated by spaces.' -ForegroundColor DarkGray
    Write-Host '  Empty line = start downloading.   Q = quit.' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $raw = Read-Host ('  [{0}]' -f ($collected.Count + 1))
        if ($null -eq $raw) { break }
        $raw = $raw.Trim()

        if ($raw -eq '') {
            if ($collected.Count -gt 0) { break }
            Write-Host '      Nothing entered yet. Paste a link, or type Q to quit.' -ForegroundColor DarkGray
            continue
        }
        if ($raw -in @('q', 'quit', 'exit')) { return @() }

        foreach ($part in ($raw -split '[\s,;]+' | Where-Object { $_ })) {
            try {
                $url = ConvertTo-YtDlpTarget -InputValue $part
                $collected.Add($url)
                Write-Host ('      ok  -> {0}' -f $url) -ForegroundColor DarkGreen
            } catch {
                Write-Host ('      bad -> {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }

    return @($collected.ToArray())
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
function Resolve-FullPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Resolve-YtDlpExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Path)

    if ($Path) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-FullPath $Path) }
        throw "yt-dlp not found at -YtDlpPath '$Path'."
    }

    $found = Get-Command -Name 'yt-dlp.exe', 'yt-dlp' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.Source }

    throw 'yt-dlp was not found on PATH. Install it (winget install yt-dlp.yt-dlp) or pass -YtDlpPath.'
}

function Test-Environment {
    <#
    .SYNOPSIS
        Non-fatal environment checks. Writes warnings, never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExePath,
        [Parameter(Mandatory)][string] $DownloadPath,
        [string] $Ffmpeg
    )

    # ffmpeg is required for merging, thumbnail embedding and chapters.
    if ($Ffmpeg) {
        if (-not (Test-Path -LiteralPath $Ffmpeg)) {
            Write-RunLog -Level WARN -EventName 'ffmpeg_missing' -Data @{ path = $Ffmpeg } -Message "-FfmpegLocation '$Ffmpeg' does not exist."
        }
    } elseif (-not (Get-Command -Name 'ffmpeg.exe', 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-RunLog -Level WARN -EventName 'ffmpeg_missing' -Message 'ffmpeg was not found on PATH. Merging, thumbnails and chapters will fail. Install with: winget install Gyan.FFmpeg'
    }

    # A stale yt-dlp is the single most common cause of YouTube breakage.
    try {
        $version = ([string](& $ExePath '--version' 2>&1 | Select-Object -First 1)).Trim()
        Write-RunLog -Level INFO -EventName 'ytdlp_version' -Data @{ version = $version; path = $ExePath } -NoConsole
        Write-Host ('  yt-dlp    : {0}  ({1})' -f $version, $ExePath) -ForegroundColor DarkGray

        if ($version -match '^(\d{4})\.(\d{2})\.(\d{2})') {
            $released = Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour 0 -Minute 0 -Second 0
            $age = [int]((Get-Date) - $released).TotalDays
            if ($age -gt $script:StaleAfterDays) {
                $how = if ($ExePath -like '*WinGet*' -or $ExePath -like "$env:ProgramFiles*") {
                    'winget upgrade yt-dlp.yt-dlp'
                } else {
                    "$ExePath -U   (or re-run this script with -Update)"
                }
                Write-RunLog -Level WARN -EventName 'ytdlp_stale' -Data @{ version = $version; age_days = $age } -Message ('yt-dlp is {0} days old. YouTube changes often, update with: {1}' -f $age, $how)
            }
        }
    } catch {
        Write-RunLog -Level WARN -EventName 'ytdlp_version_failed' -Message "Could not read the yt-dlp version: $($_.Exception.Message)"
    }

    # Free space on the target drive.
    try {
        $root = [System.IO.Path]::GetPathRoot($DownloadPath)
        if ($root -and $root -match '^[A-Za-z]:') {
            $drive = Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue
            if ($drive -and $null -ne $drive.Free) {
                $freeGb = [Math]::Round($drive.Free / 1GB, 1)
                Write-Host ('  free space: {0} GB on {1}' -f $freeGb, $root) -ForegroundColor DarkGray
                if ($drive.Free -lt 5GB) {
                    Write-RunLog -Level WARN -EventName 'low_disk_space' -Data @{ free_gb = $freeGb; drive = $root } -Message ('Only {0} GB free on {1}.' -f $freeGb, $root)
                }
            }
        }
    } catch {
        Write-RunLog -Level DEBUG -EventName 'disk_check_failed' -Message $_.Exception.Message
    }
}

function Update-YtDlp {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $ExePath)

    if (-not $PSCmdlet.ShouldProcess($ExePath, 'yt-dlp self update')) { return }

    Write-Section 'Updating yt-dlp'
    try {
        & $ExePath '-U'
        Write-RunLog -Level INFO -EventName 'ytdlp_update' -Data @{ exit_code = $LASTEXITCODE } -NoConsole
        if ($LASTEXITCODE -ne 0) {
            Write-RunLog -Level WARN -EventName 'ytdlp_update_failed' -Message 'Self-update failed. If yt-dlp lives in Program Files, update it with: winget upgrade yt-dlp.yt-dlp'
        }
    } catch {
        Write-RunLog -Level WARN -EventName 'ytdlp_update_failed' -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# yt-dlp invocation
# ---------------------------------------------------------------------------
function Get-YtDlpArgumentList {
    <#
    .SYNOPSIS
        Builds the shared yt-dlp argument list (everything except the URL).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $Options)

    $arguments = New-Object System.Collections.Generic.List[string]

    $arguments.Add('--no-continue')
    $arguments.Add('--no-overwrites')
    $arguments.Add('--no-post-overwrites')
    $arguments.Add('--no-abort-on-error')
    $arguments.Add('--windows-filenames')
    $arguments.Add('--newline')

    if (-not $Options.NoForceIPv4) { $arguments.Add('--force-ipv4') }

    if ($Options.AudioOnly) {
        $arguments.AddRange([string[]]@('--extract-audio', '--audio-format', $Options.AudioFormat, '--audio-quality', '0'))
    } else {
        $arguments.AddRange([string[]]@('--merge-output-format', $Options.MergeFormat))
    }

    if (-not $Options.NoArchive) {
        $arguments.AddRange([string[]]@('--download-archive', $Options.ArchivePath))
    }

    $arguments.AddRange([string[]]@('--sleep-interval', [string]$Options.SleepInterval))
    $arguments.AddRange([string[]]@('--max-sleep-interval', [string]$Options.MaxSleepInterval))
    $arguments.AddRange([string[]]@('--limit-rate', $Options.LimitRate))
    $arguments.AddRange([string[]]@('--retries', [string]$Options.Retries))
    $arguments.AddRange([string[]]@('--fragment-retries', [string]$Options.FragmentRetries))
    $arguments.AddRange([string[]]@('--concurrent-fragments', [string]$Options.ConcurrentFragments))

    $arguments.AddRange([string[]]@('--embed-thumbnail', '--convert-thumbnails', 'png'))
    $arguments.Add('--embed-chapters')
    $arguments.Add('--embed-metadata')

    if (-not $Options.NoSponsorBlock) {
        $arguments.AddRange([string[]]@('--sponsorblock-mark', 'all'))
    }

    if ($Options.Subtitles) {
        $arguments.AddRange([string[]]@('--write-subs', '--write-auto-subs', '--sub-langs', $Options.SubtitleLanguages, '--embed-subs'))
    }

    if ($Options.TrimFilenames -gt 0) {
        $arguments.AddRange([string[]]@('--trim-filenames', [string]$Options.TrimFilenames))
    }

    if ($Options.OutputTemplate) {
        $arguments.AddRange([string[]]@('-o', $Options.OutputTemplate))
    }

    if ($Options.CookiesFromBrowser) {
        $arguments.AddRange([string[]]@('--cookies-from-browser', $Options.CookiesFromBrowser))
    }
    if ($Options.CookieFile) {
        $arguments.AddRange([string[]]@('--cookies', $Options.CookieFile))
    }
    if ($Options.FfmpegLocation) {
        $arguments.AddRange([string[]]@('--ffmpeg-location', $Options.FfmpegLocation))
    }

    $arguments.AddRange([string[]]@('-P', $Options.OutputPath))

    if ($Options.Verbose) { $arguments.Add('--verbose') }
    if ($Options.ExtraArgs) { $arguments.AddRange([string[]]$Options.ExtraArgs) }

    return $arguments.ToArray()
}

function Invoke-YtDlpProcess {
    <#
    .SYNOPSIS
        Runs yt-dlp once, streams progress to the console, returns the exit code and output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $ExePath,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    # Native exit codes are data here, never terminating errors.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false

    $captured = New-Object System.Collections.Generic.List[string]
    $onProgressLine = $false

    # In-place progress needs a real console. When output is redirected (scheduled task,
    # transcript, `> out.txt`) carriage returns would pile up into one huge line, so there
    # we keep only the finished-fragment lines.
    $isConsole = $true
    try { $isConsole = -not [Console]::IsOutputRedirected } catch { $isConsole = $false }

    $width = 100
    try { $width = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 2) } catch { $width = 100 }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    & $ExePath @Arguments 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $line = $line.TrimEnd()

        if ($line -match '^\[download\]\s+\d') {
            $isComplete = $line -match '\s100(\.0+)?%'
            if ($isConsole) {
                # Overwrite the same console line instead of scrolling.
                $shown = if ($line.Length -gt $width) { $line.Substring(0, $width) } else { $line.PadRight($width) }
                Write-Host ("`r" + $shown) -NoNewline -ForegroundColor DarkCyan
                $onProgressLine = $true
            } elseif ($isComplete) {
                Write-Host $line
            }
            if ($isComplete) { $captured.Add($line) }
            return
        }

        if ($onProgressLine) { Write-Host ''; $onProgressLine = $false }
        $captured.Add($line)

        if ($line -match '^ERROR:') { Write-Host $line -ForegroundColor Red }
        elseif ($line -match '^WARNING:') { Write-Host $line -ForegroundColor Yellow }
        elseif ($line -match 'has already been (recorded|downloaded)') { Write-Host $line -ForegroundColor DarkGreen }
        else { Write-Host $line }
    }

    if ($onProgressLine) { Write-Host '' }
    $stopwatch.Stop()

    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Output     = $captured
        DurationMs = [int]$stopwatch.Elapsed.TotalMilliseconds
    }
}

function Get-RunOutcome {
    <#
    .SYNOPSIS
        Maps a yt-dlp exit code plus its output to Success / Skipped / Cancelled / Failed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int] $ExitCode,
        [AllowNull()][AllowEmptyCollection()][string[]] $Output
    )

    $text = if ($Output) { $Output -join "`n" } else { '' }

    if ($ExitCode -eq 0) {
        $status = if ($text -match 'has already been (recorded|downloaded)' -and $text -notmatch '\[download\] Destination') {
            'Skipped'
        } else {
            'Success'
        }
        return [pscustomobject]@{ Status = $status; Retry = $false; Reason = '' }
    }

    # 130 = SIGINT, -1073741510 = 0xC000013A, console Ctrl+C on Windows.
    if ($ExitCode -in @(130, -1073741510)) {
        return [pscustomobject]@{ Status = 'Cancelled'; Retry = $false; Reason = 'Cancelled by user' }
    }
    if ($ExitCode -eq 101) {
        return [pscustomobject]@{ Status = 'Success'; Retry = $false; Reason = 'Stopped by --max-downloads' }
    }
    if ($ExitCode -eq 2) {
        return [pscustomobject]@{ Status = 'Failed'; Retry = $false; Reason = 'Bad yt-dlp option (check -ExtraArgs)' }
    }

    # Permanent content problems are not worth a second attempt.
    if ($text -match 'video (is )?unavailable|has been removed|Private video|members-only|is not available in your country') {
        return [pscustomobject]@{ Status = 'Failed'; Retry = $false; Reason = 'Video not available' }
    }

    $reason = @($Output | Where-Object { $_ -match '^ERROR:' } | Select-Object -Last 1)
    $reasonText = if ($reason.Count -gt 0) { [string]$reason[0] } else { "yt-dlp exit code $ExitCode" }
    return [pscustomobject]@{ Status = 'Failed'; Retry = $true; Reason = $reasonText }
}

function Get-FailureHint {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyCollection()][string[]] $Output)

    if (-not $Output -or $Output.Count -eq 0) { return @() }
    $text = $Output -join "`n"

    $hints = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $script:FailureHints) {
        if ($text -match $entry.Pattern) { $hints.Add($entry.Hint) }
    }
    return @($hints | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Main {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Debug 'Console encoding left unchanged.' }

    Initialize-Log -Path $LogPath

    Write-Host ''
    Write-Host '  yt-dlp downloader' -ForegroundColor Cyan
    Write-Host '  -----------------' -ForegroundColor Cyan

    if ($MaxSleepInterval -lt $SleepInterval) {
        throw "-MaxSleepInterval ($MaxSleepInterval) must be greater than or equal to -SleepInterval ($SleepInterval)."
    }
    if ($CookieFile -and -not (Test-Path -LiteralPath $CookieFile -PathType Leaf)) {
        throw "-CookieFile not found: $CookieFile"
    }

    $exePath = Resolve-YtDlpExecutable -Path $YtDlpPath
    $resolvedOutput = Resolve-FullPath $OutputPath
    $resolvedArchive = Resolve-FullPath $ArchivePath

    Write-Host ('  output    : {0}' -f $resolvedOutput) -ForegroundColor DarkGray
    Write-Host ('  archive   : {0}' -f $(if ($NoArchive) { 'disabled (-NoArchive)' } else { $resolvedArchive })) -ForegroundColor DarkGray
    if ($script:LogFile) { Write-Host ('  log       : {0}' -f $script:LogFile) -ForegroundColor DarkGray }

    Test-Environment -ExePath $exePath -DownloadPath $resolvedOutput -Ffmpeg $FfmpegLocation
    if ($Update) { Update-YtDlp -ExePath $exePath }

    # --- collect targets --------------------------------------------------
    $rawTargets = New-Object System.Collections.Generic.List[string]
    if ($Target) { $rawTargets.AddRange([string[]]$Target) }
    if ($InputFile) { $rawTargets.AddRange([string[]](Read-TargetFromFile -Path $InputFile)) }

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($item in $rawTargets) {
        try {
            $urls.Add((ConvertTo-YtDlpTarget -InputValue $item))
        } catch {
            Write-RunLog -Level ERROR -EventName 'target_rejected' -Data @{ input = $item } -Message $_.Exception.Message
        }
    }

    if (($urls.Count -eq 0 -and $Host.Name -eq 'ConsoleHost') -or ($Interactive -and $urls.Count -eq 0)) {
        foreach ($url in (Read-InteractiveTarget)) { $urls.Add($url) }
    }

    if ($urls.Count -eq 0) {
        Write-RunLog -Level WARN -EventName 'no_targets' -Message 'Nothing to download.'
        return 0
    }

    # --- prepare folders --------------------------------------------------
    foreach ($dir in @($resolvedOutput, (Split-Path -Path $resolvedArchive -Parent))) {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
            Write-RunLog -Level INFO -EventName 'directory_created' -Data @{ path = $dir } -NoConsole
        }
    }
    if (-not $NoArchive -and -not (Test-Path -LiteralPath $resolvedArchive)) {
        $null = New-Item -ItemType File -Path $resolvedArchive -Force
    }

    $options = @{
        NoForceIPv4         = [bool]$NoForceIPv4
        AudioOnly           = [bool]$AudioOnly
        AudioFormat         = $AudioFormat
        MergeFormat         = $MergeFormat
        NoArchive           = [bool]$NoArchive
        ArchivePath         = $resolvedArchive
        OutputPath          = $resolvedOutput
        SleepInterval       = $SleepInterval
        MaxSleepInterval    = $MaxSleepInterval
        LimitRate           = $LimitRate
        Retries             = $Retries
        FragmentRetries     = $FragmentRetries
        ConcurrentFragments = $ConcurrentFragments
        NoSponsorBlock      = [bool]$NoSponsorBlock
        Subtitles           = [bool]$Subtitles
        SubtitleLanguages   = $SubtitleLanguages
        TrimFilenames       = $TrimFilenames
        OutputTemplate      = $OutputTemplate
        CookiesFromBrowser  = $CookiesFromBrowser
        CookieFile          = $CookieFile
        FfmpegLocation      = $FfmpegLocation
        ExtraArgs           = $ExtraArgs
        Verbose             = ($VerbosePreference -ne 'SilentlyContinue')
    }
    $baseArguments = Get-YtDlpArgumentList -Options $options

    Write-RunLog -Level INFO -EventName 'run_start' -Data @{
        targets = $urls.Count
        output  = $resolvedOutput
        archive = $(if ($NoArchive) { 'none' } else { $resolvedArchive })
    } -NoConsole

    # Two runs sharing one archive file can race, so serialise on the archive path.
    $mutexName = 'Local\ytdlp-ps-' + [Math]::Abs($resolvedArchive.ToLowerInvariant().GetHashCode())
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $holdsMutex = $false
    $results = New-Object System.Collections.Generic.List[pscustomobject]
    $allOutput = New-Object System.Collections.Generic.List[string]

    try {
        $holdsMutex = $mutex.WaitOne(0)
        if (-not $holdsMutex) {
            Write-RunLog -Level WARN -EventName 'lock_wait' -Message 'Another download is already running against this archive. Waiting up to 10 minutes...'
            $holdsMutex = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
            if (-not $holdsMutex) { throw 'Timed out waiting for the other download to finish.' }
        }

        $index = 0
        foreach ($url in $urls) {
            $index++
            $label = Get-TargetLabel -Url $url
            Write-Section ('[{0}/{1}] {2}' -f $index, $urls.Count, $label)
            try { $Host.UI.RawUI.WindowTitle = 'yt-dlp  {0}/{1}  {2}' -f $index, $urls.Count, $label } catch { Write-Debug 'Window title left unchanged.' }

            if ($WhatIfPreference) {
                Write-Host ('  What if: {0} {1} {2}' -f $exePath, ($baseArguments -join ' '), $url) -ForegroundColor DarkGray
                $results.Add([pscustomobject]@{ Target = $label; Status = 'WhatIf'; Attempts = 0; Seconds = 0; Reason = '' })
                continue
            }

            $attempt = 0
            $outcome = $null
            $run = $null
            while ($attempt -lt $MaxAttempts) {
                $attempt++
                Write-RunLog -Level INFO -EventName 'download_start' -Data @{ target = $label; url = $url; attempt = $attempt } -NoConsole

                $run = Invoke-YtDlpProcess -ExePath $exePath -Arguments ($baseArguments + $url)
                $outcome = Get-RunOutcome -ExitCode $run.ExitCode -Output $run.Output.ToArray()
                foreach ($line in $run.Output) { $allOutput.Add($line) }

                Write-RunLog -Level $(if ($outcome.Status -eq 'Failed') { 'ERROR' } else { 'INFO' }) -EventName 'download_end' -Data @{
                    target      = $label
                    attempt     = $attempt
                    outcome     = $outcome.Status.ToLowerInvariant()
                    exit_code   = $run.ExitCode
                    duration_ms = $run.DurationMs
                    reason      = $outcome.Reason
                } -NoConsole

                if (-not $outcome.Retry -or $attempt -ge $MaxAttempts) { break }

                $backoff = 5 * $attempt
                Write-RunLog -Level WARN -EventName 'download_retry' -Data @{ target = $label; attempt = $attempt } -Message ('Attempt {0} failed. Retrying in {1}s...' -f $attempt, $backoff)
                Start-Sleep -Seconds $backoff
            }

            $results.Add([pscustomobject]@{
                    Target   = $label
                    Status   = $outcome.Status
                    Attempts = $attempt
                    Seconds  = [Math]::Round($run.DurationMs / 1000, 1)
                    Reason   = $outcome.Reason
                })

            switch ($outcome.Status) {
                'Success' { Write-Host '  -> done' -ForegroundColor Green }
                'Skipped' { Write-Host '  -> already in the download archive, nothing to do' -ForegroundColor DarkGreen }
                'Cancelled' { Write-Host '  -> cancelled' -ForegroundColor Yellow }
                default { Write-Host ('  -> failed: {0}' -f $outcome.Reason) -ForegroundColor Red }
            }

            if ($outcome.Status -eq 'Cancelled') {
                Write-RunLog -Level WARN -EventName 'run_cancelled' -Message 'Stopping, the remaining targets were skipped.'
                break
            }
        }
    } finally {
        if ($holdsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        try { $Host.UI.RawUI.WindowTitle = 'PowerShell' } catch { Write-Debug 'Window title left unchanged.' }
    }

    # --- summary ----------------------------------------------------------
    Write-Section 'Summary'
    $results | Format-Table -AutoSize -Property Target, Status, Attempts, Seconds, Reason | Out-String | Write-Host

    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    $cancelled = @($results | Where-Object { $_.Status -eq 'Cancelled' })

    if ($failed.Count -gt 0) {
        foreach ($hint in (Get-FailureHint -Output $allOutput.ToArray())) {
            Write-Host ('  hint: {0}' -f $hint) -ForegroundColor Yellow
        }
        if ($script:LogFile) { Write-Host ('  log : {0}' -f $script:LogFile) -ForegroundColor DarkGray }
    }

    Write-RunLog -Level INFO -EventName 'run_end' -Data @{
        total     = $results.Count
        success   = @($results | Where-Object { $_.Status -eq 'Success' }).Count
        skipped   = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count
        failed    = $failed.Count
        cancelled = $cancelled.Count
        output    = $resolvedOutput
    } -NoConsole

    Write-Host ('  files are in: {0}' -f $resolvedOutput) -ForegroundColor Cyan

    if ($failed.Count -gt 0) { return 1 }
    if ($cancelled.Count -gt 0) { return 130 }
    return 0
}

# ---------------------------------------------------------------------------
# Entry point (skipped when the file is dot-sourced, for example by the tests)
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $exitCode = Invoke-Main
    } catch {
        Write-Host ''
        Write-Host ('  FATAL: {0}' -f $_.Exception.Message) -ForegroundColor Red
        if ($_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
        Write-RunLog -Level ERROR -EventName 'run_fatal' -Data @{ message = $_.Exception.Message } -NoConsole
        $exitCode = 1
    }

    if ($Interactive -or $KeepOpen) {
        Write-Host ''
        try { $null = Read-Host '  Press Enter to close' } catch { Write-Debug 'Non-interactive host, not pausing.' }
    }
    exit $exitCode
}
