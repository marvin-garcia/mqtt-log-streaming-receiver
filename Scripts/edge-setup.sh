#!/bin/bash -e

while [ "$#" -gt 0 ]; do
    case "$1" in
        --iotHubHostname)                  iotHubHostname="$2" ;;
        --deviceId)                        deviceId="$2" ;;
        --certName)                        certName="$2" ;;
        --keyName)                         keyName="$2" ;;
        --caName)                          caName="$2" ;;
        --logGenFileName)                  logGenFileName="$2" ;;
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
cp $caName "$certdir/$caName.crt"
cp $certName "$certdir/$certName.crt"
cp $keyName "$certdir/$keyName.crt"
update-ca-certificates
chmod 644 $certdir/*crt
echo "certificates installed."

echo "Initializing iotedge config file..."
sleep 3
file="/etc/aziot/config.toml"

echo "" > $file
echo "######################################################################" >> $file
echo "# Manual x.509 cert provisioning configuration - added by edge-setup #" >> $file
echo "######################################################################" >> $file
echo "[provisioning]" >> $file
echo "source = \"manual\"" >> $file
echo "iothub_hostname = \"$iotHubHostname\"" >> $file
echo "device_id = \"$deviceId\"" >> $file
echo "[provisioning.authentication]" >> $file
echo "method = \"x509\"" >> $file
echo "identity_cert = \"file://$certdir/$certName.crt\"" >> $file
echo "identity_pk = \"file://$certdir/$keyName.crt\"" >> $file
echo "trust_bundle_cert = \"file://$certdir/$caName.crt\"" >> $file
echo "########################################################################" >> $file

echo "iotedge provisioned."

echo "Restarting iotedge runtime..."
sleep 3
iotedge config apply
iotedge system status
echo "Iotedge running."

echo "Creating sensor directory..."
mkdir -p /app/sensor/log
chmod -R 777 /app/sensor/
echo "Sensor directory created."

echo "Moving log generator script..."
cp $logGenFileName /app/sensor/
echo "Log generator script moved."