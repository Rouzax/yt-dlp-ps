#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    # Dot-sourcing loads the functions without creating any shortcut.
    . (Join-Path $PSScriptRoot '..\Install-YtDlpShortcut.ps1')

    $script:ourScript = 'C:\GitHub\yt-dlp-ps\Invoke-YtDlp.ps1'
}

Describe 'Test-ShortcutOwnedByScript' {
    It 'recognises a shortcut that already runs our script' {
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\GitHub\yt-dlp-ps\Invoke-YtDlp.ps1" -Interactive -OutputPath "C:\TEMP\_YT-DLP"'
        Test-ShortcutOwnedByScript -ExistingArguments $arguments -ScriptPath $script:ourScript | Should -BeTrue
    }

    It 'ignores path casing and dot segments' {
        $arguments = '-File "C:\GitHub\YT-DLP-PS\.\Invoke-YtDlp.ps1" -Interactive'
        Test-ShortcutOwnedByScript -ExistingArguments $arguments -ScriptPath $script:ourScript | Should -BeTrue
    }

    It 'handles an unquoted script path' {
        $arguments = '-NoLogo -File C:\GitHub\yt-dlp-ps\Invoke-YtDlp.ps1 -Interactive'
        Test-ShortcutOwnedByScript -ExistingArguments $arguments -ScriptPath $script:ourScript | Should -BeTrue
    }

    It 'refuses a shortcut that runs a different script' {
        # The case this guard exists for: an unrelated tool already owns that name.
        $arguments = '-NoExit -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\other-app\other-app.ps1" -Status'
        Test-ShortcutOwnedByScript -ExistingArguments $arguments -ScriptPath $script:ourScript | Should -BeFalse
    }

    It 'refuses a shortcut that runs a different script from the same folder' {
        $arguments = '-File "C:\GitHub\yt-dlp-ps\Something-Else.ps1" -Interactive'
        Test-ShortcutOwnedByScript -ExistingArguments $arguments -ScriptPath $script:ourScript | Should -BeFalse
    }

    It 'refuses a shortcut with no -File argument' {
        Test-ShortcutOwnedByScript -ExistingArguments '--profile-directory="Default" https://example.test' -ScriptPath $script:ourScript |
            Should -BeFalse
    }

    It 'refuses empty arguments' {
        Test-ShortcutOwnedByScript -ExistingArguments '' -ScriptPath $script:ourScript | Should -BeFalse
        Test-ShortcutOwnedByScript -ExistingArguments $null -ScriptPath $script:ourScript | Should -BeFalse
    }
}

Describe 'Get-ShortcutFolder' {
    It 'returns the desktop by default' {
        Get-ShortcutFolder -Location 'Desktop' | Should -Be ([Environment]::GetFolderPath('Desktop'))
    }

    It 'returns the per-user Start menu programs folder' {
        Get-ShortcutFolder -Location 'StartMenu' |
            Should -Be (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    }

    It 'returns both folders for Both' {
        (Get-ShortcutFolder -Location 'Both').Count | Should -Be 2
    }
}
