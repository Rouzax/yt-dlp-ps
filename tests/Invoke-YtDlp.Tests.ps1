#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    # Dot-sourcing loads the functions without running the downloader.
    . (Join-Path $PSScriptRoot '..\Invoke-YtDlp.ps1')

    function Get-TestOption {
        param([hashtable] $Override = @{})

        $options = @{
            NoForceIPv4         = $false
            AudioOnly           = $false
            AudioFormat         = 'm4a'
            MergeFormat         = 'mkv'
            NoArchive           = $false
            ArchivePath         = 'C:\TEMP\yt-dlp_downloaded.txt'
            OutputPath          = 'C:\TEMP\_YT-DLP'
            SleepInterval       = 3
            MaxSleepInterval    = 10
            LimitRate           = '10M'
            Retries             = 10
            FragmentRetries     = 10
            ConcurrentFragments = 2
            NoSponsorBlock      = $false
            Subtitles           = $false
            SubtitleLanguages   = 'en.*'
            TrimFilenames       = 0
            OutputTemplate      = ''
            CookiesFromBrowser  = ''
            CookieFile          = ''
            FfmpegLocation      = ''
            ExtraArgs           = @()
            Verbose             = $false
        }
        foreach ($key in $Override.Keys) { $options[$key] = $Override[$key] }
        return $options
    }

    function Test-ArgumentPair {
        param([string[]] $Arguments, [string] $Name, [string] $Value)

        for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
            if ($Arguments[$i] -eq $Name -and $Arguments[$i + 1] -eq $Value) { return $true }
        }
        return $false
    }
}

Describe 'ConvertTo-YtDlpTarget' {
    It 'passes a full https URL through unchanged' {
        ConvertTo-YtDlpTarget -InputValue 'https://www.youtube.com/watch?v=alpAGBQBIFs' |
            Should -Be 'https://www.youtube.com/watch?v=alpAGBQBIFs'
    }

    It 'expands a bare 11 character video ID' {
        ConvertTo-YtDlpTarget -InputValue 'M-CdImxl9XI' |
            Should -Be 'https://www.youtube.com/watch?v=M-CdImxl9XI'
    }

    It 'expands a video ID that starts with a dash' {
        ConvertTo-YtDlpTarget -InputValue '-CdImxl9XI0' |
            Should -Be 'https://www.youtube.com/watch?v=-CdImxl9XI0'
    }

    It 'expands a video ID that starts with an underscore' {
        ConvertTo-YtDlpTarget -InputValue '_CdImxl9XI0' |
            Should -Be 'https://www.youtube.com/watch?v=_CdImxl9XI0'
    }

    It 'trims whitespace and pasted quotes' {
        ConvertTo-YtDlpTarget -InputValue '  "M-CdImxl9XI"  ' |
            Should -Be 'https://www.youtube.com/watch?v=M-CdImxl9XI'
    }

    It 'strips the angle brackets some chat clients add' {
        ConvertTo-YtDlpTarget -InputValue '<https://youtu.be/M-CdImxl9XI>' |
            Should -Be 'https://youtu.be/M-CdImxl9XI'
    }

    It 'adds a scheme to a scheme-less URL' {
        ConvertTo-YtDlpTarget -InputValue 'www.youtube.com/watch?v=M-CdImxl9XI' |
            Should -Be 'https://www.youtube.com/watch?v=M-CdImxl9XI'
    }

    It 'adds a scheme to a short youtu.be link' {
        ConvertTo-YtDlpTarget -InputValue 'youtu.be/M-CdImxl9XI' |
            Should -Be 'https://youtu.be/M-CdImxl9XI'
    }

    It 'expands a playlist ID' {
        ConvertTo-YtDlpTarget -InputValue 'PLbpi6ZahtOH6Blw3RGYpWkSByi_T7Rygb' |
            Should -Be 'https://www.youtube.com/playlist?list=PLbpi6ZahtOH6Blw3RGYpWkSByi_T7Rygb'
    }

    It 'expands a channel ID' {
        ConvertTo-YtDlpTarget -InputValue 'UCHnyfMqiRRG1u-2MsSQLbXA' |
            Should -Be 'https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA'
    }

    It 'expands an @handle' {
        ConvertTo-YtDlpTarget -InputValue '@veritasium' |
            Should -Be 'https://www.youtube.com/@veritasium'
    }

    It 'prefers the video reading for an 11 character string that starts with PL' {
        ConvertTo-YtDlpTarget -InputValue 'PLabcdefghi' |
            Should -Be 'https://www.youtube.com/watch?v=PLabcdefghi'
    }

    It 'keeps a non-YouTube site URL' {
        ConvertTo-YtDlpTarget -InputValue 'https://vimeo.com/123456789' |
            Should -Be 'https://vimeo.com/123456789'
    }

    It 'rejects an empty value' {
        { ConvertTo-YtDlpTarget -InputValue '   ' } | Should -Throw '*Empty target*'
    }

    It 'rejects an unsupported scheme' {
        { ConvertTo-YtDlpTarget -InputValue 'ftp://example.com/file.mp4' } | Should -Throw '*Unsupported URL scheme*'
    }

    It 'rejects a value that is not a URL or an ID' {
        { ConvertTo-YtDlpTarget -InputValue 'not a link' } | Should -Throw '*Cannot read*'
    }

    It 'rejects a string of the wrong length for a video ID' {
        { ConvertTo-YtDlpTarget -InputValue 'abcdefgh' } | Should -Throw '*Cannot read*'
    }
}

