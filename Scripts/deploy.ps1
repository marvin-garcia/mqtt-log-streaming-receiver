$root_path = Split-Path $PSScriptRoot -Parent
Import-Module "$root_path/Scripts/PS-Library"
$github_repo_url = "https://raw.githubusercontent.com/marvin-garcia/mqtt-log-streaming-receiver"
$github_branch_name = $(git rev-parse --abbrev-ref HEAD)

function Set-EnvironmentHash {
    param(
        [int] $hash_length = 8
    )
    $script:env_hash = Get-EnvironmentHash -hash_length $hash_length
}

function Read-CliVersion {
    param (
        [version]$min_version = "2.21"
    )

    $az_version = az version | ConvertFrom-Json
    [version]$cli_version = $az_version.'azure-cli'

    Write-Host
    Write-Host "Verifying your Azure CLI installation version..."
    Start-Sleep -Milliseconds 500

    if ($min_version -gt $cli_version) {
        Write-Host
        Write-Host "You are currently using the Azure CLI version $($cli_version) and this wizard requires version $($min_version) or later. You can update your CLI installation with 'az upgrade' and come back at a later time."

        return $false
    }
    else {
        Write-Host
        Write-Host "Great! You are using a supported Azure CLI version."

        return $true
    }
}

function Set-AzureAccount {
    param()

    Write-Host
    Write-Host "Retrieving your current Azure subscription..."
    Start-Sleep -Milliseconds 500

    $account = az account show | ConvertFrom-Json

    $option = Get-InputSelection `
        -options @("Yes", "No. I want to use a different subscription") `
        -text "You are currently using the Azure subscription '$($account.name)'. Do you want to keep using it?" `
        -default_index 1
    
    if ($option -eq 2) {
        $accounts = az account list | ConvertFrom-Json | Sort-Object -Property name

        $account_list = $accounts | Select-Object -Property @{ label="displayName"; expression={ "$($_.name): $($_.id)" } }
        $option = Get-InputSelection `
            -options $account_list.displayName `
            -text "Choose a subscription to use from this list (using its Index):" `
            -separator "`r`n`r`n"

        $account = $accounts[$option - 1]

        Write-Host "Switching to Azure subscription '$($account.name)' with id '$($account.id)'."
        az account set -s $account.id
    }
}

function Set-ResourceGroupName {
    param()

    $script:create_resource_group = $false
    $script:resource_group_name = $null
    $first = $true

    while ([string]::IsNullOrEmpty($script:resource_group_name) -or ($script:resource_group_name -notmatch "^[a-z0-9-_]*$")) {
        if ($first -eq $false) {
            Write-Host "Use alphanumeric characters as well as '-' or '_'."
        }
        else {
            Write-Host
            Write-Host "Provide a name for the resource group to host all the new resources that will be deployed as part of your solution."
            $first = $false
        }
        $script:resource_group_name = Read-Host -Prompt ">"

        $resourceGroup = az group list | ConvertFrom-Json | Where-Object { $_.name -eq $script:resource_group_name }
        if (!$resourceGroup) {
            $script:create_resource_group = $true
        }
        else {
            $script:create_resource_group = $false
        }
    }
}

function Get-IoTDeviceId {
    param()

    $device_id = $null
    $first = $true

    while ([string]::IsNullOrEmpty($device_id) -or ($device_id -notmatch "^[a-z0-9-]*$")) {
        if ($first -eq $false) {
            Write-Host "Use alphanumeric characters as well as '-'."
        }
        else {
            Write-Host
            Write-Host "Provide an Id for the IoT device."
            $first = $false
        }
        $device_id = Read-Host -Prompt ">"

        return $device_id
    }
}

