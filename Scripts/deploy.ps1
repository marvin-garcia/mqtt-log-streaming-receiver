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

function Get-LeafDeviceName {
    param()

    $device_name = $null
    $first = $true

    while ([string]::IsNullOrEmpty($device_name) -or ($device_cert_option -notmatch "^[a-z0-9-]*$")) {
        if ($first -eq $false) {
            Write-Host "Use alphanumeric characters as well as '-'."
        }
        else {
            Write-Host
            Write-Host "Provide a name for the leaf IoT device."
            $first = $false
        }
        $device_name = Read-Host -Prompt ">"

        return $device_name
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

    #region deployment option
    $deployment_options = @(
        "Create a sandbox environment",
        "Custom deployment"
    )

    $deployment_option = Get-InputSelection `
        -options $deployment_options `
        -text "Choose a deployment option from the list (using its Index):"
    #endregion

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

    if ($deployment_option -eq 1) {

        $script:sandbox = $true

        Set-IoTHub
        Set-Storage
        Set-LogAnalyticsWorkspace
    }

    elseif ($deployment_option -eq 2) {

        #region iot hub
        Set-IoTHub

        if (!$script:create_iot_hub) {

            #region handle IoT hub service policy
            $iot_hub_policies = az iot hub policy list --hub-name $script:iot_hub_name | ConvertFrom-Json
            $iot_hub_policy = $iot_hub_policies | Where-Object { $_.rights -like '*serviceconnect*' -and $_.rights -like '*registryread*' }

            if (!$iot_hub_policy) {
                
                $script:iot_hub_policy_name = "iotedgelogs"
                Write-Host
                Write-Host "Creating IoT hub shared access policy '$($script:iot_hub_policy_name)' with permissions 'RegistryRead ServiceConnect'."
                
                az iot hub policy create `
                    --hub-name $script:iot_hub_name `
                    --name $script:iot_hub_policy_name `
                    --permissions RegistryRead ServiceConnect
            }
            else {
                
                $script:iot_hub_policy_name = $iot_hub_policy.keyName
                Write-Host
                Write-Host "The existing IoT hub shared access policy '$($script:iot_hub_policy_name)' will be used in the deployment."
            }
            #endregion

            Write-Host
            Write-Host -ForegroundColor Yellow "IMPORTANT: You must update device twin for your IoT edge devices with `"$($script:deployment_condition)`" to collect logs from their modules."
            
            Start-Sleep -Milliseconds 1500
            
            Write-Host
            Write-Host "Press Enter to continue."
            Read-Host
        }
        #endregion

        #region storage account
        Set-Storage

        if (!$script:create_event_grid) {
            Write-Host
            Write-Host "The existing event grid system topic '$($script:event_grid_topic_name)' will be used in the deployment."
        }
        #endregion

        #region log analytics
        Set-LogAnalyticsWorkspace
        #endregion
    }
    
    #region metrics monitoring
    # if ($script:sandbox) {
    #     $script:enable_monitoring = $true
    #     $script:monitoring_mode = "IoTMessage"
    # }
    # else {
    #     $option = Get-InputSelection `
    #         -options @("Yes", "No") `
    #         -text @("In addition to logging, ELMS can enable IoT Edge monitoring with Azure Monitor. It will let you monitor your edge fleet at scale by using Azure Monitor to collect, store, visualize and generate alerts from metrics emitted by the IoT Edge runtime.", "Do you want to enable IoT Edge monitoring? Choose an option from the list (using its Index):") `
    #         -default_index 1
        
    #     if ($option -eq 1) {
    #         $script:enable_monitoring = $true
    #     }
    # }

    # region select monitoring type
    # if ($script:enable_monitoring -and $null -eq $script:monitoring_mode) {

    #     $option = Get-InputSelection `
    #         -options @("To Log Analytics", "As IoT messages") `
    #         -text @("Collected monitoring metrics can be uploaded directly to Log Analytics (requires outbound internet connectivity from the edge device(s)), or can be published as IoT messages (useful for local consumption). Metrics published as IoT messages are emitted as UTF8-encoded json from the endpoint '/messages/modules//outputs/metricOutput'.", "How should metrics be uploaded? Choose an option from the list (using its Index):")
        
    #     if ($option -eq 1) {
    #         Write-Host
    #         Write-Host -ForegroundColor Yellow "NOTE: Monitoring metrics will be sent directly from the edge to a log analytics workspace Log analytics workspace. Go to https://aka.ms/edgemon-docs to find more details."

    #         $script:monitoring_mode = "AzureMonitor"
    #         $script:create_event_hubs = $false
    #     }
    #     elseif ($option -eq 2) {
    #         Write-Host
    #         Write-Host -ForegroundColor Yellow "NOTE: Monitoring metrics will be routed from IoT hub to an event hubs instance and processed by an Azure Function."

    #         $script:monitoring_mode = "IoTMessage"
    #         $script:create_event_hubs = $true
    #     }
    # }

    $script:enable_monitoring = $false
    #endregion

    if ($script:enable_monitoring) {
        Set-EventHubsNamespace -route_condition  "id = '$metrics_collector_message_id'"
    }
    else {
        $script:create_event_hubs_namespace = $false
        $script:create_event_hubs = $false
    }
    #endregion

    #region obtain deployment location
    if ($script:create_iot_hub) {
        $locations = Get-ResourceProviderLocations -provider 'Microsoft.Devices' -typeName 'ProvisioningServices'

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
        "createIoTHub"                = @{ "value" = $script:create_iot_hub }
        "iotHubLocation"              = @{ "value" = $script:iot_hub_location }
        "iotHubName"                  = @{ "value" = $script:iot_hub_name }
        "iotHubResourceGroup"         = @{ "value" = $script:iot_hub_resource_group }
        "iotHubServicePolicyName"     = @{ "value" = $script:iot_hub_policy_name }
        "createStorageAccount"        = @{ "value" = $script:create_storage }
        "storageAccountLocation"      = @{ "value" = $script:storage_account_location }
        "storageAccountName"          = @{ "value" = $script:storage_account_name }
        "storageAccountResourceGroup" = @{ "value" = $script:storage_account_resource_group }
        "storageContainerName"        = @{ "value" = $script:storage_container_name }
        "storageQueueName"            = @{ "value" = $script:storage_queue_name }
        "createEventGridSystemTopic"  = @{ "value" = $script:create_event_grid }
        "eventGridSystemTopicName"    = @{ "value" = $script:event_grid_topic_name }
        "createWorkspace"             = @{ "value" = $script:create_workspace }
        "workspaceLocation"           = @{ "value" = $script:workspace_location }
        "workspaceName"               = @{ "value" = $script:workspace_name }
        "workspaceResourceGroup"      = @{ "value" = $script:workspace_resource_group }
        "functionAppName"             = @{ "value" = $script:function_app_name }
        "templateUrl"                 = @{ "value" = $github_repo_url }
        "branchName"                  = @{ "value" = $github_branch_name }
    }

    if ($script:create_iot_hub) {
        $template_parameters.Add("edgeVmName", @{ "value" = $script:vm_name })
        $template_parameters.Add("edgeVmSize", @{ "value" = $script:vm_size })
        $template_parameters.Add("adminUsername", @{ "value" = $script:vm_username })
        $template_parameters.Add("adminPassword", @{ "value" = $script:vm_password })
        $template_parameters.Add("vnetName", @{ "value" = $script:vnet_name })
        $template_parameters.Add("vnetAddressPrefix", @{ "value" = $script:vnet_addr_prefix })
        $template_parameters.Add("edgeSubnetName", @{ "value" = $script:subnet_name })
        $template_parameters.Add("edgeSubnetAddressRange", @{ "value" = $script:subnet_addr_prefix })
    }

    $template_parameters.Add("createEventHubsNamespace", @{ "value" = $script:create_event_hubs_namespace })
    $template_parameters.Add("createEventHubs", @{ "value" = $script:create_event_hubs })
    if ($script:create_event_hubs) {
        $template_parameters.Add("eventHubResourceGroup", @{ "value" = $script:event_hubs_resource_group })
        $template_parameters.Add("eventHubsLocation", @{ "value" = $script:event_hubs_location })
        $template_parameters.Add("eventHubsNamespace", @{ "value" = $script:event_hubs_namespace })
        $template_parameters.Add("eventHubsName", @{ "value" = $script:event_hubs_name })
        $template_parameters.Add("eventHubsEndpointName", @{ "value" = $script:event_hubs_endpoint })
        $template_parameters.Add("eventHubsRouteName", @{ "value" = $script:event_hubs_route })
        $template_parameters.Add("eventHubsRouteCondition", @{ "value" = $script:event_hubs_route_condition })
        $template_parameters.Add("eventHubsListenPolicyName", @{ "value" = $script:event_hubs_listen_rule })
        $template_parameters.Add("eventHubsSendPolicyName", @{ "value" = $script:event_hubs_send_rule })
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
    Import-Module "$root_path/Scripts/ca-certs.ps1"
    Set-Location "$root_path/Scripts/"

    New-CACertsCertChain rsa
    New-CACertsEdgeDeviceIdentity "$script:vm_name"
    New-CACertsEdgeDevice "ca-cert"
    #endregion

    #region Leaf device certificates
    $script:device_certs = @()
    do {
        $device_cert_options = @(
            "Yes",
            "No"
        )

        $device_cert_option = Get-InputSelection `
            -options $device_cert_options `
            -text "Do you want to create certificates for your leaf devices?"
        
        if ($device_cert_option -eq 1) {

            $device_name = Get-LeafDeviceName

            New-CACertsDevice "$device_name-primary"
            New-CACertsDevice "$device_name-secondary"

            $script:device_certs += @{
                "device_name" = $device_name
                "primary_cert" = @{
                    "name" = "iot-device-$device_name-primary.cert.pem"
                    "path" = "$root_path/Scripts/certs/iot-device-$device_name-primary.cert.pem"
                    "url" = ""
                }
                "primary_pk" = @{
                    "name" = "iot-device-$device_name-primary.key.pem"
                    "path" = "$root_path/Scripts/private/iot-device-$device_name-primary.key.pem"
                    "url" = ""
                }
                "secondary_cert" = @{
                    "name" = "iot-device-$device_name-secondary.cert.pem"
                    "path" = "$root_path/Scripts/certs/iot-device-$device_name-secondary.cert.pem"
                    "url" = ""
                }
                "secondary_pk" = @{
                    "name" = "iot-device-$device_name-secondary.key.pem"
                    "path" = "$root_path/Scripts/private/iot-device-$device_name-secondary.key.pem"
                    "url" = ""
                }
            }
        }
    }
    while ($device_cert_option -eq 1)
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
        --secondary-thumbprint $thumbprint

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
    $iotedge_cert_sas = [System.Web.HttpUtility]::UrlDecode($iotedge_cert_sas)
    
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
    $root_cert_sas = [System.Web.HttpUtility]::UrlDecode($root_cert_sas)

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
    $iotedge_key_sas = [System.Web.HttpUtility]::UrlDecode($iotedge_key_sas)

    if ($script:device_certs.Count -gt 0) {
        
        Write-Host "Creating leaf devices."
        foreach ($device in $script:device_certs) {

            Write-Host "Creating leaf device $($device.device_name)."
            az iot hub device-identity create `
                --device-id $($device.device_name) `
                --hub-name $script:iot_hub_name `
                --auth-method x509_thumbprint `
                --primary-thumbprint $(openssl x509 -noout -fingerprint -inform pem -sha1 -in $device.primary_cert.path).Split('=')[1].Replace(':','').Trim() `
                --secondary-thumbprint $(openssl x509 -noout -fingerprint -inform pem -sha1 -in $device.secondary_cert.path).Split('=')[1].Replace(':','').Trim()

            az iot hub device-identity parent set `
                --device-id $device.device_name `
                --parent-device-id $script:vm_name `
                --hub-name $script:iot_hub_name

            Write-Host "Uploading primary certificate for leaf device $($device.device_name)."
            az storage blob upload `
                --account-name $script:storage_account_name `
                --account-key $storage_key `
                --container-name $iotedge_container `
                --file $device.primary_cert.path `
                --name $device.primary_cert.name

            $sas = az storage blob generate-sas `
                --account-name $script:storage_account_name `
                --account-key $storage_key `
                --container-name $iotedge_container `
                --name $device.primary_cert.name `
                --permissions r `
                --expiry (Get-Date -AsUtc).AddDays(10).ToString('yyyy-MM-ddTHH:mm:00Z') `
                --full-uri `
                -o tsv

            $device.primary_cert.url = [System.Web.HttpUtility]::UrlDecode($sas)

            Write-Host "Uploading primary key for leaf device $($device.device_name)."
            az storage blob upload `
                --account-name $script:storage_account_name `
                --account-key $storage_key `
                --container-name $iotedge_container `
                --file $device.primary_pk.path `
                --name $device.primary_pk.name

            $sas = az storage blob generate-sas `
                --account-name $script:storage_account_name `
                --account-key $storage_key `
                --container-name $iotedge_container `
                --name $device.primary_pk.name `
                --permissions r `
                --expiry (Get-Date -AsUtc).AddDays(10).ToString('yyyy-MM-ddTHH:mm:00Z') `
                --full-uri `
                -o tsv

            $device.primary_pk.url = [System.Web.HttpUtility]::UrlDecode($sas)
        }
    }

    Write-Host "Registering iot edge device."
    $protected_settings_path = "$root_path/Scripts/vm-script.json"
    $protected_settings = @{
        "fileUris" = @(
            $iotedge_cert_sas,
            $root_cert_sas,
            $iotedge_key_sas,
            "$github_repo_url/$github_branch_name/Scripts/edge-setup.sh",
            "$github_repo_url/$github_branch_name/Scripts/edge-setup.ps1"
        )
        "commandToExecute" = "sudo bash edge-setup.sh --iotHubHostname '$($script:iot_hub_name).azure-devices.net' --deviceId '$script:vm_name' --certName '$iotedge_cert_name' --keyName '$iotedge_key_name' --caName '$root_cert_name'"
    }
    Set-Content -Value (ConvertTo-Json $protected_settings | Out-String) -Path $protected_settings_path -Force

    az vm extension set `
        --resource-group $script:iot_hub_resource_group `
        --vm-name $script:vm_name `
        --name customScript `
        --publisher Microsoft.Azure.Extensions `
        --protected-settings $protected_settings_path

    #endregion

    #region update azure function host key app setting
    $script:function_app_hostname = az functionapp show -g $script:resource_group_name -n $script:function_app_name --query defaultHostName -o tsv
    $script:function_key = az functionapp keys list -g $script:resource_group_name -n $script:function_app_name --query 'functionKeys.default' -o tsv

    az functionapp config appsettings set `
        --name $script:function_app_name `
        --resource-group $script:resource_group_name `
        --settings "HostUrl=https://$($script:function_app_hostname)" "HostKey=$($script:function_key)" | Out-Null
    #endregion

    #region edge deployments
    # Create main deployment
    Write-Host "`r`nCreating base IoT edge device deployment"

    $deployment_schema = "1.2"
    az iot edge deployment create `
        -d "base-deployment" `
        --hub-name $script:iot_hub_name `
        --content "$($root_path)/EdgeSolution/deployment-$($deployment_schema).manifest.json" `
        --target-condition=$script:deployment_condition | Out-Null
    #endregion

    #region function app
    # Write-Host
    # Write-Host "Deploying code to Function App $script:function_app_name"
    
    # az functionapp deployment source config-zip -g $script:resource_group_name -n $script:function_app_name --src $script:zip_package_path | Out-Null

    # if (!$script:create_event_hubs) {

    #     az functionapp config appsettings set --resource-group $script:resource_group_name --name $script:function_app_name --settings "AzureWebJobs.CollectMetrics.Disabled=true" | Out-Null
    # }
    # #endregion

    # #region notify of monitoring deployment steps
    # if (!$script:create_iot_hub -and $script:enable_monitoring) {
        
    #     #region create custom endpoint and message route
    #     if ($script:monitoring_mode -eq "IoTMessage") {
    #         Write-Host
    #         Write-Host "Creating IoT hub routing endpoint"

    #         $script:iot_hub_endpoint_name = "metricscollector-$($script:env_hash)"
    #         $script:iot_hub_route_name = "metricscollector-$($script:env_hash)"
    #         $eh_conn_string = "Endpoint=sb://$($script:deployment_output.properties.outputs.eventHubsNamespaceEndpoint.value);SharedAccessKeyName=$($script:event_hubs_send_rule);SharedAccessKey=$($script:deployment_output.properties.outputs.eventHubsSendKey.value);EntityPath=$($script:event_hubs_name)"

    #         az iot hub routing-endpoint create `
    #             --resource-group $script:iot_hub_resource_group `
    #             --hub-name $script:iot_hub_name `
    #             --endpoint-type eventhub `
    #             --endpoint-name $script:iot_hub_endpoint_name `
    #             --endpoint-resource-group $script:resource_group_name `
    #             --endpoint-subscription-id $(az account show --query id -o tsv) `
    #             --connection-string $eh_conn_string | ConvertFrom-Json | Out-Null

    #         Write-Host
    #         Write-Host "Creating IoT hub route"

    #         az iot hub route create `
    #             --resource-group $script:iot_hub_resource_group `
    #             --hub-name $script:iot_hub_name `
    #             --endpoint-name $script:iot_hub_endpoint_name `
    #             --source-type DeviceMessages `
    #             --route-name $script:iot_hub_route_name `
    #             --condition $event_hubs_route_condition `
    #             --enabled true | ConvertFrom-Json | Out-Null
    #     }
    #     #endregion

    #     Write-Host
    #     Write-Host -ForegroundColor Yellow "IMPORTANT: To start collecting metrics for your edge devices, you must create an IoT edge deployment with the Azure Monitor module. You can use the deployment manifest below on IoT hub '$($script:iot_hub_name)'."

    #     Write-Host
    #     Write-Host -ForegroundColor Yellow $(Get-Content $monitoring_manifest) -Separator "`r`n"

    #     Write-Host
    #     Write-Host -ForegroundColor Yellow "Go to https://aka.ms/edgemon-docs for more details."
    # }
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

    }
    else {
        Write-Host
        Write-Host -ForegroundColor Green "REMINDER: Update device twin for your IoT edge devices with `"$($script:deployment_condition)`" to apply the edge configuration."
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