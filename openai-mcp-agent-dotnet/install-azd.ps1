#!/usr/bin/env pwsh
<#
.SYNOPSIS
Download and install azd on the local machine.

.DESCRIPTION
Downloads and installs azd on the local machine. Includes ability to configure
download and install locations.

.PARAMETER BaseUrl
Specifies the base URL to use when downloading. Default is
https://azuresdkartifacts.z5.web.core.windows.net/azd/standalone/release

.PARAMETER Version
Specifies the version to use. Default is `latest`. Valid values include a
SemVer version number (e.g. 1.0.0 or 1.1.0-beta.1), `latest`, `daily`

.PARAMETER DryRun
Print the download URL and quit. Does not download or install.

.PARAMETER InstallFolder
Location to install azd.

.PARAMETER SymlinkFolder
(Mac/Linux only) Folder to symlink 

.PARAMETER DownloadTimeoutSeconds
Download timeout in seconds. Default is 120 (2 minutes).

.PARAMETER SkipVerify
Skips verification of the downloaded file.

.PARAMETER InstallShScriptUrl
(Mac/Linux only) URL to the install-azd.sh script. Default is https://aka.ms/install-azd.sh

.EXAMPLE
powershell -ex AllSigned -c "Invoke-RestMethod 'https://aka.ms/install-azd.ps1' | Invoke-Expression"

Install the azd CLI from a Windows shell

The use of `-ex AllSigned` is intended to handle the scenario where a machine's
default execution policy is restricted such that modules used by
`install-azd.ps1` cannot be loaded. Because this syntax is piping output from
`Invoke-RestMethod` to `Invoke-Expression` there is no direct valication of the
`install-azd.ps1` script's signature. Validation of the script can be
accomplished by downloading the script to a file and executing the script file.

.EXAMPLE
Invoke-RestMethod 'https://aka.ms/install-azd.ps1' -OutFile 'install-azd.ps1'
PS > ./install-azd.ps1

Download the installer and execute from PowerShell

.EXAMPLE
Invoke-RestMethod 'https://aka.ms/install-azd.ps1' -OutFile 'install-azd.ps1'
PS > ./install-azd.ps1 -Version daily

Download the installer and install the "daily" build
#>

param(
    [string] $BaseUrl = "https://azuresdkartifacts.z5.web.core.windows.net/azd/standalone/release",
    [string] $Version = "stable",
    [switch] $DryRun,
    [string] $InstallFolder,
    [string] $SymlinkFolder,
    [switch] $SkipVerify,
    [int] $DownloadTimeoutSeconds = 120,
    [switch] $NoTelemetry,
    [string] $InstallShScriptUrl = "https://aka.ms/install-azd.sh"
)

function isLinuxOrMac {
    return $IsLinux -or $IsMacOS
}

