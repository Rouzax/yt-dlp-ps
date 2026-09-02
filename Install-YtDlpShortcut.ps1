#Requires -Version 7.2

<#
.SYNOPSIS
    Creates the desktop shortcut that runs Invoke-YtDlp.ps1 and asks for a URL or ID.

.DESCRIPTION
    Writes a .lnk that starts pwsh.exe with a fixed output folder and download archive,
    in interactive mode, so a double click only asks "paste a link".

    An existing shortcut of the same name is only overwritten when it already points at
    this script. Anything else is left alone unless you pass -Force, so an unrelated
    shortcut on your desktop cannot be clobbered by accident.

    Re-run this script whenever you want to change the folder the shortcut downloads to.

.PARAMETER ShortcutName
    File name of the shortcut, without .lnk.

.PARAMETER OutputPath
    Folder the shortcut downloads into.

.PARAMETER ArchivePath
    Download archive the shortcut uses.

.PARAMETER ScriptPath
    Path to Invoke-YtDlp.ps1. Defaults to the copy next to this file.

.PARAMETER Location
    Desktop (default), StartMenu, or Both.

.PARAMETER ExtraScriptArguments
    Extra arguments appended to the script call, for example -Subtitles or -AudioOnly.

.PARAMETER Force
    Overwrite an existing shortcut of the same name even when it points somewhere else.

.EXAMPLE
    .\Install-YtDlpShortcut.ps1

.EXAMPLE
    .\Install-YtDlpShortcut.ps1 -ShortcutName 'YT-DLP - Music' -OutputPath 'C:\TEMP\_YT-MUSIC' -ExtraScriptArguments '-AudioOnly'

.NOTES
    Author: Rouzax
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', '',
    Justification = 'Script parameters are read from script scope inside Install-Shortcut, which the rule cannot follow.')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $ShortcutName = 'YT-DLP - Download',

    [string] $OutputPath = 'C:\TEMP\_YT-DLP',

    [string] $ArchivePath = 'C:\TEMP\yt-dlp_downloaded.txt',

    [string] $ScriptPath,

    [ValidateSet('Desktop', 'StartMenu', 'Both')]
    [string] $Location = 'Desktop',

    [string[]] $ExtraScriptArguments,

    [string] $IconPath,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ShortcutOwnedByScript {
    <#
    .SYNOPSIS
        True when an existing shortcut's arguments already run the given .ps1 file.

    .DESCRIPTION
        The guard against overwriting somebody else's shortcut: WScript.Shell opens an
        existing .lnk in place, so Save() would silently replace whatever was there.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $ExistingArguments,

        [Parameter(Mandatory)]
        [string] $ScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($ExistingArguments)) { return $false }
    if ($ExistingArguments -notmatch '(?i)-File\s+"?([^"]+?\.ps1)"?(\s|$)') { return $false }

    try {
        $existing = [System.IO.Path]::GetFullPath($Matches[1].Trim())
        $wanted = [System.IO.Path]::GetFullPath($ScriptPath)
        return $existing -ieq $wanted
    } catch {
        return $false
    }
}

function Get-DefaultIcon {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Fallback)

    $ytDlp = Get-Command -Name 'yt-dlp.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($ytDlp) { return "$($ytDlp.Source),0" }
    return "$Fallback,0"
}

function Get-ShortcutFolder {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $Location)

    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

    switch ($Location) {
        'Desktop' { return @($desktop) }
        'StartMenu' { return @($startMenu) }
        default { return @($desktop, $startMenu) }
    }
}

function Install-Shortcut {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $scriptFullPath = if ($ScriptPath) { $ScriptPath } else { Join-Path $PSScriptRoot 'Invoke-YtDlp.ps1' }
    $scriptFullPath = [System.IO.Path]::GetFullPath($scriptFullPath)
    if (-not (Test-Path -LiteralPath $scriptFullPath -PathType Leaf)) {
        throw "Invoke-YtDlp.ps1 not found at: $scriptFullPath"
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $pwshCommand) {
        throw 'pwsh.exe was not found on PATH. This toolkit is PowerShell 7 only: winget install Microsoft.PowerShell'
    }
    $pwshPath = $pwshCommand.Source

    $icon = if ($IconPath) { $IconPath } else { Get-DefaultIcon -Fallback $pwshPath }

    $arguments = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', ('"{0}"' -f $scriptFullPath)
        '-Interactive'
        '-OutputPath', ('"{0}"' -f $OutputPath)
        '-ArchivePath', ('"{0}"' -f $ArchivePath)
    )
    if ($ExtraScriptArguments) { $arguments += $ExtraScriptArguments }
    $argumentLine = $arguments -join ' '

    $created = 0
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($folder in (Get-ShortcutFolder -Location $Location)) {
            if (-not (Test-Path -LiteralPath $folder)) {
                $null = New-Item -ItemType Directory -Path $folder -Force
            }
            $linkPath = Join-Path $folder ('{0}.lnk' -f $ShortcutName)

            # Never overwrite a shortcut that belongs to something else.
            if (Test-Path -LiteralPath $linkPath) {
                $existing = $shell.CreateShortcut($linkPath)
                $ownedByUs = Test-ShortcutOwnedByScript -ExistingArguments $existing.Arguments -ScriptPath $scriptFullPath
                $existingTarget = '{0} {1}' -f $existing.TargetPath, $existing.Arguments
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($existing)

                if (-not $ownedByUs -and -not $Force) {
                    Write-Host ''
                    Write-Host ('  A different shortcut already exists: {0}' -f $linkPath) -ForegroundColor Yellow
                    Write-Host ('  It runs: {0}' -f $existingTarget.Trim()) -ForegroundColor DarkGray
                    Write-Host '  Nothing was changed. Choose another -ShortcutName, or pass -Force to replace it.' -ForegroundColor Yellow
                    continue
                }
                Write-Host ('  Updating the existing shortcut: {0}' -f $linkPath) -ForegroundColor DarkGray
            }

            if (-not $PSCmdlet.ShouldProcess($linkPath, 'Create shortcut')) { continue }

            $shortcut = $shell.CreateShortcut($linkPath)
            $shortcut.TargetPath = $pwshPath
            $shortcut.Arguments = $argumentLine
            $shortcut.WorkingDirectory = Split-Path -Path $scriptFullPath -Parent
            $shortcut.Description = "Download YouTube video to $OutputPath"
            $shortcut.IconLocation = $icon
            $shortcut.WindowStyle = 1
            $shortcut.Save()
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)

            if (-not (Test-Path -LiteralPath $linkPath)) {
                throw "The shortcut was not created: $linkPath"
            }

            $created++
            Write-Host ''
            Write-Host ('  Shortcut     : {0}' -f $linkPath) -ForegroundColor Green
            Write-Host ('  Runs         : {0} {1}' -f $pwshPath, $argumentLine) -ForegroundColor DarkGray
            Write-Host ('  Downloads to : {0}' -f $OutputPath) -ForegroundColor DarkGray
            Write-Host ('  Archive      : {0}' -f $ArchivePath) -ForegroundColor DarkGray
        }
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }

    if ($created -gt 0) {
        Write-Host ''
        Write-Host '  Double click it, paste a URL or an ID, press Enter twice.' -ForegroundColor Cyan
    }
    Write-Host ''
}

# Entry point (skipped when the file is dot-sourced, for example by the tests).
if ($MyInvocation.InvocationName -ne '.') {
    Install-Shortcut
}
