#!/bin/bash
# visionStack Installer v1.4
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

# 2. System Optimization & Log Rotation (Optimized for 200GB)
echo "Configuring System & Docker Log Rotation..."
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker

# 2.5 Add Weekly Cleanup Cron Job (Set and Forget)
echo "Adding weekly maintenance schedule..."
(crontab -l 2>/dev/null; echo "0 0 * * 0 docker system prune -af --volumes > /dev/null 2>&1") | crontab -

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

# 7. Post-Deployment Integration
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
echo "NetClaw (Host):  http://$HOST_IP:8000"
echo "Portainer:       http://$HOST_IP:8010 | admin / $MASTER_PWD"
echo "Netbox:          http://$HOST_IP:8020 | admin / $MASTER_PWD"
echo "Zabbix (Web):    http://$HOST_IP:8030 | Admin / zabbix"
echo "Graylog:         http://$HOST_IP:8040 | admin / $MASTER_PWD"
echo "Grafana:         http://$HOST_IP:8050 | admin / admin"
echo "ntopng:          http://$HOST_IP:8070 | admin / admin"
echo "------------------------------------------------"
echo "INTEGRATION COMPLETE"
echo "Netbox API Token: $NETBOX_TOKEN"
echo "------------------------------------------------"

# --- Netbox Bootstrap & Service Registration ---
echo "Bootstrapping Netbox Inventory via API..."

# 1. Create the visionStack Site
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "visionStack", "slug": "visionstack"}' \
  http://localhost:8020/api/dcim/sites/ > /dev/null

# 2. Create Manufacturer (visionStack)
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "visionStack", "slug": "visionstack"}' \
  http://localhost:8020/api/dcim/manufacturers/ > /dev/null

# 3. Create Device Role (Infrastructure)
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "Infrastructure", "slug": "infrastructure", "color": "4caf50"}' \
  http://localhost:8020/api/dcim/device-roles/ > /dev/null

# 4. Create Device Type (Docker Container)
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"manufacturer": {"slug": "visionstack"}, "model": "Docker Container", "slug": "docker-container"}' \
  http://localhost:8020/api/dcim/device-types/ > /dev/null

# 5. Register Services
SERVICES=("Portainer" "Netbox" "Zabbix" "Graylog" "Grafana" "Prometheus" "ntopng" "Oxidized")
for SERVICE in "${SERVICES[@]}"; do
  echo "Registering $SERVICE in Netbox..."
  curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$SERVICE\",
      \"device_type\": {\"slug\": \"docker-container\"},
      \"site\": {\"slug\": \"visionstack\"},
      \"status\": \"active\",
      \"role\": {\"slug\": \"infrastructure\"}
    }" \
    http://localhost:8020/api/dcim/devices/ > /dev/null
done

# --- Zabbix-Netbox Sync Configuration ---
echo "Linking Zabbix to Netbox API..."

# 1. Get the Host ID and the Template ID for "Netbox by HTTP"
ZABBIX_HOST_ID=$(curl -s -X POST -H "Content-Type: application/json-rpc" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"Zabbix server\"]}},\"id\":1}" \
  http://localhost:8030/api_jsonrpc.php | grep -oP '(?<="hostid":")[^"]+')

TEMPLATE_ID=$(curl -s -X POST -H "Content-Type: application/json-rpc" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"template.get\",\"params\":{\"filter\":{\"host\":[\"Netbox by HTTP\"]}},\"id\":1}" \
  http://localhost:8030/api_jsonrpc.php | grep -oP '(?<="templateid":")[^"]+')

# 2. Update the Host with Macros AND link the Template
curl -s -X POST -H "Content-Type: application/json-rpc" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"method\": \"host.update\",
    \"params\": {
        \"hostid\": \"$ZABBIX_HOST_ID\",
        \"templates\": [{\"templateid\": \"$TEMPLATE_ID\"}],
        \"macros\": [
            {\"macro\": \"{\$NETBOX.URL}\", \"value\": \"http://vision-netbox:8080/api\"},
            {\"macro\": \"{\$NETBOX.TOKEN}\", \"value\": \"$NETBOX_TOKEN\"},
            {\"macro\": \"{\$NETBOX.FILTER}\", \"value\": \"site=visionstack\"}
        ]
    },
    \"id\": 1
  }" http://localhost:8030/api_jsonrpc.php > /dev/null

echo "Integration Complete. Zabbix is now monitoring the Netbox Inventory."