# Does some very basic parsing of /etc/os-release to output the value present in
# the file. Since only lines that start with '#' are to be treated as comments
# according to `man os-release` there is no additional parsing of comments
# Options like:
# bash -c "set -o allexport; source /etc/os-release;set +o allexport; echo $VERSION_ID"
# were considered but it's possible that bash is not installed on the system and
# these commands would not be available.
function getOsReleaseValue($key) {
    $value = $null
    foreach ($line in Get-Content '/etc/os-release') {
        if ($line -like "$key=*") {
            # 'ID="value" -> @('ID', '"value"')
            $splitLine = $line.Split('=', 2)

            # Remove surrounding whitespaces and quotes
            # ` "value" ` -> `value`
            # `'value'` -> `value`
            $value = $splitLine[1].Trim().Trim(@("`"", "'"))
        }
    }
    return $value
}

function getOs {
    $os = [Environment]::OSVersion.Platform.ToString()
    try {
        if (isLinuxOrMac) {
            if ($IsLinux) {
                $os = getOsReleaseValue 'ID'
            } elseif ($IsMacOs) {
                $os = sw_vers -productName
            }
        }
    } catch {
        Write-Error "Error getting OS name $_"
        $os = "error"
    }
    return $os
}

function getOsVersion {
    $version = [Environment]::OSVersion.Version.ToString()
    try {
        if (isLinuxOrMac) {
            if ($IsLinux) {
                $version = getOsReleaseValue 'VERSION_ID'
            } elseif ($IsMacOS) {
                $version = sw_vers -productVersion
            }
        }
    } catch {
        Write-Error "Error getting OS version $_"
        $version = "error"
    }
    return $version
}

function isWsl {
    $isWsl = $false
    if ($IsLinux) {
        $kernelRelease = uname --kernel-release
        if ($kernelRelease -like '*wsl*') {
            $isWsl = $true
        }
    }
    return $isWsl
}

function getTerminal {
    return (Get-Process -Id $PID).ProcessName
}

function getExecutionEnvironment {
    $executionEnvironment = 'Desktop'
    if ($env:GITHUB_ACTIONS) {
        $executionEnvironment = 'GitHub Actions'
    } elseif ($env:SYSTEM_TEAMPROJECTID) {
        $executionEnvironment = 'Azure DevOps'
    }
    return $executionEnvironment
}

function promptForTelemetry {
    # UserInteractive may return $false if the session is not interactive
    # but this does not work in 100% of cases. For example, running:
    # "powershell -NonInteractive -c '[Environment]::UserInteractive'"
    # results in output of "True" even though the shell is not interactive.
    if (![Environment]::UserInteractive) {
        return $false
    }

    Write-Host "Answering 'yes' below will send data to Microsoft. To learn more about data collection see:"
    Write-Host "https://go.microsoft.com/fwlink/?LinkId=521839"
    Write-Host ""
    Write-Host "You can also file an issue at https://github.com/Azure/azure-dev/issues/new?assignees=&labels=&template=issue_report.md&title=%5BIssue%5D"

    try {
        $yes = New-Object System.Management.Automation.Host.ChoiceDescription `
            "&Yes", `
            "Sends failure report to Microsoft"
        $no = New-Object System.Management.Automation.Host.ChoiceDescription `
            "&No", `
            "Exits the script without sending a failure report to Microsoft (Default)"
        $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
        $decision = $Host.UI.PromptForChoice( `
            'Confirm issue report', `
            'Do you want to send diagnostic data about the failure to Microsoft?', `
            $options, `
            1 `                     # Default is 'No'
        )

        # Return $true if user consents
        return $decision -eq 0
    } catch {
        # Failure to prompt generally indicates that the environment is not
        # interactive and the default resposne can be assumed.
        return $false
    }
}

function reportTelemetryIfEnabled($eventName, $reason='', $additionalProperties = @{}) {
    if ($NoTelemetry -or $env:AZURE_DEV_COLLECT_TELEMETRY -eq 'no') {
        Write-Verbose "Telemetry disabled. No telemetry reported." -Verbose:$Verbose
        return
    }

    $IKEY = 'a9e6fa10-a9ac-4525-8388-22d39336ecc2'

    $telemetryObject = @{
        iKey = $IKEY;
        name = "Microsoft.ApplicationInsights.$($IKEY.Replace('-', '')).Event";
        time = (Get-Date).ToUniversalTime().ToString('o');
        data = @{
            baseType = 'EventData';
            baseData = @{
                ver = 2;
                name = $eventName;
                properties = @{
                    installVersion = $Version;
                    reason = $reason;
                    os = getOs;
                    osVersion = getOsVersion;
                    isWsl = isWsl;
                    terminal = getTerminal;
                    executionEnvironment = getExecutionEnvironment;
                };
            }
        }
    }

    # Add entries from $additionalProperties. These may overwrite existing
    # entries in the properties field.
    if ($additionalProperties -and $additionalProperties.Count) {
        foreach ($entry in $additionalProperties.GetEnumerator()) {
            $telemetryObject.data.baseData.properties[$entry.Name] = $entry.Value
        }
    }

    Write-Host "An error was encountered during install: $reason"
    Write-Host "Error data collected:"
    $telemetryDataTable = $telemetryObject.data.baseData.properties | Format-Table | Out-String
    Write-Host $telemetryDataTable
    if (!(promptForTelemetry)) {
        # The user responded 'no' to the telemetry prompt or is in a
        # non-interactive session. Do not send telemetry.
        return
    }

    try {
        Invoke-RestMethod `
            -Uri 'https://centralus-2.in.applicationinsights.azure.com/v2/track' `
            -ContentType 'application/json' `
            -Method Post `
            -Body (ConvertTo-Json -InputObject $telemetryObject -Depth 100 -Compress) | Out-Null
        Write-Verbose -Verbose:$Verbose "Telemetry posted"
    } catch {
        Write-Host $_
        Write-Verbose -Verbose:$Verbose "Telemetry post failed"
    }
}

if (isLinuxOrMac) {
    if (!(Get-Command curl)) { 
        Write-Error "Command could not be found: curl."
        exit 1
    }
    if (!(Get-Command bash)) { 
        Write-Error "Command could not be found: bash."
        exit 1
    }

    $params = @(
        '--base-url', "'$BaseUrl'", 
        '--version', "'$Version'"
    )

    if ($InstallFolder) {
        $params += '--install-folder', "'$InstallFolder'"
    }

    if ($SymlinkFolder) {
        $params += '--symlink-folder', "'$SymlinkFolder'"
    }

    if ($SkipVerify) { 
        $params += '--skip-verify'
    }

    if ($DryRun) {
        $params += '--dry-run'
    }

    if ($NoTelemetry) {
        $params += '--no-telemetry'
    }

    if ($VerbosePreference -eq 'Continue') {
        $params += '--verbose'
    }

    $bashParameters = $params -join ' '
    Write-Verbose "Running: curl -fsSL $InstallShScriptUrl | bash -s -- $bashParameters" -Verbose:$Verbose
    bash -c "curl -fsSL $InstallShScriptUrl | bash -s -- $bashParameters"
    exit $LASTEXITCODE
}

try {
    $packageFilename = "azd-windows-amd64.msi"

    $downloadUrl = "$BaseUrl/$packageFilename"
    if ($Version) {
        $downloadUrl = "$BaseUrl/$Version/$packageFilename"
    }

    if ($DryRun) {
        Write-Host $downloadUrl
        exit 0
    }

    $tempFolder = "$([System.IO.Path]::GetTempPath())$([System.IO.Path]::GetRandomFileName())"
    Write-Verbose "Creating temporary folder for downloading package: $tempFolder"
    New-Item -ItemType Directory -Path $tempFolder | Out-Null

    Write-Verbose "Downloading build from $downloadUrl" -Verbose:$Verbose
    $releaseArtifactFilename = Join-Path $tempFolder $packageFilename
    try {
        $global:LASTEXITCODE = 0
        Invoke-WebRequest -Uri $downloadUrl -OutFile $releaseArtifactFilename -TimeoutSec $DownloadTimeoutSeconds
        if ($LASTEXITCODE) {
            throw "Invoke-WebRequest failed with nonzero exit code: $LASTEXITCODE"
        }
    } catch {
        Write-Error -ErrorRecord $_
        reportTelemetryIfEnabled 'InstallFailed' 'DownloadFailed' @{ downloadUrl = $downloadUrl }
        exit 1
    }
   

    try {
        if (!$SkipVerify) {
            try {
                Write-Verbose "Verifying signature of $releaseArtifactFilename" -Verbose:$Verbose
                $signature = Get-AuthenticodeSignature $releaseArtifactFilename
                if ($signature.Status -ne 'Valid') {
                    Write-Error "Signature of $releaseArtifactFilename is not valid"
                    reportTelemetryIfEnabled 'InstallFailed' 'SignatureVerificationFailed'
                    exit 1
                }
            } catch {
                Write-Error -ErrorRecord $_
                reportTelemetryIfEnabled 'InstallFailed' 'SignatureVerificationFailed'
                exit 1
            }
        }

        Write-Verbose "Installing MSI" -Verbose:$Verbose
        $MSIEXEC = "${env:SystemRoot}\System32\msiexec.exe"
        $installProcess = Start-Process $MSIEXEC `
            -ArgumentList @("/i", "`"$releaseArtifactFilename`"", "/qn", "INSTALLDIR=`"$InstallFolder`"", "INSTALLEDBY=`"install-azd.ps1`"") `
            -PassThru `
            -Wait

        if ($installProcess.ExitCode) {
            if ($installProcess.ExitCode -eq 1603) {
                Write-Host "A later version of Azure Developer CLI may already be installed. Use 'Add or remove programs' to uninstall that version and try again."
            }

            Write-Error "Could not install MSI at $releaseArtifactFilename. msiexec.exe returned exit code: $($installProcess.ExitCode)"

            reportTelemetryIfEnabled 'InstallFailed' 'MsiFailure' @{ msiExitCode = $installProcess.ExitCode }
            exit 1
        }
    } catch {
        Write-Error -ErrorRecord $_
        reportTelemetryIfEnabled 'InstallFailed' 'GeneralInstallFailure'
        exit 1
    }

    Write-Verbose "Cleaning temporary install directory: $tempFolder" -Verbose:$Verbose
    Remove-Item $tempFolder -Recurse -Force | Out-Null

    if (!(isLinuxOrMac)) {
        # Installed on Windows
        Write-Host "Successfully installed azd"
        Write-Host "Azure Developer CLI (azd) installed successfully. You may need to restart running programs for installation to take effect."
        Write-Host "- For Windows Terminal, start a new Windows Terminal instance."
        Write-Host "- For VSCode, close all instances of VSCode and then restart it."
    }
    Write-Host ""
    Write-Host "The Azure Developer CLI collects usage data and sends that usage data to Microsoft in order to help us improve your experience."
    Write-Host "You can opt-out of telemetry by setting the AZURE_DEV_COLLECT_TELEMETRY environment variable to 'no' in the shell you use."
    Write-Host ""
    Write-Host "Read more about Azure Developer CLI telemetry: https://github.com/Azure/azure-dev#data-collection"

    exit 0
} catch {
    Write-Error -ErrorRecord $_
    reportTelemetryIfEnabled 'InstallFailed' 'UnhandledError' @{ exceptionName = $_.Exception.GetType().Name; }
    exit 1
}
# SIG # Begin signature block
# MIIoKAYJKoZIhvcNAQcCoIIoGTCCKBUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAutMpvjwitgD44
# E4w0c9iW/e2w2w1pD89LokaHWMUJwqCCDXYwggX0MIID3KADAgECAhMzAAAEhV6Z
# 7A5ZL83XAAAAAASFMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjUwNjE5MTgyMTM3WhcNMjYwNjE3MTgyMTM3WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDASkh1cpvuUqfbqxele7LCSHEamVNBfFE4uY1FkGsAdUF/vnjpE1dnAD9vMOqy
# 5ZO49ILhP4jiP/P2Pn9ao+5TDtKmcQ+pZdzbG7t43yRXJC3nXvTGQroodPi9USQi
# 9rI+0gwuXRKBII7L+k3kMkKLmFrsWUjzgXVCLYa6ZH7BCALAcJWZTwWPoiT4HpqQ
# hJcYLB7pfetAVCeBEVZD8itKQ6QA5/LQR+9X6dlSj4Vxta4JnpxvgSrkjXCz+tlJ
# 67ABZ551lw23RWU1uyfgCfEFhBfiyPR2WSjskPl9ap6qrf8fNQ1sGYun2p4JdXxe
# UAKf1hVa/3TQXjvPTiRXCnJPAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUuCZyGiCuLYE0aU7j5TFqY05kko0w
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwNTM1OTAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBACjmqAp2Ci4sTHZci+qk
# tEAKsFk5HNVGKyWR2rFGXsd7cggZ04H5U4SV0fAL6fOE9dLvt4I7HBHLhpGdE5Uj
# Ly4NxLTG2bDAkeAVmxmd2uKWVGKym1aarDxXfv3GCN4mRX+Pn4c+py3S/6Kkt5eS
# DAIIsrzKw3Kh2SW1hCwXX/k1v4b+NH1Fjl+i/xPJspXCFuZB4aC5FLT5fgbRKqns
# WeAdn8DsrYQhT3QXLt6Nv3/dMzv7G/Cdpbdcoul8FYl+t3dmXM+SIClC3l2ae0wO
# lNrQ42yQEycuPU5OoqLT85jsZ7+4CaScfFINlO7l7Y7r/xauqHbSPQ1r3oIC+e71
# 5s2G3ClZa3y99aYx2lnXYe1srcrIx8NAXTViiypXVn9ZGmEkfNcfDiqGQwkml5z9
# nm3pWiBZ69adaBBbAFEjyJG4y0a76bel/4sDCVvaZzLM3TFbxVO9BQrjZRtbJZbk
# C3XArpLqZSfx53SuYdddxPX8pvcqFuEu8wcUeD05t9xNbJ4TtdAECJlEi0vvBxlm
# M5tzFXy2qZeqPMXHSQYqPgZ9jvScZ6NwznFD0+33kbzyhOSz/WuGbAu4cHZG8gKn
# lQVT4uA2Diex9DMs2WHiokNknYlLoUeWXW1QrJLpqO82TLyKTbBM/oZHAdIc0kzo
# STro9b3+vjn2809D0+SOOCVZMIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGggwghoEAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAASFXpnsDlkvzdcAAAAABIUwDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICwOWJggeUVjb/JkwUiJ+q6G
# ODLHl06vGaZsBDoUAcjxMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAmiHsqVj3OEfP+aWpTPu2FlJkWHpCg14o+b6Twvym9JaRDwhxbR7vwuDP
# jr2Kg84SUagwHSCGkkWIQXfISiuqyErT2URniqLFZrzo0YS22zdHmKvWbQW/drf+
# 0iZ1UjI4YR2GchMHVbef9ifNM00w80MSVD77IrOqrmYVzJZRi1/nlTTTdySAVMQB
# 8vuc0S8fTSZR4ySMShCGCexlzt+dASyi9LsnniOhB5UKHGGy5yeBjOX+Y7qO3JGY
# bBUrpff0mURTgfXOdfVnLcSP4nMp2X1UPtAlqyk8LqQoEOP/uuZ+WJtO4iKY+1oL
# owvnuIgc/SWpa47VRyXF4zBsYq9056GCF5IwgheOBgorBgEEAYI3AwMBMYIXfjCC
# F3oGCSqGSIb3DQEHAqCCF2swghdnAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFQBgsq
# hkiG9w0BCRABBKCCAT8EggE7MIIBNwIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCBMw+Z3JuQPlmxrVQMBvcrTpghgcm2aCI0flo6vhPxfBQIGaPBuxQkT
# GBEyMDI1MTAyMzAyMjc0OS43WjAEgAIB9KCB0aSBzjCByzELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJp
# Y2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg5MDAtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR
# 6jCCByAwggUIoAMCAQICEzMAAAIOLMsofZUgdWMAAQAAAg4wDQYJKoZIhvcNAQEL
# BQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwMTMwMTk0MzAz
# WhcNMjYwNDIyMTk0MzAzWjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg5MDAtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEArObe4kbV7dIW3qPTBO/GWIyKN7GkLljARUO1+LPb6KGE
# QAUzn9qaEx2rcfhMJwVBgdVdrfxOjMLEDZmOV6TP++Wgq2XcQJ61faOE7ubAXqW2
# 33obKzlkQSBqCROj7VqHdQqxXoZtXYs942Nx/Iha4e56nn54mdUp23FjzMjSMbhh
# c6UIgwPhOWEt95njKml8IXW9NQpbspof9xCr5J4+HSKUGRFjjzN48W0VQGDeSdrT
# q2JCXHQ8dJdNlfzWHdapL1AYD8ayr4quZM+xOgGzonwg0jAYHJ/1+0UMOt9EJM6o
# adJA1Nqnov2qPSB5rrkXlxI546YE7K+AG99yAgCjGMTkHvp+cKhFXBPTk8oZlmSU
# uQJ1lE54qJOJoMDjQVkNQyzhhZGcF099+CDwqneP9/y3fyLYs4rLclGWLJpfwuGY
# XQC2732MM799TsX/DU5leSBsVnR55Nh4YeG580yqLBGg6yb0DIkPpaKIzO3+W4Hc
# gQZ2EAZufv4ibMcPJNtu8xdo2zSPjsLPBy3mRrfLeridnlYzQ9QdGLYLAT9HLAZZ
# 5yPuPnby2EbdHAKsOj4mEs+RUmXG6YtMXQB/43d3c8hgK28i7qOvR7oHxhBG/7DN
# O63KD9aN3GfHljG+PjCAfHrjm+Q1Tw5xHBYuDQ7pGDPdYNQ7f6iHpPq7RPPFUvEC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBSFcURpUhGRPtREiulBiO2DXBCI2zAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAdeC9ky/i/Dly8Zxkmpdod9JmexbARaKImJFF
# TmNORfaZ8D01bnxAxlhKTTctjn2lB1iDqEP/f648DtIUtkqQdAczAJNoMs/djRlj
# qVm6QXTL660Q6YlmYv7i0uGRnUZ9z9g3HGJpZDT/r2kQF757/pqduyoCO/ZifYRs
# gkG77TCI5G2KC6iu7Be1moZ/ay419cuUCS+JbxMt0JgPSkQY+enBL/5QL8w6u3ko
# qkav6QsqsnPLs5kPEnilslrug41APb4vOELJi46jxgpx+HD8oPrfeUaVvu97J4Xs
# NYglfsF7tkcTJ1oOxLA+Xi5CRy7M1CD3flwpQ/hU71dNxn6ww35PuOX5R/3ikWXN
# zFGbZ4SyYz8L9yqCg0nFuIlekmwkcnGD5KqFgax3+0rwwOxqx9lDrc9VmtZNu7HW
# YKRuv3PQqiiPAl+b4GmvgO6GB2+GQY+0vLvLIMcFiux4Fg0Qcjh9woibuCyfId04
# kZEQK5h0adJWzX9YgCri/POiChPddr9MquebfIzMYwVO7qC7K2FSKCpM4frAJIJK
# RjqGS9ePnZcVTPdQWr82uJDg01JcM2/kqV7EqlcfJ7geqoVMu6aqYMMNauEjYQMR
# ZxcbMYk5WqC++RjcT0etOZSdll3obRIu//mHyarx/r56nKago8kPYTWlc7jhB1+D
# MrqnI8IwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDTTCC
# AjUCAQEwgfmhgdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjo4OTAwLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIaAxUASuh2
# P2Vi5znDBELI5AwKAfyWVgiggYMwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAOyjfkswIhgPMjAyNTEwMjIxNjAxMTVa
# GA8yMDI1MTAyMzE2MDExNVowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA7KN+SwIB
# ADAHAgEAAgITLTAHAgEAAgIR0jAKAgUA7KTPywIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQBs5619POe6l1uZll0jE1JsP6yoGs8pVHJORsGCTGXWaDZEaLNZ
# 1q5CtfQdHgqfdzsJ3pGoeClYSSEYKDpmj2bN8tyvUQWIzXJsBPqKM8tfvjeetQ2C
# o6+FRYv16tqCblYnl8rOG1Uq4nBMeBZBx9eWBuxCeuQHQNC9gb/D8GQCNwZCG7/f
# fWOiLm48bCBmqgE0jvXgXgjBvhnTXtuuf4NPwFxlyU73DWpXayZN5kdmZmCkqSA5
# 8goowlScnbQWutxcyWAWjEvgAIcjXzsQd9gNIuIz/T+JyucJNQhrYp/AYWOhk4jK
# WCgbV7527+3lwISt/m47Y9uIjPbrq4qIFPEjMYIEDTCCBAkCAQEwgZMwfDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIOLMsofZUgdWMAAQAAAg4wDQYJ
# YIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkq
# hkiG9w0BCQQxIgQguaq17l1ycjmq0YTCLsMAt6MUFXGgXzI7XBFPBnhgru4wgfoG
# CyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCABdB1zJfDpgZCtuu5saGykoocDnT9H
# lDV0DMqT808ShjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# AhMzAAACDizLKH2VIHVjAAEAAAIOMCIEIBILxg0NDwJCqsgeKHfuQY0dAhzK2xBh
# K64X2s4g3R2gMA0GCSqGSIb3DQEBCwUABIICAIcYLSPbz8CV001/LRXbM/6yVmpk
# KT73tQdCOngVcz6UzkdEmYoBhe6urtztqXXuGNZD87ast2S5R0k4i2hL/j0NJ2RV
# ziQApiHxjhON4QlLFE1ZPsxB/Zb/y3A/xqBSW+VCiwX1vN+x3HvU4lCXW3MR6NEw
# PGXk3xXSiQCCPB0JUtR7JH/SFX/PsEo6iieYNBppUwb3c3o891+p/apuDOAKcMpn
# odSMFAEJhHu+jv9hkMRX+Yz+iFPHmOatgP1asIEmoJ9XyzCzzL105uZMY7W/8w5b
# ixcFoXtmElwCyNeBisrJJWQEHUBRg15+O07uBvWYB+KKFmpIv6HoB+RgkQY1r78G
# L0TUuyQhovvhakBW+Ayc2N+dJhspvG/b7MY3ToLCXsuLMsrFKw6ddbejqzciiYb/
# UqcYAs9pPLf7L80gT2pBSN7I4aUcMdwBW+3+Sn6JZRlqA0JuWmNuLLn/sxDhwV5A
# 2HJY9AlhJ4FLFSqAtVGFpIqtEY4FUjQdSi9xR0/PZHC4SdozBfMCWdY/X+dSRZe0
# eH9L+RQ7L6LbvdUSnHqUR/vFm9v6q6xcoj5X+TG0D2bFOluEHRduU09r+mtnP91j
# 2E6q/OuWU9UxOa2Xu+s29dGKqJbfGYcFz4NL1aJeyMqLhUeEGXCrNZNJ2K5if0gt
# F3ggS6HTyCyNrd0N
# SIG # End signature block
