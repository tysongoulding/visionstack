#!/bin/bash
# visionstack Configuration Engine
set -e

# ==========================================
# UI & LOGGING FRAMEWORK
# ==========================================
C_DEFAULT='\033[0m'
C_BLUE='\033[1;34m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_MAGENTA='\033[1;35m'

log_info() { echo -e "${C_BLUE}[INFO]${C_DEFAULT} $1"; }
log_succ() { echo -e "${C_GREEN}[ OK ]${C_DEFAULT} $1"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_DEFAULT} $1"; }
log_err()  { echo -e "${C_RED}[ERR!]${C_DEFAULT} $1"; }
log_step() { echo -e "\n${C_MAGENTA}===>${C_DEFAULT} ${C_CYAN}$1${C_DEFAULT}"; }

TOTAL_STEPS=7
CURRENT_STEP=0

draw_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    let _progress=(${CURRENT_STEP}*100/${TOTAL_STEPS}*100)/100
    let _done=(${_progress}*4)/10
    let _left=40-$_done
    _fill=$(printf "%${_done}s")
    _empty=$(printf "%${_left}s")
    printf "\r${C_BLUE}[${C_GREEN}${_fill// /#}${C_DEFAULT}${_empty// /-}${C_BLUE}] ${_progress}%%${C_DEFAULT} - %-40s" "$1"
}

# ==========================================
# ENV & CREDENTIALS
# ==========================================

if [ ! -f "./visionstack_credentials.txt" ]; then
    log_err "visionstack_credentials.txt not found!"
    log_info "Please ensure the stack is deployed successfully using install.sh first."
    exit 1
fi

log_info "Loading Master Credentials..."
export MASTER_PWD=$(grep -m 1 "Master Password:" ./visionstack_credentials.txt | awk '{print $3}')
export GRAYLOG_PASSWORD_SECRET=$(grep -m 1 "Graylog Secret:" ./visionstack_credentials.txt | awk '{print $3}')
export NETBOX_SECRET_KEY=$(grep -m 1 "Netbox Secret Key:" ./visionstack_credentials.txt | awk '{print $4}')
export NETBOX_TOKEN=$(grep -m 1 "Netbox API Token:" ./visionstack_credentials.txt | awk '{print $4}')
export VISION_READ_PWD=$(grep -m 1 "vision-read Pass:" ./visionstack_credentials.txt | awk '{print $3}')
export VISION_WRITE_PWD=$(grep -m 1 "vision-write Pass:" ./visionstack_credentials.txt | awk '{print $3}')
export VISION_READ_TOKEN=$(grep -m 1 "vision-read App Token:" ./visionstack_credentials.txt | awk '{print $4}')
export VISION_WRITE_TOKEN=$(grep -m 1 "vision-write App Token:" ./visionstack_credentials.txt | awk '{print $4}')
export HOST_IP=$(grep -m 1 "Host IP (Detected):" ./visionstack_credentials.txt | awk '{print $4}')

# ==========================================
# GLOBAL API ENDPOINTS
# ==========================================
PORTAINER_API="http://localhost:8010/api"
NETBOX_API="http://localhost:8020/api"
ZABBIX_API="http://localhost:8030/api_jsonrpc.php"
GRAYLOG_API="http://localhost:8040/api"
GRAFANA_API="http://localhost:8050/api"

# ==========================================
# HELPER FUNCTIONS
# ==========================================
wait_for_apis() {
    log_info "Waking up APIs (Waiting for migrations)..."
    TIMEOUT=0
    printf "  "
    while ! curl -s -X GET "$PORTAINER_API/status" > /dev/null; do
        printf "${C_CYAN}.${C_DEFAULT}"
        sleep 3
        TIMEOUT=$((TIMEOUT + 1))
        if [ $TIMEOUT -gt 20 ]; then break; fi
    done
    printf " ${C_GREEN}Online!${C_DEFAULT}\n"
}

