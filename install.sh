#!/bin/bash
# visionStack Installer v1.3
set -e

echo "Initializing visionStack Deployment..."

# 1. Prerequisite Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)." 
   exit 1
fi

# 1.5 Install Dependencies
if ! [ -x "$(command -v docker)" ]; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
fi

if ! docker compose version &> /dev/null && ! docker-compose version &> /dev/null; then
    echo "Installing Docker-Compose..."
    sudo apt-get update && sudo apt-get install -y docker-compose-plugin docker-compose
fi

# 2. System Optimization
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 3. Directory Preparation
mkdir -p ./data/{netbox,zabbix,graylog,grafana,prometheus,oxidized}
chmod -R 775 ./data

# 4. Setup Wizard
read -p "Enter your Host IP Address: " HOST_IP
read -p "Enter a Master Password for DBs: " MASTER_PWD

# 5. Generate Graylog Secrets
export GRAYLOG_ROOT_PASSWORD_SHA2=$(echo -n "$MASTER_PWD" | sha256sum | awk '{print $1}')
export GRAYLOG_PASSWORD_SECRET=$(openssl rand -base64 32)

# 6. Launch the Stack
echo "Deploying containers..."
export MASTER_PWD=$MASTER_PWD
export HOST_IP=$HOST_IP
export GRAYLOG_ROOT_PASSWORD_SHA2=$GRAYLOG_ROOT_PASSWORD_SHA2
export GRAYLOG_PASSWORD_SECRET=$GRAYLOG_PASSWORD_SECRET

docker compose up -d || docker-compose up -d

# 7. Post-Deployment Integration & Health Check
echo -n "Waking up APIs (Waiting for migrations)..."
TIMEOUT=0
while ! curl -s --head --request GET http://localhost:8010 | grep "200 OK" > /dev/null; do
    echo -n "."
    sleep 3
    ((TIMEOUT++))
    if [ $TIMEOUT -gt 20 ]; then break; fi
done
echo " Online!"

# --- Netbox Integration ---
NETBOX_TOKEN=$(openssl rand -hex 20)
echo "Generating Netbox API Token..."
docker exec vision-netbox python3 manage.py create_token --user admin --token $NETBOX_TOKEN > /dev/null

# --- Oxidized Integration ---
echo "Configuring Oxidized..."
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
echo "Connecting Grafana to Prometheus..."
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
echo "Zabbix (Web):    http://$HOST_IP:8030 | User: Admin / Pass: zabbix"
echo "Graylog:         http://$HOST_IP:8040 | User: admin / Pass: $MASTER_PWD"
echo "Grafana:         http://$HOST_IP:8050 | User: admin / Pass: admin"
echo "Prometheus:      http://$HOST_IP:8060 | No Auth"
echo "ntopng:          http://$HOST_IP:8070 | User: admin / Pass: admin"
echo "Oxidized:        http://$HOST_IP:8080 | No Auth"
echo "------------------------------------------------"
echo "INTEGRATION COMPLETE"
echo "Netbox API Token: $NETBOX_TOKEN"
echo "------------------------------------------------"
