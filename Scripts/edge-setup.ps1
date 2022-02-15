<#
 .SYNOPSIS
    Installs IoT edge 

 .DESCRIPTION
    Installs IoT edge on a linux vm and enrolls vm.

 .PARAMETER iotHubHostname
   IoT Hub hostname.

  .PARAMETER deviceId
   Device Id.

 .PARAMETER certFile
    The certificate name.

 .PARAMETER keyFile
    The certificate private key name.
#>
param(
   [Parameter(Mandatory)]
   [string] $iotHubHostname,
   [Parameter(Mandatory)]
   [string] $deviceId,
   [Parameter(Mandatory)]
   [string] $certFile,
   [Parameter(Mandatory)]
   [string] $keyFile
)

if ($PsVersionTable.Platform -eq "Unix") {

   $template = "/etc/aziot/config.toml.edge.template"
   $file = "/etc/aziot/config.toml"
   Copy-Item $template $file -Force

   Write-Host "Configure and initialize IoT Edge on Linux using enrollment information."

   $configToml += "`n"
    $configToml += "`n##########################################################################"
    $configToml += "`n# Manual x.509 cert provisioning configuration - added by edge-setup.ps1 #"
    $configToml += "`n##########################################################################"
    $configToml += "`n"
    $configToml += "`n[provisioning]"
    $configToml += "`nsource = `"manual`""
    $configToml += "`niothub_hostname = `"$iothubHostname`""
    $configToml += "`ndevice_id = `"$($deviceId)`""
    $configToml += "`n`n[provisioning.authentication]"
    $configToml += "`nmethod = `"x509`""
    $configToml += "`nidentity_cert = `"file://$certFile`""
    $configToml += "`nidentity_pk = `"file://$keyFile`""
    $configToml += "`n"
    $configToml += "`n########################################################################"
    $configToml += "`n"

    $configToml | Out-File $file -Force
}
else {
    Write-Error "Windows OS is not supported in this demo"
    return -1
}