# ------------------------------------------
# PORTAINER
# ------------------------------------------
init_portainer() {
    curl -s -X POST "$PORTAINER_API/users/admin/init" \
        -H 'Content-Type: application/json' \
        -d "{\"Username\":\"admin\",\"Password\":\"$MASTER_PWD\"}" > /dev/null

    JWT=$(curl -s -X POST "$PORTAINER_API/auth" \
        -H 'Content-Type: application/json' \
        -d "{\"Username\":\"admin\",\"Password\":\"$MASTER_PWD\"}" | grep -oP '(?<="jwt":")[^"]+')
    
    # Role 2 = Standard User
    curl -s -X POST "$PORTAINER_API/users" -H "Authorization: Bearer $JWT" \
        -H 'Content-Type: application/json' \
        -d "{\"Username\":\"vision-read\",\"Password\":\"$VISION_READ_PWD\",\"Role\":2}" > /dev/null
    
    # Role 1 = Administrator
    curl -s -X POST "$PORTAINER_API/users" -H "Authorization: Bearer $JWT" \
        -H 'Content-Type: application/json' \
        -d "{\"Username\":\"vision-write\",\"Password\":\"$VISION_WRITE_PWD\",\"Role\":1}" > /dev/null
}

# ------------------------------------------
# ZABBIX
# ------------------------------------------
init_zabbix() {
    ZBX_TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' -d '{
        "jsonrpc": "2.0",
        "method": "user.login",
        "params": {"username": "Admin", "password": "zabbix"},
        "id": 1
    }' "$ZABBIX_API" | jq -r .result)

    if [ -z "$ZBX_TOKEN" ] || [ "$ZBX_TOKEN" == "null" ]; then
        return
    fi

    ZBX_SERVER_ID=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"host.get\",
        \"params\": {\"filter\": {\"host\": [\"Zabbix server\"]}},
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 1
    }" "$ZABBIX_API" | jq -r '.result[0].hostid')

    ZBX_DOCKER_TPL_ID=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"template.get\",
        \"params\": {\"filter\": {\"host\": [\"Docker by Zabbix agent 2\"]}},
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 1
    }" "$ZABBIX_API" | jq -r '.result[0].templateid')

    ZBX_INTERFACE_ID=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"hostinterface.get\",
        \"params\": {\"hostids\": \"$ZBX_SERVER_ID\"},
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 1
    }" "$ZABBIX_API" | jq -r '.result[0].interfaceid')

    # Update default agent DNS interface
    curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"hostinterface.update\",
        \"params\": {
            \"interfaceid\": \"$ZBX_INTERFACE_ID\",
            \"useip\": 0,
            \"dns\": \"visionstack-zabbix-agent\",
            \"port\": \"10050\"
        },
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 2
    }" "$ZABBIX_API" > /dev/null

    # Attach 'Docker by Zabbix agent 2' template (using jq appending)
    ZBX_HOST_DATA=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"host.get\",
        \"params\": {
            \"filter\": {\"host\": [\"Zabbix server\"]},
            \"selectParentTemplates\": [\"templateid\"]
        },
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 3
    }" "$ZABBIX_API")
    
    ZBX_NEW_TEMPLATE_LIST=$(echo $ZBX_HOST_DATA | jq -c ".result[0].parentTemplates + [{\"templateid\": \"$ZBX_DOCKER_TPL_ID\"}]")
    
    curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"host.update\",
        \"params\": {
            \"hostid\": \"$ZBX_SERVER_ID\",
            \"templates\": $ZBX_NEW_TEMPLATE_LIST
        },
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 4
    }" "$ZABBIX_API" > /dev/null

    # Create HTTP Tracking for Container GUIs
    curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"httptest.create\",
        \"params\": {
            \"name\": \"VisionStack Web GUIs\",
            \"hostid\": \"$ZBX_SERVER_ID\",
            \"steps\": [
                { \"name\": \"Portainer\", \"url\": \"http://visionstack-portainer:9000\", \"status_codes\": \"200\", \"no\": 1 },
                { \"name\": \"Netbox\", \"url\": \"http://visionstack-netbox:8080/login/\", \"status_codes\": \"200\", \"no\": 2 },
                { \"name\": \"Grafana\", \"url\": \"http://visionstack-grafana:3000/api/health\", \"status_codes\": \"200\", \"no\": 3 },
                { \"name\": \"Zabbix Web\", \"url\": \"http://visionstack-zabbix-web:8080/ping\", \"status_codes\": \"200\", \"no\": 4 },
                { \"name\": \"ntopng\", \"url\": \"http://visionstack-ntopng:3000\", \"status_codes\": \"200,302\", \"no\": 5 }
            ]
        },
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 5
    }" "$ZABBIX_API" > /dev/null

    # Provision Zabbix Universal Users
    curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"user.create\",
        \"params\": {
            \"username\": \"vision-write\",
            \"passwd\": \"$VISION_WRITE_PWD\",
            \"roleid\": \"3\",
            \"usrgrps\": [{\"usrgrpid\": \"7\"}]
        },
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 6
    }" "$ZABBIX_API" > /dev/null
    
    curl -s -X POST -H 'Content-Type: application/json' -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"user.create\",
        \"params\": {
            \"username\": \"vision-read\",
            \"passwd\": \"$VISION_READ_PWD\",
            \"roleid\": \"1\",
            \"usrgrps\": [{\"usrgrpid\": \"8\"}]
        },
        \"auth\": \"$ZBX_TOKEN\",
        \"id\": 7
    }" "$ZABBIX_API" > /dev/null
}

