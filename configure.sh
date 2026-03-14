#!/bin/bash
# visionstack Configuration Engine
set -e

echo "Initializing visionstack API Integrations..."

# Load exact credentials from deployment footprint
if [ ! -f "./visionstack_credentials.txt" ]; then
    echo "ERROR: visionstack_credentials.txt not found!"
    echo "Please ensure the stack is deployed successfully using install.sh first."
    exit 1
fi

echo "Loading Master Credentials..."
export MASTER_PWD=$(grep -m 1 "Master Password:" ./visionstack_credentials.txt | awk '{print $3}')
export GRAYLOG_PASSWORD_SECRET=$(grep -m 1 "Graylog Secret:" ./visionstack_credentials.txt | awk '{print $3}')
export NETBOX_SECRET_KEY=$(grep -m 1 "Netbox Secret Key:" ./visionstack_credentials.txt | awk '{print $4}')
export NETBOX_TOKEN=$(grep -m 1 "Netbox API Token:" ./visionstack_credentials.txt | awk '{print $4}')
export HOST_IP=$(grep -m 1 "Host IP (Detected):" ./visionstack_credentials.txt | awk '{print $4}')

# 7. Post-Deployment Integration
echo -n "Waking up APIs (Waiting for migrations)..."
TIMEOUT=0
while ! curl -s --request GET http://localhost:8010 > /dev/null; do
    echo -n "."
    sleep 3
    TIMEOUT=$((TIMEOUT + 1))
    if [ $TIMEOUT -gt 20 ]; then break; fi
done
echo " Online!"

echo "Configuring Portainer Admin User..."
curl -s --request POST 'http://localhost:8010/api/users/admin/init' \
  --header 'Content-Type: application/json' \
  --data "{\"Username\":\"admin\",\"Password\":\"$MASTER_PWD\"}" > /dev/null

