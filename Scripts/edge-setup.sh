#!/bin/bash -e

while [ "$#" -gt 0 ]; do
    case "$1" in
        --iotHubHostname)                  iotHubHostname="$2" ;;
        --deviceId)                        deviceId="$2" ;;
        --certName)                        certName="$2" ;;
        --keyName)                         keyName="$2" ;;
        --caName)                          caName="$2" ;;
    esac
    shift
done

curdir="$( cd "$(dirname "$0")" ; pwd -P )"
certdir="/usr/local/share/ca-certificates"

echo "In $curdir..."
echo "Prepare machine..."
DEBIAN_FRONTEND=noninteractive

# install powershell and aziot-edge
wget https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb

apt-get update
apt-get install -y --no-install-recommends powershell
echo "Powershell installed."

apt-get install -y ca-certificates
apt-get install -y moby-engine
apt-get install -y aziot-edge
echo "iotedge installed."

echo "Installing CA root certificate..."
cp $caName $certdir
cp $certName $certdir
cp $keyName $certdir
update-ca-certificates
echo "certificates installed."

echo "Provisioning iotedge..."
sleep 3
pwsh -File $curdir/edge-setup.ps1 -iotHubHostname $iotHubHostname -deviceId $deviceId -certName "$certdir/$certName" -keyName "$certdir/$keyName"
echo "iotedge provisioned."

echo "Restarting iotedge runtime..."
sleep 3
iotedge config apply
iotedge system status
echo "Iotedge running."