# ------------------------------------------
# NETBOX
# ------------------------------------------
init_netbox() {
    docker exec -i visionstack-netbox /opt/netbox/netbox/manage.py migrate --no-input > /dev/null 2>&1 &
    MIGRATE_PID=$!

    SPIN='-\|/'
    i=0
    # Add a custom spinner for migrations that preserves the progress bar
    printf "\n  ${C_CYAN}Running Netbox Migrations (~2-6 min) ${C_DEFAULT}"
    while kill -0 $MIGRATE_PID 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\b${SPIN:$i:1}"
        sleep 0.1
    done
    printf "\b${C_GREEN}Done!${C_DEFAULT}\n"

    printf "  ${C_CYAN}Waiting for Netbox Web UI ${C_DEFAULT}"
    TIMEOUT=0
    while true; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost:8020/login/" || echo "000")
        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
            break
        fi
        for _ in {1..50}; do
            i=$(( (i+1) %4 ))
            printf "\b${SPIN:$i:1}"
            sleep 0.1
        done
        TIMEOUT=$((TIMEOUT + 1))
        if [ $TIMEOUT -gt 180 ]; then
            printf "\b${C_RED}Timeout!${C_DEFAULT}\n"
            break
        fi
    done
    printf "\b${C_GREEN}Online!${C_DEFAULT}\n"

    # Go back up two lines to redraw over the sub-progress blocks to keep it clean, or leave them.
    # We will leave them so the user knows what took so long.
    
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

# Create Universal Service Accounts
user_read, _ = User.objects.get_or_create(username='vision-read')
user_read.is_superuser = False
user_read.is_staff = False
user_read.set_password('$VISION_READ_PWD')
user_read.save()
Token.objects.filter(user=user_read).delete()
Token.objects.create(user=user_read, key='$VISION_READ_TOKEN')

user_write, _ = User.objects.get_or_create(username='vision-write')
user_write.is_superuser = True
user_write.is_staff = True
user_write.set_password('$VISION_WRITE_PWD')
user_write.save()
Token.objects.filter(user=user_write).delete()
Token.objects.create(user=user_write, key='$VISION_WRITE_TOKEN')

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

    run_netbox_post() {
        curl -s -X POST -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" -d "$2" "$NETBOX_API/$1" > /dev/null
    }

    run_netbox_post "dcim/sites/" '{"name": "visionstack", "slug": "visionstack"}'
    run_netbox_post "dcim/manufacturers/" '{"name": "visionstack", "slug": "visionstack"}'
    run_netbox_post "dcim/device-roles/" '{"name": "Infrastructure", "slug": "infrastructure", "color": "4caf50"}'
    run_netbox_post "dcim/device-types/" '{"manufacturer": {"slug": "visionstack"}, "model": "Docker Container", "slug": "docker-container"}'
    run_netbox_post "dcim/device-types/" '{"manufacturer": {"slug": "visionstack"}, "model": "Baremetal Server", "slug": "baremetal-server"}'
    
    run_netbox_post "dcim/devices/" '{"name": "VisionStack Host Server", "device_type": {"slug": "baremetal-server"}, "site": {"slug": "visionstack"}, "status": "active", "role": {"slug": "infrastructure"}}'

    SERVICES=("Portainer" "Netbox" "Zabbix" "Graylog" "Grafana" "Prometheus" "ntopng" "Oxidized")
    for SERVICE in "${SERVICES[@]}"; do
        run_netbox_post "dcim/devices/" "{\"name\": \"$SERVICE\", \"device_type\": {\"slug\": \"docker-container\"}, \"site\": {\"slug\": \"visionstack\"}, \"status\": \"active\", \"role\": {\"slug\": \"infrastructure\"}}"
    done
}

