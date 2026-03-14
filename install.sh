#!/bin/bash
# visionstack Installer v1.4
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
log_step "Initializing Stage 1: Infrastructure Deployment"

# 1. Prerequisite Check
if [[ $EUID -ne 0 ]]; then
   log_err "This script must be run as root (sudo)." 
   exit 1
fi

# 1.5 Install Dependencies
if ! [ -x "$(command -v docker)" ]; then
    log_info "Installing Docker Engine..."
    curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
    sudo usermod -aG docker $USER
fi

if ! docker compose version &> /dev/null && ! docker-compose version &> /dev/null; then
    log_info "Installing Docker-Compose..."
    sudo apt-get update > /dev/null 2>&1 && sudo apt-get install -y docker-compose-plugin docker-compose > /dev/null 2>&1
fi

# 2. System Optimization & Log Rotation
log_info "Configuring Kernel & Docker Log Rotation (Max 300MB per container)..."
sysctl -w vm.max_map_count=262144 > /dev/null 2>&1
if ! grep -q "vm.max_map_count=262144" /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
fi

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

# 1.6 Network Security
log_info "Configuring Host Firewall (UFW)..."
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 514/udp > /dev/null 2>&1
ufw allow 514/tcp > /dev/null 2>&1
ufw allow 8000:8080/tcp > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1

# 2.5 Add Weekly Cleanup Cron Job
log_info "Injecting automated weekly Docker cleanup schedule..."
(crontab -l 2>/dev/null | grep -v "docker system prune"; echo "0 0 * * 0 docker system prune -af --volumes > /dev/null 2>&1") | crontab -

# 3. Directory & Compose File Preparation
log_info "Provisioning underlying persistence directories..."
mkdir -p ./data/{netbox,zabbix,graylog,grafana,prometheus,oxidized,postgres-netbox,postgres-zabbix,mongodb,opensearch}
chmod -R 777 ./data

# If running via exactly a one-liner without cloning, download the compose file
if [ ! -f "docker-compose.yaml" ]; then
    log_info "Downloading architectural configuration (docker-compose.yaml)..."
    curl -sL "https://raw.githubusercontent.com/tysongoulding/visionstack/main/docker-compose.yaml?t=$(date +%s)" -o docker-compose.yaml
fi

if [ ! -f "configure.sh" ]; then
    log_info "Downloading integration engine (configure.sh)..."
    curl -sL "https://raw.githubusercontent.com/tysongoulding/visionstack/main/configure.sh?t=$(date +%s)" -o configure.sh
    chmod +x configure.sh
fi

log_succ "Host System Prep Complete."

# 4. Setup Wizard
log_step "Generating Security Footprint"
if [ -z "$HOST_IP" ]; then
    if command -v hostname >/dev/null 2>&1; then
        HOST_IP=$(hostname -I | awk '{print $1}')
    else
        HOST_IP=$(ip route get 1 | awk '{print $NF;exit}')
    fi
    log_info "Auto-detected Host IP: $HOST_IP"
fi

if [ -f "./visionstack_credentials.txt" ]; then
    log_warn "Existing credentials file found. Reusing previous secrets to prevent database lockout."
    export MASTER_PWD=$(grep -m 1 "Master Password:" ./visionstack_credentials.txt | awk '{print $3}')
    export GRAYLOG_PASSWORD_SECRET=$(grep -m 1 "Graylog Secret:" ./visionstack_credentials.txt | awk '{print $3}')
    export NETBOX_SECRET_KEY=$(grep -m 1 "Netbox Secret Key:" ./visionstack_credentials.txt | awk '{print $4}')
    export NETBOX_TOKEN=$(grep -m 1 "Netbox API Token:" ./visionstack_credentials.txt | awk '{print $4}')
    export VISION_READ_PWD=$(grep -m 1 "vision-read Pass:" ./visionstack_credentials.txt | awk '{print $3}')
    export VISION_WRITE_PWD=$(grep -m 1 "vision-write Pass:" ./visionstack_credentials.txt | awk '{print $3}')
    export VISION_READ_TOKEN=$(grep -m 1 "vision-read App Token:" ./visionstack_credentials.txt | awk '{print $4}')
    export VISION_WRITE_TOKEN=$(grep -m 1 "vision-write App Token:" ./visionstack_credentials.txt | awk '{print $4}')
    export GRAYLOG_ROOT_PASSWORD_SHA2=$(echo -n "$MASTER_PWD" | sha256sum | awk '{print $1}')