function Set-MqttTopicName {

    $script:mqtt_topic_name = $null
    $first = $true

    while ([string]::IsNullOrEmpty($script:mqtt_topic_name) -or ($script:mqtt_topic_name -notmatch "^[a-z0-9_\/]*$")) {
        if ($first -eq $false) {
            Write-Host "Use alphanumeric characters as well as '_' and '/'. For example: 'observability/logs'."
        }
        else {
            Write-Host
            Write-Host "Provide topic name each device will publish logs to. Default value is 'obsagent/log'."
            $first = $false
        }
        $script:mqtt_topic_name = Read-Host -Prompt "> (obsagent/log)"
        if ([string]::IsNullOrEmpty($script:mqtt_topic_name)) {
            $script:mqtt_topic_name = "obsagent/log"
        }
    }
}

function Get-InputSelection {
    param(
        [array] $options,
        $text,
        $separator = "`r`n",
        $default_index = $null
    )

    Write-Host
    Write-Host $text -Separator "`r`n`r`n"
    $indexed_options = @()
    for ($index = 0; $index -lt $options.Count; $index++) {
        $indexed_options += ("$($index + 1): $($options[$index])")
    }

    Write-Host $indexed_options -Separator $separator

    if (!$default_index) {
        $prompt = ">"
    }
    else {
        $prompt = "> $default_index"
    }

    while ($true) {
        $option = Read-Host -Prompt $prompt
        try {
            if (!!$default_index -and !$option)  {
                $option = $default_index
                break
            }
            elseif ([int] $option -ge 1 -and [int] $option -le $options.Count) {
                break
            }
        }
        catch {
            Write-Host "Invalid index '$($option)' provided."
        }

        Write-Host
        Write-Host "Choose from the list using an index between 1 and $($options.Count)."
    }

    return $option
}

function Get-ExistingResource {
    param (
        [string] $type,
        [string] $display_name,
        [string] $separator = "`r`n"
    )
 
    $resources = az resource list --resource-type $type | ConvertFrom-Json | Sort-Object -Property id
    if ($resources.Count -gt 0) {
        
        $option = Get-InputSelection `
            -options $resources.id `
            -text "Choose $($prefix) $($display_name) to use from this list (using its Index):" `
            -separator $separator

        return $resources[$option - 1]
    }
    else {
        return $null
    }
}

function Get-NewOrExistingResource {
    param(
        [string] $type,
        [string] $display_name,
        [string] $separator = "`r`n"
    )

    $resources = az resource list --resource-type $type | ConvertFrom-Json | Sort-Object -Property id
    if ($resources.Count -gt 0) {
        
        $option = Get-InputSelection `
            -options @("Create new $($display_name)", "Use existing $($display_name)") `
            -text "Choose an option from the list for the $($display_name) (using its index):"

        if ($option -eq 2) {

            $regex = "^[aeiou].*$"
            if ($display_name -imatch $regex) {
                $prefix = "an"
            }
            else {
                $prefix = "a"
            }

            $option = Get-InputSelection `
                -options $resources.id `
                -text "Choose $($prefix) $($display_name) to use from this list (using its Index):" `
                -separator $separator

            return $resources[$option - 1]
        }
        else {
            return $null
        }
    }
    else {
        return $null
    }
}

function Set-IoTHub {
    param(
        [string] $prefix = "iothub",
        [string] $policy_name = "iotedgelogs")

    if (!$script:sandbox) {
        $iot_hub = Get-NewOrExistingResource -type "Microsoft.Devices/IoTHubs" -display_name "IoT hub" -separator "`r`n`r`n"

        if (!!$iot_hub) {
            $script:create_iot_hub = $false
            $script:iot_hub_name = $iot_hub.name
            $script:iot_hub_resource_group = $iot_hub.resourcegroup
            $script:iot_hub_location = $iot_hub.location
        }
        else {
            $script:create_iot_hub = $true
        }
    }
    else {
        $script:create_iot_hub = $true
    }

    if ($script:create_iot_hub) {
        $script:iot_hub_resource_group = $script:resource_group_name
        $script:iot_hub_name = "$($prefix)-$($script:env_hash)"
        $script:iot_hub_policy_name = $policy_name
    }
}