# ------------------------------------------
# OXIDIZED
# ------------------------------------------
init_oxidized() {
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
    url: $NETBOX_API/dcim/devices/
    map:
      name: name
      model: device_type.model.slug
    headers:
      Authorization: "Token $NETBOX_TOKEN"
EOF
}

# ------------------------------------------
# GRAFANA
# ------------------------------------------
init_grafana() {
    run_grafana_admin() {
        curl -s -X POST -H 'Content-Type: application/json' -d "$2" "http://admin:admin@localhost:8050/api/$1" > /dev/null
    }

    run_grafana_admin "admin/users" "{\"name\":\"vision-read\",\"email\":\"read@visionstack\",\"login\":\"vision-read\",\"password\":\"$VISION_READ_PWD\"}"
    run_grafana_admin "admin/users" "{\"name\":\"vision-write\",\"email\":\"write@visionstack\",\"login\":\"vision-write\",\"password\":\"$VISION_WRITE_PWD\"}"

    run_grafana_admin "datasources" '{"name":"Prometheus","type":"prometheus","url":"http://visionstack-prometheus:9090","access":"proxy"}'
    run_grafana_admin "datasources" "{\"name\":\"PostgreSQL (Netbox)\",\"type\":\"postgres\",\"url\":\"visionstack-postgres-netbox:5432\",\"access\":\"proxy\",\"database\":\"netbox\",\"user\":\"netbox\",\"secureJsonData\":{\"password\":\"$MASTER_PWD\"},\"jsonData\":{\"sslmode\":\"disable\",\"postgresVersion\":15}}"
    run_grafana_admin "datasources" "{\"name\":\"PostgreSQL (Zabbix)\",\"type\":\"postgres\",\"url\":\"visionstack-postgres-zabbix:5432\",\"access\":\"proxy\",\"database\":\"zabbix\",\"user\":\"zabbix\",\"secureJsonData\":{\"password\":\"$MASTER_PWD\"},\"jsonData\":{\"sslmode\":\"disable\",\"postgresVersion\":15}}"
    run_grafana_admin "datasources" '{"name":"OpenSearch (Graylog)","type":"elasticsearch","url":"http://visionstack-opensearch:9200","access":"proxy","database":"[graylog_deflector]","jsonData":{"esVersion":"7.10.0","timeField":"timestamp","tlsSkipVerify":true}}'
    run_grafana_admin "datasources" '{"name":"Zabbix","type":"alexanderzobnin-zabbix-datasource","url":"http://visionstack-zabbix-web:8080/api_jsonrpc.php","access":"proxy","jsonData":{"username":"Admin","zabbixVersion":70},"secureJsonData":{"password":"zabbix"}}'
    run_grafana_admin "datasources" '{"name":"Redis","type":"redis-datasource","url":"redis://visionstack-redis:6379","access":"proxy"}'
}

