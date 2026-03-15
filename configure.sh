#!/bin/bash
# visionstack Configuration Engine
# set -e (Removed to allow script to continue on individual curl/api errors)# ==========================================
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

run_task() {
    local task_name=$1
    local func_name=$2
    
    tput civis
    $func_name > /dev/null 2>&1 &
    local pid=$!
    
    local spin='-\|/'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r  ${C_CYAN}[${spin:$i:1}]${C_DEFAULT} %s" "$task_name..."
        sleep 0.1
    done
    wait $pid
    local extcode=$?
    
    tput cnorm
    
    if [ $extcode -eq 0 ]; then
        printf "\r  ${C_GREEN}[✓]${C_DEFAULT} %-60s\n" "$task_name..."
    else
        printf "\r  ${C_RED}[x]${C_DEFAULT} %-60s\n" "$task_name... (Failed)"
    fi
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
wait_for_portainer() {
    local TIMEOUT=0
    while ! curl -s -X GET "$PORTAINER_API/status" > /dev/null; do
        sleep 3
        TIMEOUT=$((TIMEOUT + 1))
        if [ $TIMEOUT -gt 20 ]; then exit 1; fi
    done
}

wait_for_zabbix() {
    local TIMEOUT=0
    # Wait for the API to actually start returning valid JSON RPCs
    while true; do
        local RESPONSE=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc": "2.0", "method": "apiinfo.version", "id": 1}' "$ZABBIX_API" || echo "failed")
        if [[ "$RESPONSE" == *"result"* ]]; then
            break
        fi
        sleep 3
        TIMEOUT=$((TIMEOUT + 1))
        # Zabbix postgres DB initialization is notoriously slow on first boot. Need an extended timeout here.
        if [ $TIMEOUT -gt 60 ]; then exit 1; fi
    done
}

wait_for_grafana() {
    local TIMEOUT=0
    while ! curl -s -X GET "$GRAFANA_API/health" > /dev/null; do
        sleep 3
        TIMEOUT=$((TIMEOUT + 1))
        if [ $TIMEOUT -gt 20 ]; then exit 1; fi
    done
}

wait_for_graylog() {
    local TIMEOUT=0
    while ! curl -s -X GET "$GRAYLOG_API/system/cluster/node" > /dev/null; do
        sleep 3
        TIMEOUT=$((TIMEOUT + 1))
        if [ $TIMEOUT -gt 20 ]; then exit 1; fi
    done
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
netbox_migrate() {
    # Run migrations synchronously inside a spinner so we can see when it finishes
    # TTY (-i/-t) flags removed to prevent background thread exit code failures
    docker exec visionstack-netbox /opt/netbox/netbox/manage.py migrate --no-input > /dev/null 2>&1
}

wait_for_netbox() {
    local TIMEOUT=0
    while true; do
        local HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost:8020/login/" || echo "000")
        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
            # Wait an additional small delay to ensure the web workers are fully bound
            sleep 5
            break
        fi
        sleep 3
        TIMEOUT=$((TIMEOUT + 1))
        # NetBox API boot takes several minutes after DB schema build
        if [ $TIMEOUT -gt 180 ]; then exit 1; fi
    done
}

netbox_config() {
    
    CONTAINERS=$(docker ps --format '{{.Names}}')

    # Removed -i flag to prevent non-interactive shell errors
    docker exec visionstack-netbox python3 manage.py shell <<EOF
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

# ------------------------------------------
# FREERADIUS (JUMPCLOUD PROXY)
# ------------------------------------------
wait_for_freeradius() {
    local TIMEOUT=0
    # FreeRADIUS initializes almost instantly, but wait for the port to open
    while ! docker exec visionstack-freeradius radtest testing password localhost 0 testing123 >/dev/null 2>&1; do
        sleep 2
        TIMEOUT=$((TIMEOUT + 1))
        if [ $TIMEOUT -gt 15 ]; then exit 1; fi
    done
}

init_freeradius() {
    # 1. Inject Network Clients (Local network gear allowed to query this proxy)
    docker exec visionstack-freeradius bash -c "cat << 'EOF' > /etc/raddb/clients.conf
client localhost {
    ipaddr = 127.0.0.1
    secret = testing123
}
client private_10 {
    ipaddr = 10.0.0.0/8
    secret = $LOCAL_RADIUS_SECRET
}
client private_172 {
    ipaddr = 172.16.0.0/12
    secret = $LOCAL_RADIUS_SECRET
}
client private_192 {
    ipaddr = 192.168.0.0/16
    secret = $LOCAL_RADIUS_SECRET
}
EOF"

    # 2. Inject Proxy Configuration (Forward all requests to JumpCloud)
    docker exec visionstack-freeradius bash -c "cat << 'EOF' > /etc/raddb/proxy.conf
proxy server {
    default_fallback = no
}
home_server jumpcloud {
    type = auth
    ipaddr = radius.jumpcloud.com
    port = 1812
    secret = $JUMPCLOUD_SHARED_SECRET
    response_window = 20
    zombie_period = 40
    revive_interval = 120
    status_check = status-server
    check_interval = 30
    num_answers_to_alive = 3
}
home_server_pool jumpcloud_pool {
    type = fail-over
    home_server = jumpcloud
}
realm DEFAULT {
    auth_pool = jumpcloud_pool
    nostrip
}
EOF"

    # Restart FreeRADIUS daemon to absorb the new confs
    docker restart visionstack-freeradius > /dev/null
}

# ==========================================
# EXECUTION
# ==========================================
clear
echo -e "${C_CYAN}"
echo "                                                     "
echo "        _     _                 _             _      "
echo " __   _(_)___(_) ___  _ __  ___| |_ __ _  ___| | __  "
echo " \ \ / / / __| |/ _ \| '_ \/ __| __/ _' |/ __| |/ /  "
echo "  \ V /| \__ \ | (_) | | | \__ \ || (_| | (__|   <   "
echo "   \_/ |_|___/_|\___/|_| |_|___/\__\__,_|\___|_|\_\  "
echo "                                                     "
echo -e "${C_DEFAULT}"
log_step "Initializing Component Integrations..."
run_task "Waiting for Portainer API" "wait_for_portainer"
run_task "Configuring Portainer" "init_portainer"

run_task "Waiting for Zabbix API" "wait_for_zabbix"
run_task "Configuring Zabbix" "init_zabbix"

run_task "Running Netbox Database Migrations (~2-5 min)" "netbox_migrate"
run_task "Waiting for Netbox Web UI (~5-8 min)" "wait_for_netbox"
run_task "Configuring Netbox Settings" "netbox_config"
run_task "Configuring Oxidized" "init_oxidized"

run_task "Waiting for Grafana API" "wait_for_grafana"
run_task "Configuring Grafana" "init_grafana"

run_task "Waiting for Graylog API" "wait_for_graylog"
run_task "Configuring Graylog" "init_graylog"

run_task "Waiting for FreeRADIUS Daemon" "wait_for_freeradius"
run_task "Configuring FreeRADIUS Proxy" "init_freeradius"

run_task "Linking Zabbix <-> Netbox" "link_zabbix_netbox"

# --- Final Credential Print ---
echo -e "\n${C_MAGENTA}================================================================${C_DEFAULT}"
echo -e "${C_GREEN}  visionstack Infrastructure is LIVE!${C_DEFAULT}"
echo -e "${C_MAGENTA}================================================================${C_DEFAULT}"
echo -e "${C_CYAN}  NetClaw (Host) :${C_DEFAULT} http://$HOST_IP:8000"
echo -e "${C_CYAN}  Portainer      :${C_DEFAULT} http://$HOST_IP:8010 | admin / $MASTER_PWD"
echo -e "${C_CYAN}  Netbox         :${C_DEFAULT} http://$HOST_IP:8020 | admin / $MASTER_PWD"
echo -e "${C_CYAN}  Zabbix (Web)   :${C_DEFAULT} http://$HOST_IP:8030 | Admin / zabbix"
echo -e "${C_CYAN}  Graylog        :${C_DEFAULT} http://$HOST_IP:8040 | admin / $MASTER_PWD"
echo -e "${C_CYAN}  Grafana        :${C_DEFAULT} http://$HOST_IP:8050 | admin / admin"
echo -e "${C_CYAN}  Prometheus     :${C_DEFAULT} http://$HOST_IP:8060 | (No auth)"
echo -e "${C_CYAN}  ntopng         :${C_DEFAULT} http://$HOST_IP:8070 | admin / admin"
echo -e "${C_MAGENTA}----------------------------------------------------------------${C_DEFAULT}"
echo -e "${C_YELLOW}  Universal Service Accounts Active:${C_DEFAULT}"
echo -e "  vision-read  | $VISION_READ_PWD"
echo -e "  vision-write | $VISION_WRITE_PWD"
echo -e "${C_MAGENTA}================================================================${C_DEFAULT}\n"

echo ""
echo ""
log_succ "visionstack Configuration Complete!"
echo -e "         ${C_GREEN}All APIs are fully autonomous and integrated.${C_DEFAULT}"
echo ""