Describe 'Get-TargetLabel' {
    It 'uses the video ID from a watch URL' {
        Get-TargetLabel -Url 'https://www.youtube.com/watch?v=M-CdImxl9XI' | Should -Be 'M-CdImxl9XI'
    }

    It 'uses the video ID from a short URL' {
        Get-TargetLabel -Url 'https://youtu.be/M-CdImxl9XI' | Should -Be 'M-CdImxl9XI'
    }

    It 'marks a playlist' {
        Get-TargetLabel -Url 'https://www.youtube.com/playlist?list=PL123456789012' | Should -Be 'list:PL123456789012'
    }

    It 'shortens a long unknown URL' {
        $label = Get-TargetLabel -Url ('https://example.com/' + ('x' * 90))
        $label.Length | Should -Be 60
        $label | Should -BeLike '*...'
    }
}

Describe 'Read-TargetFromFile' {
    BeforeAll {
        $script:listFile = Join-Path $TestDrive 'targets.txt'
        @(
            '# a comment line'
            'M-CdImxl9XI'
            ''
            'https://youtu.be/alpAGBQBIFs   # trailing comment'
        ) | Set-Content -LiteralPath $script:listFile
    }

    It 'reads entries and drops comments and blank lines' {
        $items = Read-TargetFromFile -Path $script:listFile
        $items.Count | Should -Be 2
        $items[0] | Should -Be 'M-CdImxl9XI'
        $items[1] | Should -Be 'https://youtu.be/alpAGBQBIFs'
    }

    It 'throws when the file does not exist' {
        { Read-TargetFromFile -Path (Join-Path $TestDrive 'nope.txt') } | Should -Throw '*Input file not found*'
    }
}

Describe 'Get-YtDlpArgumentList' {
    It 'reproduces the original command line options' {
        $arguments = Get-YtDlpArgumentList -Options (Get-TestOption)

        $arguments | Should -Contain '--no-continue'
        $arguments | Should -Contain '--no-overwrites'
        $arguments | Should -Contain '--no-post-overwrites'
        $arguments | Should -Contain '--force-ipv4'
        $arguments | Should -Contain '--windows-filenames'
        $arguments | Should -Contain '--embed-thumbnail'
        $arguments | Should -Contain '--embed-chapters'

        Test-ArgumentPair -Arguments $arguments -Name '--merge-output-format' -Value 'mkv' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--convert-thumbnails' -Value 'png' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--sponsorblock-mark' -Value 'all' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--limit-rate' -Value '10M' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--sleep-interval' -Value '3' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--max-sleep-interval' -Value '10' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--retries' -Value '10' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--fragment-retries' -Value '10' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--concurrent-fragments' -Value '2' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '--download-archive' -Value 'C:\TEMP\yt-dlp_downloaded.txt' | Should -BeTrue
        Test-ArgumentPair -Arguments $arguments -Name '-P' -Value 'C:\TEMP\_YT-DLP' | Should -BeTrue
    }

    It 'omits the archive when -NoArchive is used' {
        $arguments = Get-YtDlpArgumentList -Options (Get-TestOption @{ NoArchive = $true })
        $arguments | Should -Not -Contain '--download-archive'
    }

    It 'omits force-ipv4 when -NoForceIPv4 is used' {
        $arguments = Get-YtDlpArgumentList -Options (Get-TestOption @{ NoForceIPv4 = $true })
        $arguments | Should -Not -Contain '--force-ipv4'
    }

    It 'switches to audio extraction and drops the merge format' {
        $arguments = Get-YtDlpArgumentList -Options (Get-TestOption @{ AudioOnly = $true; AudioFormat = 'mp3' })
        $arguments | Should -Contain '--extract-audio'
        $arguments | Should -Not -Contain '--merge-output-format'
        Test-ArgumentPair -Arguments $arguments -Name '--audio-format' -Value 'mp3' | Should -BeTrue
    }

    It 'adds subtitle options only when asked' {
        $off = Get-YtDlpArgumentList -Options (Get-TestOption)
        $off | Should -Not -Contain '--embed-subs'

        $on = Get-YtDlpArgumentList -Options (Get-TestOption @{ Subtitles = $true; SubtitleLanguages = 'nl.*,en.*' })
        $on | Should -Contain '--embed-subs'
        Test-ArgumentPair -Arguments $on -Name '--sub-langs' -Value 'nl.*,en.*' | Should -BeTrue
    }

    It 'adds cookie options only when asked' {
        $arguments = Get-YtDlpArgumentList -Options (Get-TestOption @{ CookiesFromBrowser = 'edge' })
        Test-ArgumentPair -Arguments $arguments -Name '--cookies-from-browser' -Value 'edge' | Should -BeTrue
    }

    It 'appends passthrough arguments last' {
        $arguments = Get-YtDlpArgumentList -Options (Get-TestOption @{ ExtraArgs = @('-f', 'bv*+ba') })
        $arguments[-2] | Should -Be '-f'
        $arguments[-1] | Should -Be 'bv*+ba'
    }

    It 'keeps every argument as its own array element so spaces survive' {
        $arguments = Get-YtDlpArgumentList -Options (Get-TestOption @{ OutputPath = 'C:\Some Folder\With Spaces' })
        $arguments | Should -Contain 'C:\Some Folder\With Spaces'
    }
}

