# MQTT Receiver for Log Streaming

## Pre-requisites
In order to successfully deploy this solution, you will need the following:

- [PowerShell 7](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell?view=powershell-7.1).
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) version 2.21 or later.
- An Azure account with an active subscription. [Create one for free](https://azure.microsoft.com/free/?ref=microsoft.com&utm_source=microsoft.com&utm_medium=docs&utm_campaign=visualstudio).

## How to use
1. Go to [Azure Cloud Shell](https://shell.azure.com) and start a PowerShell session, or open PowerShell 7 on your computer.
2. Clone the repo:
    ```powershell
    git clone https://github.com/marvin-garcia/mqtt-log-streaming-receiver.git
    ```
3. Run the code below:
    ```powershell
    cd mqtt-log-streaming-receiver
    .\Scripts\deploy.ps1
    ```
4. Follow the wizard instructions

## Deployment Wizard
The deployment wizard will guide you through a set of questions that will help you deploy your environment. You can choose between a sandbox environment that will deploy everything by default, or a custom deployment that will let you select existing resources for IoT Hub, Log Analytics Workspace, etc. When the deployment is complete, you will see an output similar to the sample below:

```
Resource Group: iot-hack-rg
Environment unique id: a8854c3d

IoT Edge VM Details:
Username: azureuser
Password: ********
DNS: iotedgevm-a8854c3d.westus.cloudapp.azure.com

##############################################
##############################################
####                                      ####
####        Deployment Succeeded          ####
####                                      ####
##############################################
##############################################
```

You cann connect via SSH to the IoT Edge VM:
```powershell
ssh azureuser@<iot-edge-vm-dns>