# ------------------------------------------
# GRAYLOG
# ------------------------------------------
init_graylog() {
    run_graylog_post() {
        curl -s -u "admin:$MASTER_PWD" -X POST -H 'Content-Type: application/json' -H 'X-Requested-By: visionstack' -d "$2" "$GRAYLOG_API/$1" > /dev/null
    }

    run_graylog_post "users" "{\"username\":\"vision-read\",\"email\":\"read@visionstack\",\"full_name\":\"Vision Read\",\"password\":\"$VISION_READ_PWD\",\"roles\":[\"Reader\"]}"
    run_graylog_post "users" "{\"username\":\"vision-write\",\"email\":\"write@visionstack\",\"full_name\":\"Vision Write\",\"password\":\"$VISION_WRITE_PWD\",\"roles\":[\"Admin\"]}"

    run_graylog_post "system/inputs" '{"title":"Docker GELF","type":"org.graylog2.inputs.gelf.udp.GELFUDPInput","configuration":{"bind_address":"0.0.0.0","port":12201,"recv_buffer_size":1048576},"global":true}'
    run_graylog_post "system/inputs" '{"title":"Network Syslog","type":"org.graylog2.inputs.syslog.udp.SyslogUDPInput","configuration":{"bind_address":"0.0.0.0","port":1514,"recv_buffer_size":1048576,"force_rdns":false},"global":true}'
}

# ------------------------------------------
# ZABBIX <-> NETBOX SYNC
# ------------------------------------------
link_zabbix_netbox() {
    # Needs a new token to ensure session is valid
    ZBX_TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' -d '{
        "jsonrpc": "2.0",
        "method": "user.login",
        "params": {"username": "Admin", "password": "zabbix"},
        "id": 1
    }' "$ZABBIX_API" | jq -r .result)

    ZABBIX_HOST_ID=$(curl -s -X POST -H "Content-Type: application/json" -d "{
        \"jsonrpc\":\"2.0\",
        \"method\":\"host.get\",
        \"params\":{\"filter\":{\"host\":[\"Zabbix server\"]}},
        \"auth\": \"$ZBX_TOKEN\",
        \"id\":1
    }" "$ZABBIX_API" | jq -r '.result[0].hostid')

    TEMPLATE_ID=$(curl -s -X POST -H "Content-Type: application/json" -d "{
        \"jsonrpc\":\"2.0\",
        \"method\":\"template.get\",
        \"params\":{\"filter\":{\"host\":[\"Netbox by HTTP\"]}},
        \"auth\": \"$ZBX_TOKEN\",
        \"id\":1
    }" "$ZABBIX_API" | jq -r '.result[0].templateid')

    if [ -n "$TEMPLATE_ID" ] && [ "$TEMPLATE_ID" != "null" ]; then
        curl -s -X POST -H "Content-Type: application/json" -d "{
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
            \"auth\": \"$ZBX_TOKEN\",
            \"id\": 1
        }" "$ZABBIX_API" > /dev/null
    fi
}

# ==========================================
# EXECUTION
# ==========================================
clear
echo -e "${C_CYAN}"
echo "       _                     _             _    "
echo " __   _(_)___  ___  _ __  ___| |_ __ _  ___| | __"
echo " \ \ / / / __|/ _ \| '_ \/ __| __/ _\` |/ __| |/ /"
echo "  \ V /| \__ \ (_) | | | \__ \ || (_| | (__|   < "
echo "   \_/ |_|___/\___/|_| |_|___/\__\__,_|\___|_|\_\\"
echo "                                                      "
echo -e "${C_DEFAULT}"
log_step "Initializing Component Integrations..."
wait_for_apis

draw_progress "Configuring Portainer..."
init_portainer

draw_progress "Configuring Zabbix..."
init_zabbix

draw_progress "Configuring Netbox..."
init_netbox

draw_progress "Configuring Oxidized..."
init_oxidized

draw_progress "Configuring Grafana..."
init_grafana

draw_progress "Configuring Graylog..."
init_graylog

draw_progress "Linking Zabbix <-> Netbox..."
link_zabbix_netbox

echo ""
echo ""
log_succ "visionstack Configuration Complete!"
echo -e "         ${C_GREEN}All APIs are fully autonomous and integrated.${C_DEFAULT}"
echo ""