function Set-Storage {
    param([string] $prefix = "iotedgelogs")

    if (!$script:sandbox) {
        $storage_account = Get-NewOrExistingResource -type "Microsoft.Storage/storageAccounts" -display_name "storage account" -separator "`r`n`r`n"

        if (!!$storage_account) {
            $script:create_storage = $false
            $script:storage_account_id = $storage_account.id
            $script:storage_account_name = $storage_account.name
            $script:storage_account_resource_group = $storage_account.resourceGroup
            $script:storage_account_location = $storage_account.location

            #region event grid system topic
            $system_topics = az eventgrid system-topic list | ConvertFrom-Json
            $system_topic = $system_topics | Where-Object { $_.source -eq $script:storage_account_id }
            if (!!$system_topic) {
                $script:create_event_grid = $false
                $script:event_grid_topic_name = $system_topic.name
            }
            else {
                $script:create_event_grid = $true
            }
            #endregion
        }
        else {
            $script:create_storage = $true
            $script:create_event_grid = $true
        }
    }
    else {
        $script:create_storage = $true
        $script:create_event_grid = $true
    }

    if ($script:create_storage) {
        $script:storage_account_resource_group = $script:resource_group_name
        $script:storage_account_name = "$($prefix)$($script:env_hash)"
    }

    if ($script:create_event_grid) {
        $script:event_grid_topic_name = "$($prefix)-$($script:env_hash)"
    }

    $script:storage_container_name = "$($prefix)$($script:env_hash)"
    $script:storage_queue_name = "$($prefix)$($script:env_hash)"
}

function Set-LogAnalyticsWorkspace {
    param([string] $prefix = "iotedgelogs")

    if (!$script:sandbox) {
        $workspace = Get-NewOrExistingResource -type "Microsoft.OperationalInsights/workspaces" -display_name "log analytics workspace" -separator "`r`n`r`n"

        if (!!$workspace) {
            $script:create_workspace = $false
            $script:workspace_name = $workspace.name
            $script:workspace_resource_group = $workspace.resourceGroup
            $script:workspace_location = $workspace.location
        }
        else {
            $script:create_workspace = $true
        }
    }
    else {
        $script:create_workspace = $true
    }

    if ($script:create_workspace) {
        $script:workspace_resource_group = $script:resource_group_name
        $script:workspace_name = "$($prefix)-$($script:env_hash)"
    }
}

function Set-EventHubsNamespace {
    param(
        [string] $prefix = "metricscollector",
        [string] $route_prefix = "monitoringmetrics",
        [string] $route_condition
    )

    if ($script:enable_monitoring -and $script:monitoring_mode -eq "IoTMessage") {
        if (!$script:sandbox) {
            $namespace = Get-NewOrExistingResource -type "Microsoft.EventHub/namespaces" -display_name "event hubs namespace" -separator "`r`n`r`n"

            if (!!$namespace) {
                $script:create_event_hubs_namespace = $false
                $script:event_hubs_resource_group = $namespace.resourceGroup
                $script:event_hubs_namespace = $namespace.name
                $script:event_hubs_location = $namespace.location
            }
            else {
                $script:create_event_hubs_namespace = $true
            }
        }
        else {
            $script:create_event_hubs_namespace = $true
        }

        if ($script:create_event_hubs_namespace) {
            $script:event_hubs_resource_group = $script:iot_hub_resource_group
            $script:event_hubs_namespace = "$($prefix)-$($script:env_hash)"
        }

        $script:create_event_hubs = $true
        $script:event_hubs_name = "$($prefix)-$($script:env_hash)"
        $script:event_hubs_listen_rule = "listen-$($script:env_hash)"
        $script:event_hubs_send_rule = "send-$($script:env_hash)"
        $script:event_hubs_endpoint = "$($prefix)-$($script:env_hash)"
        $script:event_hubs_route = "$($route_prefix)-$($script:env_hash)"
        $script:event_hubs_route_condition = $route_condition
    }
    else {
        $script:create_event_hubs_namespace = $false
        $script:create_event_hubs = $false
    }
}