# --- Zabbix Integration ---
echo "Configuring Zabbix Agent Registration..."
ZBX_TOKEN=$(curl -s --request POST 'http://localhost:8030/api_jsonrpc.php' \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc": "2.0", "method": "user.login", "params": {"username": "Admin", "password": "zabbix"}, "id": 1}' | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')

if [ -n "$ZBX_TOKEN" ]; then
    echo "Resolving internal Zabbix Entity IDs dynamically..."
    ZBX_SERVER_ID=$(curl -s --request POST 'http://localhost:8030/api_jsonrpc.php' \
      --header 'Content-Type: application/json' \
      --data "{\"jsonrpc\": \"2.0\", \"method\": \"host.get\", \"params\": {\"filter\": {\"host\": [\"Zabbix server\"]}}, \"auth\": \"$ZBX_TOKEN\", \"id\": 1}" | grep -oP '(?<="hostid":")[^"]+')

    ZBX_DOCKER_TPL_ID=$(curl -s --request POST 'http://localhost:8030/api_jsonrpc.php' \
      --header 'Content-Type: application/json' \
      --data "{\"jsonrpc\": \"2.0\", \"method\": \"template.get\", \"params\": {\"filter\": {\"host\": [\"Docker by Zabbix agent 2\"]}}, \"auth\": \"$ZBX_TOKEN\", \"id\": 1}" | grep -oP '(?<="templateid":")[^"]+')

    ZBX_INTERFACE_ID=$(curl -s --request POST 'http://localhost:8030/api_jsonrpc.php' \
      --header 'Content-Type: application/json' \
      --data "{\"jsonrpc\": \"2.0\", \"method\": \"hostinterface.get\", \"params\": {\"hostids\": \"$ZBX_SERVER_ID\"}, \"auth\": \"$ZBX_TOKEN\", \"id\": 1}" | grep -oP '(?<="interfaceid":")[^"]+' | head -n 1)

    # 1. Update default agent DNS interface
    curl -s --request POST 'http://localhost:8030/api_jsonrpc.php' \
      --header 'Content-Type: application/json' \
      --data "{\"jsonrpc\": \"2.0\", \"method\": \"hostinterface.update\", \"params\": {\"interfaceid\": \"$ZBX_INTERFACE_ID\", \"dns\": \"visionstack-zabbix-agent\", \"useip\": 0}, \"auth\": \"$ZBX_TOKEN\", \"id\": 2}" > /dev/null
      
    # 2. Attach 'Docker by Zabbix agent 2' template
    curl -s --request POST 'http://localhost:8030/api_jsonrpc.php' \
      --header 'Content-Type: application/json' \
      --data "{\"jsonrpc\": \"2.0\", \"method\": \"template.massadd\", \"params\": {\"templates\": [{\"templateid\": \"$ZBX_DOCKER_TPL_ID\"}], \"hosts\": [{\"hostid\": \"$ZBX_SERVER_ID\"}]}, \"auth\": \"$ZBX_TOKEN\", \"id\": 3}" > /dev/null

    # 3. Create HTTP Tracking for Container GUIs
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\": \"2.0\", \"method\": \"httptest.create\", \"params\": { \"name\": \"VisionStack Web GUIs\", \"hostid\": \"$ZBX_SERVER_ID\", \"steps\": [ { \"name\": \"Portainer\", \"url\": \"http://visionstack-portainer:9000\", \"status_codes\": \"200\", \"no\": 1 }, { \"name\": \"Netbox\", \"url\": \"http://visionstack-netbox:8080/login/\", \"status_codes\": \"200\", \"no\": 2 }, { \"name\": \"Grafana\", \"url\": \"http://visionstack-grafana:3000/api/health\", \"status_codes\": \"200\", \"no\": 3 }, { \"name\": \"Zabbix Web\", \"url\": \"http://visionstack-zabbix-web:8080/ping\", \"status_codes\": \"200\", \"no\": 4 }, { \"name\": \"ntopng\", \"url\": \"http://visionstack-ntopng:3000\", \"status_codes\": \"200,302\", \"no\": 5 } ] }, \"auth\": \"$ZBX_TOKEN\", \"id\": 4}" \
      http://localhost:8030/api_jsonrpc.php > /dev/null
fi

# --- Netbox Integration ---
echo -n "Running Netbox Database Migrations (This takes ~2-6.5 minutes) "
# Start background migration
docker exec -i visionstack-netbox /opt/netbox/netbox/manage.py migrate --no-input > /dev/null 2>&1 &
MIGRATE_PID=$!

# Spinner animation while migration runs
SPIN='-\|/'
i=0
while kill -0 $MIGRATE_PID 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\b${SPIN:$i:1}"
    sleep 0.1
done
printf "\bDone!\n"

echo -n "Waiting for Netbox Web UI to come online (This can take ~6.5min) "
TIMEOUT=0
while true; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://localhost:8020 || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
        break
    fi
    for _ in {1..50}; do
        i=$(( (i+1) %4 ))
        printf "\b${SPIN:$i:1}"
        sleep 0.1
    done
    TIMEOUT=$((TIMEOUT + 1))
    if [ $TIMEOUT -gt 180 ]; then
        echo -e "\bTimeout!"
        break
    fi
done
echo -e "\bOnline!"

echo "Generating Netbox Admin User and Auto-Discovering Containers..."
CONTAINERS=$(docker ps --format '{{.Names}}')

docker exec -i visionstack-netbox python3 manage.py shell <<EOF
import sys
from django.contrib.auth import get_user_model
from users.models import Token
from virtualization.models import ClusterType, Cluster, VirtualMachine
from dcim.models import DeviceRole

# Configure Admin Auth
User = get_user_model()
user, created = User.objects.get_or_create(username='admin')
user.is_superuser = True
user.is_staff = True
user.set_password('$MASTER_PWD')
user.save()
Token.objects.filter(user=user).delete()
Token.objects.create(user=user, key='$NETBOX_TOKEN')

# Auto-Discover and Document Docker Containers
try:
    cluster_type, _ = ClusterType.objects.get_or_create(name='Docker Engine', defaults={'slug': 'docker-engine'})
    cluster, _ = Cluster.objects.get_or_create(name='VisionStack Host', defaults={'type': cluster_type})
    role, _ = DeviceRole.objects.get_or_create(name='Docker Container', defaults={'slug': 'docker-container', 'color': '00bcd4'})

    raw_containers = """$CONTAINERS""".split('\n')
    for name in raw_containers:
        name = name.strip()
        if name:
            VirtualMachine.objects.get_or_create(name=name, defaults={'cluster': cluster, 'role': role, 'status': 'active'})
except Exception as e:
    print(f"Container Discovery Error: {e}")
EOF

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
    url: http://visionstack-netbox:8080/api/dcim/devices/
    map:
      name: name
      model: device_type.model.slug
    headers:
      Authorization: "Token $NETBOX_TOKEN"
EOF

# --- Grafana Integration ---
echo "Connecting Grafana to Prometheus and Backend Databases..."

curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"Prometheus","type":"prometheus","url":"http://visionstack-prometheus:9090","access":"proxy"}' \
  http://admin:admin@localhost:8050/api/datasources > /dev/null

curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"PostgreSQL (Netbox)\",\"type\":\"postgres\",\"url\":\"visionstack-postgres-netbox:5432\",\"access\":\"proxy\",\"database\":\"netbox\",\"user\":\"netbox\",\"secureJsonData\":{\"password\":\"$MASTER_PWD\"},\"jsonData\":{\"sslmode\":\"disable\",\"postgresVersion\":15}}" \
  http://admin:admin@localhost:8050/api/datasources > /dev/null

curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"PostgreSQL (Zabbix)\",\"type\":\"postgres\",\"url\":\"visionstack-postgres-zabbix:5432\",\"access\":\"proxy\",\"database\":\"zabbix\",\"user\":\"zabbix\",\"secureJsonData\":{\"password\":\"$MASTER_PWD\"},\"jsonData\":{\"sslmode\":\"disable\",\"postgresVersion\":15}}" \
  http://admin:admin@localhost:8050/api/datasources > /dev/null

curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"OpenSearch (Graylog)","type":"elasticsearch","url":"http://visionstack-opensearch:9200","access":"proxy","database":"[graylog_deflector]","jsonData":{"esVersion":"7.10.0","timeField":"timestamp","tlsSkipVerify":true}}' \
  http://admin:admin@localhost:8050/api/datasources > /dev/null

# Requires plugins from GF_INSTALL_PLUGINS
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"Zabbix","type":"alexanderzobnin-zabbix-datasource","url":"http://visionstack-zabbix-web:8080/api_jsonrpc.php","access":"proxy","jsonData":{"username":"Admin","zabbixVersion":70},"secureJsonData":{"password":"zabbix"}}' \
  http://admin:admin@localhost:8050/api/datasources > /dev/null

curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"Redis","type":"redis-datasource","url":"redis://visionstack-redis:6379","access":"proxy"}' \
  http://admin:admin@localhost:8050/api/datasources > /dev/null

# --- Netbox Bootstrap & Service Registration ---
echo "Bootstrapping Netbox Inventory via API..."

# 1. Create the visionstack Site
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "visionstack", "slug": "visionstack"}' \
  http://localhost:8020/api/dcim/sites/ > /dev/null

# 2. Create Manufacturer (visionstack)
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "visionstack", "slug": "visionstack"}' \
  http://localhost:8020/api/dcim/manufacturers/ > /dev/null

# 3. Create Device Role (Infrastructure)
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "Infrastructure", "slug": "infrastructure", "color": "4caf50"}' \
  http://localhost:8020/api/dcim/device-roles/ > /dev/null

# 4. Create Device Type (Docker Container & Baremetal Server)
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"manufacturer": {"slug": "visionstack"}, "model": "Docker Container", "slug": "docker-container"}' \
  http://localhost:8020/api/dcim/device-types/ > /dev/null

curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{"manufacturer": {"slug": "visionstack"}, "model": "Baremetal Server", "slug": "baremetal-server"}' \
  http://localhost:8020/api/dcim/device-types/ > /dev/null

# 5. Register Baremetal Host Server
echo "Registering Host Engine in Netbox..."
curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "name": "VisionStack Host Server",
    "device_type": {"slug": "baremetal-server"},
    "site": {"slug": "visionstack"},
    "status": "active",
    "role": {"slug": "infrastructure"}
  }' \
  http://localhost:8020/api/dcim/devices/ > /dev/null

# 6. Register Application Services
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
            {\"macro\": \"{\$NETBOX.URL}\", \"value\": \"http://visionstack-netbox:8080/api\"},
            {\"macro\": \"{\$NETBOX.TOKEN}\", \"value\": \"$NETBOX_TOKEN\"},
            {\"macro\": \"{\$NETBOX.FILTER}\", \"value\": \"site=visionstack\"}
        ]
    },
    \"id\": 1
  }" http://localhost:8030/api_jsonrpc.php > /dev/null

echo "Integration Complete. Zabbix is now monitoring the Netbox Inventory."

# --- Graylog API Bootstrap (Automated Inputs) ---
echo "Configuring Graylog Inputs (GELF & Syslog)..."

# 1. Create GELF UDP Input (Port 12201)
curl -s -u admin:$MASTER_PWD -X POST -H "Content-Type: application/json" -H "X-Requested-By: visionstack" \
  -d '{"title":"Docker GELF","type":"org.graylog2.inputs.gelf.udp.GELFUDPInput","configuration":{"bind_address":"0.0.0.0","port":12201,"recv_buffer_size":1048576},"global":true}' \
  http://localhost:8040/api/system/inputs > /dev/null

# 2. Create Syslog UDP Input (Port 1514)
curl -s -u admin:$MASTER_PWD -X POST -H "Content-Type: application/json" -H "X-Requested-By: visionstack" \
  -d '{"title":"Network Syslog","type":"org.graylog2.inputs.syslog.udp.SyslogUDPInput","configuration":{"bind_address":"0.0.0.0","port":1514,"recv_buffer_size":1048576,"force_rdns":false},"global":true}' \
  http://localhost:8040/api/system/inputs > /dev/null

echo "Graylog is now listening on UDP 514 (Syslog) and UDP 12201 (GELF)."
echo "Setup Complete. visionstack APIs are fully autonomous and integrated."
