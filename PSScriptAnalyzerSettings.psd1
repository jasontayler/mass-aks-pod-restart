@{
    # PSScriptAnalyzer settings for mass-aks-pod-restart
    # Run: Invoke-ScriptAnalyzer -Path .\runbooks\ -Settings .\PSScriptAnalyzerSettings.psd1
    # Docs: https://github.com/PowerShell/PSScriptAnalyzer

    Severity = @('Error', 'Warning')

    # -------------------------------------------------------------------------
    # Rules to INCLUDE (explicitly enforce)
    # -------------------------------------------------------------------------
    IncludeRules = @(
        # Security
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        'PSAvoidUsingWriteHost',             # warn on Write-Host — intentionally used here, see exclusion below
        'PSAvoidUsingInvokeExpression',

        # Quality
        'PSUseApprovedVerbs',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseSingularNouns',
        'PSUseOutputTypeCorrectly',
        'PSAvoidGlobalVars',
        'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingPositionalParameters',
        'PSAvoidTrailingWhitespace',
        'PSMisleadingBacktick',
        'PSUseConsistentIndentation',
        'PSUseConsistentWhitespace',

        # Compatibility
        'PSAvoidUsingComputerNameHardcoded',

        # Best practice
        'PSAvoidShouldContinueWithoutForce',
        'PSReservedCmdletChar',
        'PSReservedParams'
    )

    # -------------------------------------------------------------------------
    # Rules to EXCLUDE (conflict with runbook patterns in this repo)
    # -------------------------------------------------------------------------
    ExcludeRules = @(
        # Write-Host is the correct pattern for Azure Automation runbook output.
        # Runbooks do not return objects to a pipeline — Write-Host is intentional.
        'PSAvoidUsingWriteHost',

        # Azure Automation runbooks are not cmdlets and do not follow ShouldProcess.
        # Runbooks expose their own -WhatIf as a plain switch, not ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions',

        # Worker-RestartSingleCluster.ps1 uses a nested function (Finish) that
        # closes over script-scope variables. This pattern is intentional.
        'PSAvoidUsingGlobalVars',

        # ConcurrentBag and Generic.List variable names like $_sf, $_kvName use
        # the underscore prefix convention for script-scope helpers. Allowed.
        'PSUseDeclaredVarsMoreThanAssignments'
    )

    # -------------------------------------------------------------------------
    # Per-rule configuration
    # -------------------------------------------------------------------------
    Rules = @{
        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind                = 'space'
        }

        PSUseConsistentWhitespace = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            CheckOpenBrace                  = $true
            CheckOpenParen                  = $true
            CheckOperator                   = $true
            CheckPipe                       = $true
            CheckPipeForRedundantWhitespace = $false
            CheckSeparator                  = $true
            CheckParameter                  = $false
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }
    }
}
