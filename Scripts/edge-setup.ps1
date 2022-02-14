<#
 .SYNOPSIS
    Installs IoT edge 

 .DESCRIPTION
    Installs IoT edge on either linux or windows vm and enrolls vm in DPS.

 .PARAMETER dpsConnString
    The Dps connection string

 .PARAMETER idScope
    The Dps id scope

 .PARAMETER dpsGlobalEndpoint
    The Dps global endpoint
#>
param(
    [Parameter(Mandatory)]
    [string] $dpsGlobalEndpoint,
    [Parameter(Mandatory)]
    [string] $dpsConnString,
    [Parameter(Mandatory)]
    [string] $idScope
)

$path = Split-Path $script:MyInvocation.MyCommand.Path
$enrollPath = join-path $path dps-enroll.ps1
if ($PsVersionTable.Platform -eq "Unix") {

    $file = "/etc/aziot/config.toml"
    if (Test-Path $file) {
        $backup = "$($file)-backup"
        if (Test-Path $backup) {
            Write-Host "Already configured."
            return
        }
        $configToml = Get-Content $file -Raw
        if ([string]::IsNullOrWhiteSpace($configToml)) {
            throw "$($file) empty."
        }
        $configToml | Out-File $backup -Force
    }
    else {
        throw "$($file) does not exist."
    }

    Write-Host "Create new IoT Edge enrollment."
    $enrollment = & $enrollPath -dpsConnString $dpsConnString -os Linux
    Write-Host "Configure and initialize IoT Edge on Linux using enrollment information."

    # comment out existing 
    # $configToml = $configToml.Replace("`nprovisioning:", "`n#provisioning:")
    # $configToml = $configToml.Replace("`nsource:", "`n#  source:")
    # $configToml = $configToml.Replace("`ndevice_connection_string:", "`n#  device_connection_string:")
    # $configToml = $configToml.Replace("`ndynamic_reprovisioning:", "`n#  dynamic_reprovisioning:")

    # add dps setting
    $configToml += "`n"
    $configToml += "`n########################################################################"
    $configToml += "`n# DPS symmetric key provisioning configuration - added by edge-setup.ps1 #"
    $configToml += "`n########################################################################"
    $configToml += "`n"
    $configToml += "`n[provisioning]"
    $configToml += "`nsource = `"dps`""
    $configToml += "`nglobal_endpoint = `"$dpsGlobalEndpoint`""
    $configToml += "`nscope_id = `"$($idScope)`""
    $configToml += "`n[provisioning.attestation]"
    $configToml += "`nmethod = `"symmetric_key`""
    $configToml += "`nregistration_id = `"$($enrollment.registrationId)`""
    $configToml += "`nsymmetric_key = `"$($enrollment.primaryKey)`""
    $configToml += "`n"
    $configToml += "`n########################################################################"
    $configToml += "`n"

    $configToml | Out-File $file -Force
}
else {
    Write-Error "Windows OS is not supported in this demo"
    return -1
}