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
# We create Oxidized config folder early so it doesn't crash on boot
mkdir -p ./data/{netbox,zabbix,graylog,grafana,prometheus,oxidized}
chmod -R 775 ./data

# 4. Setup Wizard
read -p "Enter your Host IP Address: " HOST_IP
read -p "Enter a Master Password for DBs: " MASTER_PWD

# 5. Launch the Stack
echo "Deploying containers..."
export MASTER_PWD=$MASTER_PWD
export HOST_IP=$HOST_IP
docker-compose up -d

# 6. Post-Deployment Integration (Handshaking)
echo "Waking up APIs (Waiting 45s for database migrations)..."
sleep 45

# --- Netbox Integration ---
NETBOX_TOKEN=$(openssl rand -hex 20)
echo "Generating Netbox API Token..."
docker exec vision-netbox python3 manage.py create_token --user admin --token $NETBOX_TOKEN > /dev/null

# --- Oxidized Integration ---
# Ensure no spaces exist after the final EOF below
echo "Configuring Oxidized to track Netbox inventory..."
cat <<EOF > ./data/oxidized/config
---
username: admin
password: $MASTER_PWD
model: ios
interval: 3600
use_syslog: false
debug: false
type: git
source:
  default: http
  http:
    url: http://vision-netbox:8080/api/dcim/devices/
    map:
      name: name
      model: device_type.model.slug
    headers:
      Authorization: "Token $NETBOX_TOKEN"
EOF

# --- Grafana Integration ---
echo "Connecting Grafana to Prometheus telemetry..."
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"Prometheus","type":"prometheus","url":"http://vision-prometheus:9090","access":"proxy"}' \
  http://admin:admin@localhost:8050/api/datasources > /dev/null

# --- Final Credential Print ---
echo "------------------------------------------------"
echo "visionStack is now LIVE!"
echo "------------------------------------------------"
echo "NetClaw (Host):  http://$HOST_IP:8000 | User: root / Pass: (System)"
echo "Portainer:       http://$HOST_IP:8010 | User: admin / Pass: $MASTER_PWD"
echo "Netbox:          http://$HOST_IP:8020 | User: admin / Pass: $MASTER_PWD"
echo "Zabbix:          http://$HOST_IP:8030 | User: Admin / Pass: zabbix"
echo "Graylog:         http://$HOST_IP:8040 | User: admin / Pass: admin"
echo "Grafana:         http://$HOST_IP:8050 | User: admin / Pass: admin"
echo "Prometheus:      http://$HOST_IP:8060 | No Auth by Default"
echo "ntopng:          http://$HOST_IP:8070 | User: admin / Pass: admin"
echo "Oxidized:        http://$HOST_IP:8080 | No Auth (Internal Only)"
echo "------------------------------------------------"
echo "INTEGRATION COMPLETE"
echo "Netbox API Token: $NETBOX_TOKEN"
echo "DB Master Pass:   $MASTER_PWD"
echo "------------------------------------------------"
echo "NOTE: Log in to Zabbix/Graylog/Grafana and change"
echo "default passwords to your Master Password immediately."
echo "------------------------------------------------"