else
    if [ -z "$MASTER_PWD" ]; then
        MASTER_PWD=$(openssl rand -hex 12)
        log_info "Auto-generated Secure Master Password."
    fi

    export VISION_READ_PWD=$(openssl rand -hex 16)
    export VISION_WRITE_PWD=$(openssl rand -hex 16)
    export VISION_READ_TOKEN=$(openssl rand -hex 20)
    export VISION_WRITE_TOKEN=$(openssl rand -hex 20)

    export GRAYLOG_ROOT_PASSWORD_SHA2=$(echo -n "$MASTER_PWD" | sha256sum | awk '{print $1}')
    export GRAYLOG_PASSWORD_SECRET=$(openssl rand -base64 32)
    export NETBOX_SECRET_KEY=$(openssl rand -base64 64)
    export NETBOX_TOKEN=$(openssl rand -hex 20)

    cat <<EOF > ./visionstack_credentials.txt
========================================
 visionstack Auto-Generated Credentials
========================================
Deployment Date: \$(date)
Host IP (Detected): $HOST_IP

CORE INFRASTRUCTURE:
----------------------------------------
Master Password: $MASTER_PWD

APPLICATION LOGIN CREDENTIALS:
----------------------------------------
* Portainer (http://$HOST_IP:8010)
  User: admin
  Pass: $MASTER_PWD

* Netbox (http://$HOST_IP:8020)
  User: admin
  Pass: $MASTER_PWD

* Zabbix (http://$HOST_IP:8030)
  User: Admin
  Pass: zabbix

* Graylog (http://$HOST_IP:8040)
  User: admin
  Pass: $MASTER_PWD

* Grafana (http://$HOST_IP:8050)
  User: admin
  Pass: admin

* Prometheus (http://$HOST_IP:8060)
  (No authentication by default)

* ntopng (http://$HOST_IP:8070)
  User: admin
  Pass: admin

* Oxidized (http://$HOST_IP:8080)
  (No authentication by default)

INTERNAL DATABASE CREDENTIALS:
----------------------------------------
* Postgres (Zabbix)
  Host: visionstack-postgres-zabbix:5432
  User: zabbix
  Pass: $MASTER_PWD

* Postgres (Netbox)
  Host: visionstack-postgres-netbox:5432
  User: netbox
  Pass: $MASTER_PWD

* MongoDB
  Host: visionstack-mongodb:27017
  (No authentication by default)

* OpenSearch
  Host: visionstack-opensearch:9200
  (Security plugin disabled by default)

* Redis
  Host: visionstack-redis:6379
  (No authentication by default)

UNIVERSAL SERVICE ACCOUNTS:
----------------------------------------
* vision-read (Read-Only)
  vision-read Pass: $VISION_READ_PWD
  vision-read App Token: $VISION_READ_TOKEN

* vision-write (Global Admin)
  vision-write Pass: $VISION_WRITE_PWD
  vision-write App Token: $VISION_WRITE_TOKEN

SYSTEM SECRETS (Do not lose these!):
----------------------------------------
Netbox API Token: $NETBOX_TOKEN
Netbox Secret Key: $NETBOX_SECRET_KEY
Graylog Secret: $GRAYLOG_PASSWORD_SECRET
EOF
    chmod 600 ./visionstack_credentials.txt
    log_succ "Secrets and Credentials compiled securely to ./visionstack_credentials.txt"
fi

# 6. Launch the Stack
log_step "Launching Engine Core (Docker Compose)"

# Generate .env file for docker compose to support manual usage
log_info "Generating docker compose .env file..."
cat <<EOF > .env
MASTER_PWD=$MASTER_PWD
HOST_IP=$HOST_IP
GRAYLOG_ROOT_PASSWORD_SHA2=$GRAYLOG_ROOT_PASSWORD_SHA2
GRAYLOG_PASSWORD_SECRET=$GRAYLOG_PASSWORD_SECRET
NETBOX_SECRET_KEY=$NETBOX_SECRET_KEY
EOF
chmod 600 .env

export MASTER_PWD=$MASTER_PWD
export HOST_IP=$HOST_IP
export GRAYLOG_ROOT_PASSWORD_SHA2=$GRAYLOG_ROOT_PASSWORD_SHA2
export GRAYLOG_PASSWORD_SECRET=$GRAYLOG_PASSWORD_SECRET
export NETBOX_SECRET_KEY=$NETBOX_SECRET_KEY

if docker compose version &> /dev/null; then
    docker compose up -d --pull always --force-recreate
elif docker-compose version &> /dev/null; then
    docker-compose up -d --pull always --force-recreate
else
    log_err "Command 'docker compose' or 'docker-compose' not found!"
    exit 1
fi

log_succ "Stage 1 Complete: Raw network containers deployed."

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

log_step "STAGE 2 COMMENCING: Auto-Configuring APIs and Webhooks..."
bash ./configure.sh
