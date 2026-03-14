#!/bin/bash
# visionStack Installer v1.0
set -e

echo "Initializing visionStack Deployment..."

# 1. Prerequisite Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)." 
   exit 1
fi

# 2. System Optimization for Graylog/OpenSearch
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 3. Directory Preparation
mkdir -p ./data/{netbox,zabbix,graylog,grafana,prometheus,oxidized}
chmod -R 775 ./data

# 4. Setup Wizard (Optional Variables)
read -p "Enter your Host IP Address: " HOST_IP
read -p "Enter a Master Password for DBs: " MASTER_PWD

# 5. Launch the Stack
echo "Deploying containers..."
export MASTER_PWD=$MASTER_PWD
export HOST_IP=$HOST_IP
docker-compose up -d

echo "------------------------------------------------"
echo "visionStack is now LIVE!"
echo "NetClaw (Host):  http://$HOST_IP:8000"
echo "Portainer:       http://$HOST_IP:8010"
echo "Netbox:          http://$HOST_IP:8020"
echo "Zabbix:          http://$HOST_IP:8030"
echo "Graylog:         http://$HOST_IP:8040"
echo "Grafana:         http://$HOST_IP:8050"
echo "Prometheus:      http://$HOST_IP:8060"
echo "ntopng:          http://$HOST_IP:8070"
echo "Oxidized:        http://$HOST_IP:8080"
echo "------------------------------------------------"
