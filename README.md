# visionstack
**The Ultimate Open-Source Network Observability & Lab Suite.**

`visionstack` is a unified, automated deployment of the world's leading network management tools. It provides a single-pane-of-glass view into your infrastructure with a standardized port scheme and a hybrid host-container architecture.

---

## 🚀 Quick Start

Choose one of the following installation methods. Note that the script is fully automated and will auto-detect your host IP and auto-generate secure passwords.

### Option 1: The One-Liner (Recommended)
Run the following one-liner to download and execute the fully automated setup script directly.

```bash
curl -sL "https://raw.githubusercontent.com/tysongoulding/visionstack/main/install.sh?t=$(date +%s)" | sudo bash
```

### Option 2: Manual Clone
If you prefer to clone the repository locally first, you can run the following sequence:

```bash
git clone https://github.com/tysongoulding/visionstack.git
cd visionstack
sudo chmod +x install.sh
sudo ./install.sh
```
### 🗺️ Port Map & Ecosystem

| Service | Port | Description | Environment |
| :--- | :---: | :--- | :--- |
| **OpenClaw** | `8000` | Native Host Lab (Netclaw/Containerlab) | **Host** |
| **Portainer** | `8010` | GUI Container & Stack Management | Container |
| **Netbox** | `8020` | IPAM & DCIM (Source of Truth) | Container |
| **Zabbix** | `8030` | Performance & Fault Monitoring | Container |
| **Graylog** | `8040` | Centralized Log Management (SIEM) | Container |
| **Grafana** | `8050` | Unified Visualization Dashboards | Container |
| **Prometheus** | `8060` | Time-Series Metrics & Telemetry | Container |
| **ntopng** | `8070` | Real-time Traffic Flow Analysis | Container |
| **Oxidized** | `8080` | Automated Network Config Backup | Container |

---

### 🛠️ Architecture & Integration

`visionStack` utilizes a hybrid deployment model. Heavy-duty network orchestration (**OpenClaw/Netclaw**) runs natively on the host for direct kernel access, while the management and observability tools are containerized for isolation and portability.

#### 🔗 Integrated Flow
* **Inventory:** **Netbox** acts as the primary source of truth for **Zabbix** and **Oxidized**.
* **Telemetry:** **Prometheus** and **Zabbix** feed performance data into **Grafana** for advanced dashboarding.
* **Logs:** **Graylog** ingests syslogs from the host and network nodes via GELF/UDP.
* **Traffic:** **ntopng** analyzes flows exported from the host or lab interfaces via **softflowd**.

---

### 📋 Prerequisites

* **OS:** Ubuntu 22.04 LTS or newer (Recommended).
* **Hardware:** Minimum **8GB RAM** (16GB+ recommended for full Graylog/OpenSearch performance).
* **Permissions:** **Sudo access** is required for host-level networking and Docker management.
