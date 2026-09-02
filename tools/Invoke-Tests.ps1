#Requires -Version 7.2

<#
.SYNOPSIS
    Runs the Pester suite and enforces the code coverage floor.

.DESCRIPTION
    Used by the pre-push hook. Exits 1 when a test fails or when statement coverage
    of Invoke-YtDlp.ps1 drops below -CoverageFloor.

    The floor only moves up: when a change raises coverage, raise the default here in
    the same change so the gain is locked in.

.PARAMETER CoverageFloor
    Minimum statement coverage percentage. Set to 0 to report without gating.

.PARAMETER NoCoverage
    Skip coverage measurement, run the tests only (faster local loop).

.EXAMPLE
    .\tools\Invoke-Tests.ps1

.NOTES
    Author: Rouzax
#>

[CmdletBinding()]
param(
    # Current floor, measured 2026-09-02: 40.87% of 624 commands. Covered: input
    # parsing, argument building, the process runner, outcome classification, hints
    # and logging. Not covered: Invoke-Main and the interactive prompt.
    [ValidateRange(0, 100)]
    [double] $CoverageFloor = 40,

    [switch] $NoCoverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$minimumPesterVersion = '5.9.1'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent

try {
    Import-Module Pester -MinimumVersion $minimumPesterVersion -ErrorAction Stop
} catch {
    Write-Host "Pester $minimumPesterVersion or newer is required." -ForegroundColor Red
    Write-Host "  Install-PSResource Pester -Version $minimumPesterVersion" -ForegroundColor Yellow
    exit 1
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $repoRoot 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'

if (-not $NoCoverage) {
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = Join-Path $repoRoot 'Invoke-YtDlp.ps1'
    $configuration.CodeCoverage.OutputPath = Join-Path $repoRoot '.coverage.xml'
    $configuration.CodeCoverage.CoveragePercentTarget = $CoverageFloor
}

$result = Invoke-Pester -Configuration $configuration

$exitCode = 0

if ($result.FailedCount -gt 0) {
    Write-Host ('Pester: {0} test(s) failed.' -f $result.FailedCount) -ForegroundColor Red
    $exitCode = 1
} else {
    Write-Host ('Pester: {0} test(s) passed.' -f $result.PassedCount) -ForegroundColor Green
}

if (-not $NoCoverage -and $result.CodeCoverage) {
    $analysed = $result.CodeCoverage.CommandsAnalyzedCount
    $executed = $result.CodeCoverage.CommandsExecutedCount
    $percent = if ($analysed -gt 0) { [Math]::Round(100 * $executed / $analysed, 2) } else { 0 }

    if ($percent -lt $CoverageFloor) {
        Write-Host ('Coverage: {0}% of {1} commands, below the {2}% floor.' -f $percent, $analysed, $CoverageFloor) -ForegroundColor Red
        Write-Host '  Add tests, or get sign-off before changing the floor.' -ForegroundColor Yellow
        $exitCode = 1
    } else {
        Write-Host ('Coverage: {0}% of {1} commands (floor {2}%).' -f $percent, $analysed, $CoverageFloor) -ForegroundColor Green
        if ($percent -gt $CoverageFloor + 2) {
            Write-Host ('  Coverage is above the floor. Raise -CoverageFloor to {0} to lock it in.' -f [Math]::Floor($percent)) -ForegroundColor Cyan
        }
    }
}

exit $exitCode