function Set-EdgeInfrastructure {
    param (
        [string] $vm_prefix = "iotedgevm",
        [string] $vm_username = "azureuser",
        [int] $vm_password_length = 15,
        [int] $vm_cpu_cores = 2,
        [int] $vm_memory_mb = 8192,
        [int] $vm_os_disk_size = 1047552,
        [int] $vm_resource_disk_size = 8192,
        [string] $vnet_prefix = "iot-vnet",
        [string] $vnet_addr_prefix = "10.0.0.0/16",
        [string] $subnet_name = "iotedge",
        [string] $subnet_addr_prefix = "10.0.0.0/24"
    )

    if ($script:create_iot_hub) {
        #region virtual machine
        $skus = (az vm list-skus --location $script:iot_hub_location --all $false | Out-String).ToLower() | ConvertFrom-Json
        $vm_skus = $skus | Where-Object { $_.resourceType -ieq 'virtualMachines' -and $_.restrictions.Count -eq 0 }
        $vm_sku_names = $vm_skus | Select-Object -ExpandProperty Name -Unique
        
        $script:vm_name = "$($vm_prefix)-$($script:env_hash)"
        $script:vm_username = $vm_username
        $script:vm_password = New-Password -length $vm_password_length

        $vm_sizes = az vm list-sizes --location $script:iot_hub_location | ConvertFrom-Json `
        | Where-Object { $vm_sku_names -icontains $_.name } `
        | Where-Object {
            ($_.numberOfCores -ge $vm_cpu_cores) -and `
            ($_.memoryInMB -ge $vm_memory_mb) -and `
            ($_.osDiskSizeInMB -ge $vm_os_disk_size) -and `
            ($_.resourceDiskSizeInMB -gt $vm_resource_disk_size)
        } `
        | Sort-Object -Property `
            NumberOfCores, MemoryInMB, ResourceDiskSizeInMB, Name
        
        # Pick top
        if ($vm_sizes.Count -ne 0) {
            $script:vm_size = $vm_sizes[0].Name
        }

        # $script:vm_size = "Standard_B2ms"
        #endregion

        #region virtual network parameters
        $script:vnet_name = "$($vnet_prefix)-$($script:env_hash)"
        $script:vnet_addr_prefix = $vnet_addr_prefix
        $script:subnet_name = $subnet_name
        $script:subnet_addr_prefix = $subnet_addr_prefix
        #endregion
    }
}

function New-ELMSEnvironment() {

    #region script variables
    Set-EnvironmentHash

    $metrics_collector_message_id = "origin-iotedge-metrics-collector"
    $script:deployment_condition = "tags.mqttReceiver=true"
    $script:device_query = "SELECT * FROM devices WHERE $($script:deployment_condition)"
    $script:function_app_name = "iotedgelogsapp-$($script:env_hash)"
    $script:logs_regex = "\b(WRN?|ERR?|CRIT?)\b"
    $script:logs_since = "15m"
    $script:logs_encoding = "gzip"
    $script:metrics_encoding = "gzip"
    $script:invoke_log_upload_function_name = "InvokeUploadModuleLogs"
    $script:schedule_log_upload_function_name = "ScheduleUploadModuleLogs"
    $script:alert_function_name = "MonitorAlerts"
    $script:zip_package_name = "deploy.zip"
    $script:zip_package_path = "$($root_path)/FunctionApp/FunctionApp/$($zip_package_name)"
    $script:create_storage = $false
    $script:create_event_grid = $false
    #endregion

    #region greetings
    Write-Host
    Write-Host "#########################################"
    Write-Host "#########################################"
    Write-Host "####                                 ####"
    Write-Host "#### MQTT RECEIVER FOR LOG STREAMING ####"
    Write-Host "####                                 ####"
    Write-Host "#########################################"
    Write-Host "#########################################"

    # Start-Sleep -Milliseconds 1500

    # Write-Host
    # Write-Host "Welcome to IoT ELMS (Edge Logging & Monitoring Solution). This deployment script will help you deploy IoT ELMS in your Azure subscription. It can be deployed as a sandbox environment, with a new IoT hub and a test IoT Edge device generating sample logs and collecting monitoring metrics, or it can connect to your existing IoT Hub and Log analytics workspace."
    # Write-Host
    # Write-Host "Press Enter to continue."
    # Read-Host
    #endregion

    #region validate CLI version
    $cli_valid = Read-CliVersion
    if (!$cli_valid) {
        return $null
    }
    #endregion

    # set azure susbcription
    Set-AzureAccount

    #region obtain resource group name
    if ($deployment_option -eq 1 -or $deployment_option -eq 2) {
        
        Set-ResourceGroupName

        Write-Host
        if ($script:create_resource_group) {
            Write-Host "Resource group '$script:resource_group_name' does not exist. It will be created later in the deployment."
        }
        else {
            Write-Host "Resource group '$script:resource_group_name' already exists in current subscription."
        }
    }
    #endregion

    $script:sandbox = $true
    $script:enable_monitoring = $false
    $script:create_event_hubs_namespace = $false
    $script:create_event_hubs = $false

    Set-IoTHub
    Set-Storage
    Set-LogAnalyticsWorkspace

    #region obtain deployment location
    if ($script:create_iot_hub) {
        $locations = Get-ResourceProviderLocations -provider 'Microsoft.Devices' -typeName 'IotHubs' | Sort-Object

        $option = Get-InputSelection `
            -options $locations `
            -text "Choose a location for your deployment from this list (using its Index):"

        $script:iot_hub_location = $locations[$option - 1].Replace(' ', '').ToLower()
    }

    Write-Host
    if ($script:create_iot_hub) {
        Write-Host "Using location '$($script:iot_hub_location)'"
    }
    else {
        Write-Host "Using location '$($script:iot_hub_location)' based on your IoT hub location"
    }
    #endregion

    #region create resource group
    if ($script:create_resource_group) {
        az group create --name $script:resource_group_name --location $script:iot_hub_location | ConvertFrom-Json | Out-Null
        
        Write-Host
        Write-Host "Created new resource group $($script:resource_group_name) in $($script:iot_hub_location)."
    }
    #endregion

    #region set resource location
    if (!(Get-Variable -Name storage_account_location -ErrorAction SilentlyContinue)) {
        $script:storage_account_location = $script:iot_hub_location
    }
    if (!(Get-Variable -Name workspace_location -ErrorAction SilentlyContinue)) {
        $script:workspace_location = $script:iot_hub_location
    }
    if (!(Get-Variable -Name event_hubs_location -ErrorAction SilentlyContinue)) {
        $script:event_hubs_location = $script:iot_hub_location
    }
    #endregion

    #region create deployment
    Set-EdgeInfrastructure

    $template_parameters = @{
        "location"                    = @{ "value" = $script:iot_hub_location }
        "environmentHashId"           = @{ "value" = $script:env_hash }
        "iotHubName"                  = @{ "value" = $script:iot_hub_name }
        "iotHubServicePolicyName"     = @{ "value" = $script:iot_hub_policy_name }
        "edgeVmName"                  = @{ "value" = $script:vm_name }
        "edgeVmSize"                  = @{ "value" = $script:vm_size }
        "adminUsername"               = @{ "value" = $script:vm_username }
        "adminPassword"               = @{ "value" = $script:vm_password }
        "vnetName"                    = @{ "value" = $script:vnet_name }
        "vnetAddressPrefix"           = @{ "value" = $script:vnet_addr_prefix }
        "edgeSubnetName"              = @{ "value" = $script:subnet_name }
        "edgeSubnetAddressRange"      = @{ "value" = $script:subnet_addr_prefix }
        "storageAccountName"          = @{ "value" = $script:storage_account_name }
        "storageContainerName"        = @{ "value" = $script:storage_container_name }
        "workspaceName"               = @{ "value" = $script:workspace_name }
        "templateUrl"                 = @{ "value" = $github_repo_url }
        "branchName"                  = @{ "value" = $github_branch_name }
    }

    Set-Content -Path "$($root_path)/Templates/azuredeploy.parameters.json" -Value (ConvertTo-Json $template_parameters -Depth 5)

    Write-Host
    Write-Host "Creating resource group deployment."

    $script:deployment_output = az deployment group create `
        --resource-group $script:resource_group_name `
        --name "IoTEdgeLogging-$($script:env_hash)" `
        --mode Incremental `
        --template-file "$($root_path)/Templates/azuredeploy.json" `
        --parameters "$($root_path)/Templates/azuredeploy.parameters.json" | ConvertFrom-Json

    if (!$script:deployment_output) {
        throw "Something went wrong with the resource group deployment. Ending script."        
    }
    #endregion

    #region generate edge certificates
    Set-Location "$root_path/Scripts/"
    Import-Module "$root_path/Scripts/ca-certs.ps1" -Force
    
    New-CACertsCertChain rsa
    New-CACertsEdgeDeviceIdentity "$script:vm_name"
    New-CACertsEdgeDevice "ca-cert"
    #endregion

    #region register edge device
    $iotedge_container = "iotedgecerts"
    $root_cert_name = "azure-iot-test-only.root.ca.cert.pem"
    $root_cert_path = "$($root_path)/Scripts/certs/$($root_cert_name)"
    $iotedge_cert_name = "iot-edge-device-identity-$($script:vm_name).cert.pem"
    $iotedge_cert_path = "$($root_path)/Scripts/certs/$iotedge_cert_name"
    $iotedge_key_name = "iot-edge-device-identity-$($script:vm_name).key.pem"
    $iotedge_key_path = "$($root_path)/Scripts/private/$iotedge_key_name"
    $thumbprint = $(openssl x509 -noout -fingerprint -inform pem -sha1 -in $iotedge_cert_path).Split('=')[1].Replace(':','').Trim()

    Write-Host "Creating edge device."
    az iot hub device-identity create `
        --device-id $script:vm_name `
        --hub-name $script:iot_hub_name `
        --edge-enabled `
        --auth-method x509_thumbprint `
        --primary-thumbprint $thumbprint `
        --secondary-thumbprint $thumbprint | Out-Null

    az iot hub device-twin update `
        --device-id $script:vm_name `
        --hub-name $script:iot_hub_name `
        --tags '{ \"mqttReceiver\": true }' | Out-Null

    $storage_key = az storage account keys list `
        --account-name $script:storage_account_name `
        --resource-group $script:storage_account_resource_group `
        --query '[0].value' -o tsv
    
    az storage container create `
        --account-name $script:storage_account_name `
        --account-key $storage_key `
        --resource-group $script:storage_account_resource_group `
        --name $iotedge_container | Out-Null

    Write-Host "Uploading iot edge certificate."
    az storage blob upload `
        --account-name $script:storage_account_name `
        --account-key $storage_key `
        --container-name $iotedge_container `
        --file $iotedge_cert_path `
        --name $iotedge_cert_name | Out-Null

    $iotedge_cert_sas = az storage blob generate-sas `
        --account-name $script:storage_account_name `
        --account-key $storage_key `
        --container-name $iotedge_container `
        --name $iotedge_cert_name `
        --permissions r `
        --expiry (Get-Date -AsUTC).AddHours(1).ToString('yyyy-MM-ddTHH:mm:00Z') `
        --full-uri `
        -o tsv
    
    Write-Host "Uploading edge root certificate."
    az storage blob upload `
        --account-name $script:storage_account_name `
        --account-key $storage_key `
        --container-name $iotedge_container `
        --file $root_cert_path `
        --name $root_cert_name | Out-Null

    $root_cert_sas = az storage blob generate-sas `
        --account-name $script:storage_account_name `
        --account-key $storage_key `
        --container-name $iotedge_container `
        --name $root_cert_name `
        --permissions r `
        --expiry (Get-Date -AsUtc).AddHours(1).ToString('yyyy-MM-ddTHH:mm:00Z') `
        --full-uri `
        -o tsv
    
    Write-Host "Uploading iot edge private key."
    az storage blob upload `
        --account-name $script:storage_account_name `
        --account-key $storage_key `
        --container-name $iotedge_container `
        --file $iotedge_key_path `
        --name $iotedge_key_name | Out-Null

    $iotedge_key_sas = az storage blob generate-sas `
        --account-name $script:storage_account_name `
        --account-key $storage_key `
        --container-name $iotedge_container `
        --name $iotedge_key_name `
        --permissions r `
        --expiry (Get-Date -AsUtc).AddHours(1).ToString('yyyy-MM-ddTHH:mm:00Z') `
        --full-uri `
        -o tsv

    Write-Host "Registering iot edge device."
    $protected_settings_path = "$root_path/Scripts/vm-script.json"
    $protected_settings = @{
        "fileUris" = @(
            $iotedge_cert_sas,
            $root_cert_sas,
            $iotedge_key_sas,
            "$github_repo_url/$github_branch_name/Scripts/log-generator",
            "$github_repo_url/$github_branch_name/Scripts/edge-setup.sh",
            "$github_repo_url/$github_branch_name/Scripts/edge-setup.ps1"
        )
        "commandToExecute" = "sudo bash edge-setup.sh --iotHubHostname '$($script:iot_hub_name).azure-devices.net' --deviceId '$script:vm_name' --certName '$iotedge_cert_name' --keyName '$iotedge_key_name' --caName '$root_cert_name' --logGenFileName log-generator"
    }
    Set-Content -Value (ConvertTo-Json $protected_settings | Out-String) -Path $protected_settings_path -Force

    az vm extension set `
        --resource-group $script:iot_hub_resource_group `
        --vm-name $script:vm_name `
        --name customScript `
        --publisher Microsoft.Azure.Extensions `
        --protected-settings $protected_settings_path
    #endregion

    #region create leaf devices
    $script:leaf_devices = @()
    do {
        $leaf_device_options = @(
            "Yes",
            "No"
        )

        $leaf_device_option = Get-InputSelection `
            -options $leaf_device_options `
            -text "Do you want to create any leaf devices?"
        
        if ($leaf_device_option -eq 1) {

            $device_id = Get-IoTDeviceId
            az iot hub device-identity create `
                --device-id $device_id `
                --hub-name $script:iot_hub_name `
                --auth-method shared_private_key | Out-Null

            az iot hub device-identity parent set `
                --device-id $device_id `
                --parent-device-id $script:vm_name `
                --hub-name $script:iot_hub_name | Out-Null
            
            $device_conn_str = az iot hub device-identity connection-string show `
                --device-id $device_id `
                --hub-name $script:iot_hub_name `
                --key-type primary `
                -o tsv

            $device_sas_token = az iot hub generate-sas-token `
                --device-id $device_id `
                --hub-name $script:iot_hub_name `
                --key-type primary `
                --query 'sas' `
                -o tsv

            $script:leaf_devices += @{
                "device_id" = $device_id
                "connection_string" = $device_conn_str
                "sas_token" = $device_sas_token
            }

            Write-Host "Leaf device created."
        }
    }
    while ($leaf_device_option -eq 1)
    #endregion

    #region edge deployment
    Write-Host "`r`nCreating base IoT edge device deployment"

    Set-MqttTopicName
    $obs_module_name = "obsd"
    $base_topic_name = ($script:mqtt_topic_name).Split('/')[0]
    $deployment_schema = "1.2"
    $deployment_template_path = "$($root_path)/EdgeSolution/deployment-$($deployment_schema).template.json"
    $deployment_manifest_path = "$($root_path)/EdgeSolution/deployment-$($deployment_schema).manifest.json"

    $mqtt_broker_auth = @(
        @{
            "identities" = @( "{{iot:identity}}" )
            "allow" = @(
                @{
                    "operations" = @( "mqtt:connect" )
                }
            )
        },
        @{
            "identities" = @( "$($script:iot_hub_name).azure-devices.net/{{iot:device_id}}" )
            "allow" = @(
                @{
                    "operations" = @( "mqtt:publish" )
                    "resources"  = @( "$($script:mqtt_topic_name)/{{iot:device_id}}" )
                }
            )
        },
        @{
            "identities" = @( "$($script:iot_hub_name).azure-devices.net/{{iot:this_device_id}}/$($obs_module_name)" )
            "allow" = @(
                @{
                    "operations" = @( "mqtt:subscribe" )
                    "resources"  = @( "$($base_topic_name)/#" )
                }
            )
        }
    )
    (Get-Content -Path $deployment_template_path -Raw) | ForEach-Object {
        $_ -replace '__OBS_MODULE_NAME__', $obs_module_name `
            -replace '__MQTT_BROKER_AUTH__', (ConvertTo-Json -InputObject $mqtt_broker_auth -Depth 10 | Out-String) `
            -replace '__WORKSPACE_ID__', $script:deployment_output.properties.outputs.workspaceId.value `
            -replace '__WORKSPACE_SHARED_KEY__', $script:deployment_output.properties.outputs.workspaceSharedKey.value
    } | Set-Content -Path $deployment_manifest_path

    az iot edge deployment create `
        -d "base-deployment" `
        --hub-name $script:iot_hub_name `
        --content $deployment_manifest_path `
        --target-condition=$script:deployment_condition | Out-Null

    Write-Host "`r`nRunning log generator process."
    az vm run-command invoke `
    --resource-group $script:resource_group_name `
    --name $script:vm_name `
    --command-id RunShellScript --scripts "/app/sensor/log-generator -f 5"
    #endregion

    #region completion message
    Write-Host
    Write-Host -ForegroundColor Green "Resource Group: $($script:resource_group_name)"
    Write-Host -ForegroundColor Green "Environment unique id: $($script:env_hash)"

    if ($script:create_iot_hub) {
        Write-Host
        Write-Host -ForegroundColor Green "IoT Edge VM Details:"
        Write-Host -ForegroundColor Green "Username: $script:vm_username"
        Write-Host -ForegroundColor Green "Password: $script:vm_password"
        Write-Host -ForegroundColor Green "DNS: $($script:vm_name).$($script:iot_hub_location).cloudapp.azure.com"
        Write-Host -ForegroundColor Green "Edge root CA certificate URL: $root_cert_sas"
    }
    else {
        Write-Host
        Write-Host -ForegroundColor Green "REMINDER: Update device twin for your IoT edge devices with `"$($script:deployment_condition)`" to apply the edge configuration."
    }

    if ($script:leaf_devices.Count -gt 0) {
        Write-Host
        Write-Host -ForegroundColor Green "IoT Leaf Devices Details:"
        foreach ($device in $script:leaf_devices) {
            Write-Host
            Write-Host -ForegroundColor Green "Device Id: $($device.device_id)"
            Write-Host -ForegroundColor Green "SAS Token: $($device.sas_token)"
            Write-Host -ForegroundColor Green "Connection String: $($device.connection_string)"
        }
    }

    Write-Host
    Write-Host -ForegroundColor Green "##############################################"
    Write-Host -ForegroundColor Green "##############################################"
    Write-Host -ForegroundColor Green "####                                      ####"
    Write-Host -ForegroundColor Green "####        Deployment Succeeded          ####"
    Write-Host -ForegroundColor Green "####                                      ####"
    Write-Host -ForegroundColor Green "##############################################"
    Write-Host -ForegroundColor Green "##############################################"
    Write-Host
    #endregion
}

New-ELMSEnvironment