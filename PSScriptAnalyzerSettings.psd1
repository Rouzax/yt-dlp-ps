@{
    # Gate commits and CI on Error severity; Warnings are advisory here.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # This toolkit is an interactive console front end: its whole purpose is to paint a
        # coloured progress line and a summary table on the host. Write-Output is not a
        # substitute (it would pollute the pipeline and break the in-place progress line),
        # so PSAvoidUsingWriteHost is excluded project wide by design.
        'PSAvoidUsingWriteHost'
    )

    Rules        = @{
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }
        PSPlaceOpenBrace           = @{
            Enable     = $true
            OnSameLine = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            # One-line blocks such as `catch { }` guards stay on one line on purpose.
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
            # `} catch {`, `} else {` and `} finally {` are the house style here.
            NewLineAfter       = $false
        }
        PSUseCorrectCasing         = @{
            Enable = $true
        }
    }
}