Describe 'Get-RunOutcome' {
    It 'reports success on exit code 0' {
        $outcome = Get-RunOutcome -ExitCode 0 -Output @('[download] Destination: video.webm', '[Merger] Merging formats')
        $outcome.Status | Should -Be 'Success'
        $outcome.Retry | Should -BeFalse
    }

    It 'reports skipped when everything was already in the archive' {
        $outcome = Get-RunOutcome -ExitCode 0 -Output @('[download] M-CdImxl9XI has already been recorded in the archive')
        $outcome.Status | Should -Be 'Skipped'
    }

    It 'reports cancelled on a Ctrl+C exit code' {
        (Get-RunOutcome -ExitCode 130 -Output @()).Status | Should -Be 'Cancelled'
        (Get-RunOutcome -ExitCode -1073741510 -Output @()).Status | Should -Be 'Cancelled'
    }

    It 'does not retry a bad option' {
        $outcome = Get-RunOutcome -ExitCode 2 -Output @('Usage: yt-dlp [OPTIONS]')
        $outcome.Status | Should -Be 'Failed'
        $outcome.Retry | Should -BeFalse
    }

    It 'does not retry an unavailable video' {
        $outcome = Get-RunOutcome -ExitCode 1 -Output @('ERROR: [youtube] xyz: Video unavailable')
        $outcome.Status | Should -Be 'Failed'
        $outcome.Retry | Should -BeFalse
    }

    It 'also recognises the "This video is unavailable" wording' {
        $outcome = Get-RunOutcome -ExitCode 1 -Output @('ERROR: [youtube] -CdImxl9XI1: This video is unavailable')
        $outcome.Status | Should -Be 'Failed'
        $outcome.Retry | Should -BeFalse
    }

    It 'retries a transient failure and keeps the error text' {
        $outcome = Get-RunOutcome -ExitCode 1 -Output @('ERROR: unable to download video data: HTTP Error 403')
        $outcome.Status | Should -Be 'Failed'
        $outcome.Retry | Should -BeTrue
        $outcome.Reason | Should -BeLike 'ERROR: unable to download*'
    }
}

Describe 'Resolve-FullPath' {
    It 'leaves a rooted path alone' {
        Resolve-FullPath 'C:\TEMP\_YT-DLP' | Should -Be 'C:\TEMP\_YT-DLP'
    }

    It 'normalises a rooted path with dot segments' {
        Resolve-FullPath 'C:\TEMP\.\_YT-DLP\..\_YT-DLP' | Should -Be 'C:\TEMP\_YT-DLP'
    }

    It 'resolves a relative path against the current directory' {
        Push-Location $TestDrive
        try {
            Resolve-FullPath 'sub\file.txt' | Should -Be (Join-Path (Get-Location).ProviderPath 'sub\file.txt')
        } finally {
            Pop-Location
        }
    }
}

Describe 'Resolve-YtDlpExecutable' {
    It 'returns an explicit path that exists' {
        $fake = Join-Path $TestDrive 'yt-dlp.exe'
        Set-Content -LiteralPath $fake -Value 'not really an exe'
        Resolve-YtDlpExecutable -Path $fake | Should -Be ([System.IO.Path]::GetFullPath($fake))
    }

    It 'throws for an explicit path that does not exist' {
        { Resolve-YtDlpExecutable -Path (Join-Path $TestDrive 'missing.exe') } |
            Should -Throw '*not found at -YtDlpPath*'
    }
}

