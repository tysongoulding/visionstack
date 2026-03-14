#!/bin/bash
# visionstack Installer v1.4
set -e

echo "Initializing visionstack Deployment..."

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

# 1.6 Network Security (Open Syslog & Web Ports)
echo "Configuring Host Firewall..."
# Ensure SSH is allowed so you don't get locked out!
ufw allow 22/tcp 
# Standard Syslog ports for your network gear
ufw allow 514/udp
ufw allow 514/tcp
# visionstack UI Ports
ufw allow 8000:8080/tcp
# Enable firewall without asking for confirmation
ufw --force enable

# 2.5 Add Weekly Cleanup Cron Job (Set and Forget)
echo "Adding weekly maintenance schedule..."
(crontab -l 2>/dev/null; echo "0 0 * * 0 docker system prune -af --volumes > /dev/null 2>&1") | crontab -

# 3. Directory & Compose File Preparation
mkdir -p ./data/{netbox,zabbix,graylog,grafana,prometheus,oxidized,postgres-netbox,postgres-zabbix,mongodb,opensearch}
chmod -R 777 ./data

# If running via exactly a one-liner without cloning, download the compose file
if [ ! -f "docker-compose.yaml" ]; then
    echo "Downloading docker-compose.yaml..."
    curl -sL "https://raw.githubusercontent.com/tysongoulding/visionstack/main/docker-compose.yaml?t=$(date +%s)" -o docker-compose.yaml
fi

if [ ! -f "configure.sh" ]; then
    echo "Downloading configure.sh..."
    curl -sL "https://raw.githubusercontent.com/tysongoulding/visionstack/main/configure.sh?t=$(date +%s)" -o configure.sh
    chmod +x configure.sh
fi

# 4. Setup Wizard
# Auto-detect IP if not provided
if [ -z "$HOST_IP" ]; then
    # Try hostname -I first, if not available use ip route
    if command -v hostname >/dev/null 2>&1; then
        HOST_IP=$(hostname -I | awk '{print $1}')
    else
        HOST_IP=$(ip route get 1 | awk '{print $NF;exit}')
    fi
    echo "Auto-detected Host IP: $HOST_IP"
fi

# Check for existing credentials to ensure idempotency on re-runs
if [ -f "./visionstack_credentials.txt" ]; then
    echo "Existing credentials file found. Reusing previous secrets to prevent database lockout..."
    export MASTER_PWD=$(grep -m 1 "Master Password:" ./visionstack_credentials.txt | awk '{print $3}')
    export GRAYLOG_PASSWORD_SECRET=$(grep -m 1 "Graylog Secret:" ./visionstack_credentials.txt | awk '{print $3}')
    export NETBOX_SECRET_KEY=$(grep -m 1 "Netbox Secret Key:" ./visionstack_credentials.txt | awk '{print $4}')
    export NETBOX_TOKEN=$(grep -m 1 "Netbox API Token:" ./visionstack_credentials.txt | awk '{print $4}')
    export GRAYLOG_ROOT_PASSWORD_SHA2=$(echo -n "$MASTER_PWD" | sha256sum | awk '{print $1}')
else
    # Auto-generate password if not provided
    if [ -z "$MASTER_PWD" ]; then
        MASTER_PWD=$(openssl rand -hex 12)
        echo "Auto-generated Master Password."
    fi

    # 5. Generate Application Secrets early
    export GRAYLOG_ROOT_PASSWORD_SHA2=$(echo -n "$MASTER_PWD" | sha256sum | awk '{print $1}')
    export GRAYLOG_PASSWORD_SECRET=$(openssl rand -base64 32)
    export NETBOX_SECRET_KEY=$(openssl rand -base64 64)
    export NETBOX_TOKEN=$(openssl rand -hex 20)

    # Save credentials for the admin to reference later
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

SYSTEM SECRETS (Do not lose these!):
----------------------------------------
Netbox API Token: $NETBOX_TOKEN
Netbox Secret Key: $NETBOX_SECRET_KEY
Graylog Secret: $GRAYLOG_PASSWORD_SECRET
EOF
    chmod 600 ./visionstack_credentials.txt
    echo "Credentials saved to ./visionstack_credentials.txt (Keep this safe!)"
fi

# 6. Launch the Stack
echo "Deploying containers..."
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
    echo "Command 'docker compose' or 'docker-compose' not found!"
    exit 1
fi


# --- Final Credential Print ---
echo "------------------------------------------------"
echo "visionstack Infrastructure is LIVE!"
echo "------------------------------------------------"
echo "NetClaw (Host):  http://$HOST_IP:8000"
echo "Portainer:       http://$HOST_IP:8010 | admin / $MASTER_PWD"
echo "Netbox:          http://$HOST_IP:8020 | admin / $MASTER_PWD"
echo "Zabbix (Web):    http://$HOST_IP:8030 | Admin / zabbix"
echo "Graylog:         http://$HOST_IP:8040 | admin / $MASTER_PWD"
echo "Grafana:         http://$HOST_IP:8050 | admin / admin"
echo "ntopng:          http://$HOST_IP:8070 | admin / admin"
echo "------------------------------------------------"
echo "STAGE 1 COMPLETE: Raw containers deployed."
echo "------------------------------------------------"
echo "STAGE 2 COMMENCING: Auto-Configuring APIs and Webhooks..."
bash ./configure.sh
