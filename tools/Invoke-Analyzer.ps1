#Requires -Version 7.2

<#
.SYNOPSIS
    Runs PSScriptAnalyzer over the given files, or over the whole repository.

.DESCRIPTION
    Used by the pre-commit hook, which passes the staged file names. Run it by hand
    with no arguments to check everything.

    Exits 1 when the analyzer reports anything at the severity levels configured in
    PSScriptAnalyzerSettings.psd1 (currently Error and Warning).

.PARAMETER Path
    Files to analyse. Defaults to every .ps1 / .psm1 / .psd1 in the repository.

.EXAMPLE
    .\tools\Invoke-Analyzer.ps1

.NOTES
    Author: Rouzax
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pinned exactly: the commit hook and CI must run the same analyzer.
$requiredVersion = '1.25.0'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

try {
    Import-Module PSScriptAnalyzer -RequiredVersion $requiredVersion -ErrorAction Stop
} catch {
    Write-Host "PSScriptAnalyzer $requiredVersion is required." -ForegroundColor Red
    Write-Host "  Install-PSResource PSScriptAnalyzer -Version $requiredVersion" -ForegroundColor Yellow
    exit 1
}

if ($Path) {
    $files = @($Path |
            Where-Object { $_ -match '\.(ps1|psm1|psd1)$' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
} else {
    $files = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch '\\\.git\\' } |
            Select-Object -ExpandProperty FullName)
}

if ($files.Count -eq 0) {
    Write-Host 'PSScriptAnalyzer: no PowerShell files to check.' -ForegroundColor DarkGray
    exit 0
}

# -Path takes a single path, so analyse one file at a time.
$findings = @(foreach ($file in $files) {
        Invoke-ScriptAnalyzer -Path $file -Settings $settingsPath
    })

if ($findings.Count -eq 0) {
    Write-Host ('PSScriptAnalyzer: clean ({0} file(s)).' -f $files.Count) -ForegroundColor Green
    exit 0
}

$findings |
    Sort-Object Severity, ScriptName, Line |
    Format-Table -AutoSize -Property Severity, RuleName, ScriptName, Line, Message |
    Out-String -Width 200 |
    Write-Host

Write-Host ('PSScriptAnalyzer: {0} finding(s).' -f $findings.Count) -ForegroundColor Red
exit 1