Describe 'Logging' {
    BeforeEach {
        $script:logPath = Join-Path $TestDrive ('log_{0}.log' -f [guid]::NewGuid().ToString('N'))
        Initialize-Log -Path $script:logPath
    }

    It 'creates the log file' {
        Test-Path -LiteralPath $script:logPath | Should -BeTrue
    }

    It 'writes one structured line per event, with the run id and sorted fields' {
        Write-RunLog -Level INFO -EventName 'download_end' -Data @{ target = 'M-CdImxl9XI'; exit_code = 0 } -NoConsole

        $line = @(Get-Content -LiteralPath $script:logPath | Where-Object { $_ -match 'download_end' })[0]
        $line | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z INFO run=[0-9a-f]{8} download_end '
        $line | Should -Match 'exit_code=0 target=M-CdImxl9XI$'
    }

    It 'quotes values that contain spaces and escapes embedded quotes' {
        Write-RunLog -Level ERROR -EventName 'target_rejected' -Data @{ input = 'this "is" junk' } -NoConsole

        $line = @(Get-Content -LiteralPath $script:logPath | Where-Object { $_ -match 'target_rejected' })[0]
        $line | Should -Match "input=`"this 'is' junk`"$"
    }

    It 'keeps logging best effort when the file cannot be written' {
        Initialize-Log -Path (Join-Path $TestDrive 'no\such\folder\..\..\..\..\..\nope\x.log')
        { Write-RunLog -Level INFO -EventName 'still_alive' -NoConsole } | Should -Not -Throw
    }
}

Describe 'Invoke-YtDlpProcess' {
    BeforeAll {
        # A stand-in for yt-dlp: prints yt-dlp shaped output, then exits with a chosen code.
        $script:fakeExe = (Get-Command -Name 'pwsh.exe' -CommandType Application | Select-Object -First 1).Source
        $script:fakeScript = Join-Path $TestDrive 'fake-ytdlp.ps1'
        @(
            'param([int] $Code = 0)'
            "Write-Output '[youtube] Extracting URL: https://example.test/watch?v=abcdefghijk'"
            "Write-Output '[download]  50.0% of   10.00MiB at    1.00MiB/s ETA 00:05'"
            "Write-Output '[download] 100% of   10.00MiB in 00:00:10 at 1.00MiB/s'"
            "[Console]::Error.WriteLine('WARNING: nothing to worry about')"
            'exit $Code'
        ) | Set-Content -LiteralPath $script:fakeScript

        function Invoke-FakeYtDlp {
            param([int] $Code = 0)

            # 6>$null drops the console rendering; the result object still comes back.
            Invoke-YtDlpProcess -ExePath $script:fakeExe -Arguments @(
                '-NoLogo', '-NoProfile', '-File', $script:fakeScript, '-Code', "$Code"
            ) 6>$null
        }
    }

    It 'returns exit code 0 and a duration' {
        $run = Invoke-FakeYtDlp -Code 0
        $run.ExitCode | Should -Be 0
        $run.DurationMs | Should -BeGreaterThan 0
    }

    It 'captures normal output and stderr' {
        $text = (Invoke-FakeYtDlp -Code 0).Output -join "`n"
        $text | Should -Match 'Extracting URL'
        $text | Should -Match 'WARNING: nothing to worry about'
    }

    It 'keeps the finished line but not the intermediate progress lines' {
        $text = (Invoke-FakeYtDlp -Code 0).Output -join "`n"
        $text | Should -Match '100% of'
        $text | Should -Not -Match '50\.0%'
    }

    It 'reports a non-zero exit code instead of throwing' {
        (Invoke-FakeYtDlp -Code 1).ExitCode | Should -Be 1
    }

    It 'feeds straight into the outcome classifier' {
        $run = Invoke-FakeYtDlp -Code 1
        $outcome = Get-RunOutcome -ExitCode $run.ExitCode -Output $run.Output.ToArray()
        $outcome.Status | Should -Be 'Failed'
        $outcome.Retry | Should -BeTrue
    }
}

Describe 'Get-FailureHint' {
    It 'suggests cookies for a bot check' {
        Get-FailureHint -Output @('ERROR: Sign in to confirm you are not a bot') |
            Should -Match 'CookiesFromBrowser'
    }

    It 'suggests slowing down on HTTP 429' {
        Get-FailureHint -Output @('ERROR: HTTP Error 429: Too Many Requests') |
            Should -Match 'Rate limited'
    }

    It 'explains an unavailable video' {
        Get-FailureHint -Output @('ERROR: [youtube] xyz: This video is unavailable') |
            Should -Match 'Retrying will not help'
    }

    It 'returns nothing for clean output' {
        Get-FailureHint -Output @('[download] 100% of 12.00MiB') | Should -BeNullOrEmpty
    }

    It 'returns nothing for empty output' {
        Get-FailureHint -Output @() | Should -BeNullOrEmpty
    }
}
