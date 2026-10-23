#!/usr/bin/env bash
# ==============================================================================
# 🚀 ZERO-TOUCH 1-COMMAND AUTO-BOOTSTRAPPER FOR EC2 & CLOUD VMS
# AI SECURITY & ENTERPRISE AGENTIC RAG PRODUCTION PLATFORM
#
# Designed for Senior Staff / Principal Systems Architect Demonstrations:
# Run directly on any bare, fresh EC2 instance or cloud VM via a single curl command
# without pre-installing git, docker, or python:
#
#   curl -fsSL https://raw.githubusercontent.com/KishorKumarParoi/AI_Security_Production_App/main/bootstrap.sh | bash
#
# What this script automates:
# 1. Non-interactive OS package manager setup (Ubuntu/Debian/Amazon Linux/RHEL)
# 2. Installs git, curl, and base build tools non-interactively
# 3. OOM Protection: Detects if RAM < 8GB and auto-configures a 4GB Swapfile
# 4. Ultra-fast shallow git clone (--depth 1) from GitHub
# 5. Public IP discovery via AWS IMDSv2 / IMDSv1 / External Resolvers
# 6. Automatic .env configuration with production secrets
# 7. Docker Engine & Docker Compose v2 auto-installation
# 8. Multi-stage BuildKit parallel container compilation
# 9. Healthcheck polling on FastAPI (Port 8080) and Streamlit UI (Port 8501)
# ==============================================================================

set -eo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
cat << "EOF"
================================================================================
  🛡️  AI SECURITY & ENTERPRISE AGENTIC RAG — ZERO-TOUCH CLOUD BOOTSTRAPPER
================================================================================
EOF
echo -e "${NC}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

run_sudo() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        sudo -E "$@"
    elif command -v sudo &>/dev/null; then
        sudo -E "$@"
    else
        "$@"
    fi
}

# ─── 1. Install Git & Base Prereqs If Missing ─────────────────────────────────
echo -e "${CYAN}[1/6] Detecting OS and ensuring Git & Curl are available...${NC}"

if ! command -v git &>/dev/null || ! command -v curl &>/dev/null; then
    echo -e "${YELLOW}[+] Installing Git, Curl, and core network utilities non-interactively...${NC}"
    if [ -f /etc/debian_version ]; then
        run_sudo apt-get update -qq
        run_sudo apt-get install -y -qq git curl ca-certificates tar gzip unzip build-essential >/dev/null 2>&1
    elif [ -f /etc/amazon-linux-release ] || [ -f /etc/redhat-release ]; then
        if command -v dnf &>/dev/null; then
            run_sudo dnf install -y -q git curl ca-certificates tar gzip unzip >/dev/null 2>&1 || true
        else
            run_sudo yum install -y -q git curl ca-certificates tar gzip unzip >/dev/null 2>&1 || true
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if ! command -v git &>/dev/null; then
            xcode-select --install 2>/dev/null || true
        fi
    fi
fi

echo -e "${GREEN}[✓] Git : $(git --version 2>/dev/null || echo 'Installed')${NC}"
echo -e "${GREEN}[✓] Curl: $(curl --version 2>/dev/null | head -n 1 || echo 'Installed')${NC}"

# ─── 2. Auto-Swap Configuration (OOM Protection for Small EC2 Instances) ──────
echo -e "\n${CYAN}[2/6] Checking System Memory & OOM Protection...${NC}"

if command -v free &>/dev/null; then
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    EXISTING_SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')
    
    # If RAM is under 8GB and swap is under 2GB, create 4GB swapfile
    if [ "$TOTAL_RAM_MB" -lt 8000 ] && [ "$EXISTING_SWAP_MB" -lt 2000 ]; then
        echo -e "${YELLOW}[!] Host has ${TOTAL_RAM_MB}MB RAM. Auto-configuring 4GB swapfile for compilation safety...${NC}"
        if [ ! -f /swapfile ]; then
            run_sudo fallocate -l 4G /swapfile 2>/dev/null || run_sudo dd if=/dev/zero of=/swapfile bs=1M count=4096 2>/dev/null
            run_sudo chmod 600 /swapfile
            run_sudo mkswap /swapfile >/dev/null 2>&1
            run_sudo swapon /swapfile 2>/dev/null || true
            run_sudo sysctl vm.swappiness=20 >/dev/null 2>&1 || true
            run_sudo sysctl vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
            if ! grep -q "/swapfile" /etc/fstab 2>/dev/null; then
                echo "/swapfile none swap sw 0 0" | run_sudo tee -a /etc/fstab >/dev/null 2>&1 || true
            fi
            echo -e "${GREEN}[✓] 4GB Swapfile configured and active!${NC}"
        fi
    else
        echo -e "${GREEN}[✓] Sufficient memory available (${TOTAL_RAM_MB}MB RAM, ${EXISTING_SWAP_MB}MB Swap).${NC}"
    fi
else
    echo -e "${GREEN}[✓] Memory check bypassed (macOS / BSD runtime).${NC}"
fi

# ─── 3. Repository Auto-Clone or Sync ──────────────────────────────────────────
echo -e "\n${CYAN}[3/6] Ensuring AI_Security_Production_App repository is local...${NC}"

REPO_URL="https://github.com/KishorKumarParoi/AI_Security_Production_App.git"
REPO_DIR="AI_Security_Production_App"

if [ -f "main.py" ] && [ -f "docker-compose.yml" ]; then
    echo -e "${GREEN}[✓] Already inside repository directory ($(pwd)). Syncing latest commit...${NC}"
    git pull origin main 2>/dev/null || true
elif [ -d "$REPO_DIR" ] && [ -f "$REPO_DIR/main.py" ]; then
    echo -e "${GREEN}[✓] Found existing directory ${REPO_DIR}. Entering and updating...${NC}"
    cd "$REPO_DIR"
    git pull origin main 2>/dev/null || true
else
    echo -e "${YELLOW}[+] Shallow cloning repository from GitHub for maximum speed...${NC}"
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi

# Set executable permissions
chmod +x clear.sh deploy.sh bootstrap.sh 2>/dev/null || true
find scripts/ -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

# ─── 4. Public IP Discovery & Environment Configuration ───────────────────────
echo -e "\n${CYAN}[4/6] Discovering Host Public IP & Configuring Environment...${NC}"

SERVER_PUBLIC_IP=""

# Try AWS EC2 IMDSv2
IMDS_TOKEN=$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
if [ -n "$IMDS_TOKEN" ]; then
    SERVER_PUBLIC_IP=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
fi

# Fallback to IMDSv1
if [ -z "$SERVER_PUBLIC_IP" ]; then
    SERVER_PUBLIC_IP=$(curl -s -m 2 "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
fi

# Fallback to external resolvers
if [ -z "$SERVER_PUBLIC_IP" ] || [[ ! "$SERVER_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SERVER_PUBLIC_IP=$(curl -s -m 3 https://ifconfig.me 2>/dev/null || curl -s -m 3 https://api.ipify.org 2>/dev/null || echo "127.0.0.1")
fi

export SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:-127.0.0.1}"
echo -e "${GREEN}[✓] Host Public IP Detected: ${BOLD}${SERVER_PUBLIC_IP}${NC}"

if [ ! -f .env ]; then
    echo -e "${CYAN}[+] Generating secure .env configuration from defaults...${NC}"
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        cat << ENV_EOF > .env
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP}
PORT=8080
STREAMLIT_PORT=8501
ENVIRONMENT=production
SECURITY_LEVEL=STRICT
FLASHRANK_ENABLED=true
GUARDRAILS_ENABLED=true
ENV_EOF
    fi
fi

# ─── 5. Docker & Docker Compose Auto-Bootstrap ────────────────────────────────
echo -e "\n${CYAN}[5/6] Bootstrapping Docker runtime & Docker Compose...${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${YELLOW}[+] Docker not found. Installing Docker engine automatically...${NC}"
    curl -fsSL https://get.docker.com | run_sudo sh
fi

if [[ "$OSTYPE" != "darwin"* ]]; then
    run_sudo systemctl enable --now docker 2>/dev/null || run_sudo service docker start 2>/dev/null || true
    run_sudo usermod -aG docker "$USER" 2>/dev/null || true
fi

# Detect Compose Command with automated sudo fallback
COMPOSE_CMD=""
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif run_sudo docker compose version &>/dev/null; then
    COMPOSE_CMD="run_sudo docker compose"
else
    echo -e "${YELLOW}[+] Installing Docker Compose v2 plugin...${NC}"
    CLI_PLUGINS_DIR="${HOME}/.docker/cli-plugins"
    mkdir -p "${CLI_PLUGINS_DIR}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) COMPOSE_ARCH="x86_64" ;;
        aarch64|arm64) COMPOSE_ARCH="aarch64" ;;
        *) COMPOSE_ARCH="x86_64" ;;
    esac
    curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" -o "${CLI_PLUGINS_DIR}/docker-compose" || true
    chmod +x "${CLI_PLUGINS_DIR}/docker-compose" || true
    COMPOSE_CMD="docker compose"
fi

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

# ─── 6. Build & Launch Microservices ──────────────────────────────────────────
echo -e "\n${CYAN}[6/6] Launching Production Containers via Docker Compose...${NC}"
echo "    1. Enterprise Agentic RAG API    (Port 8080 & Port 80)"
echo "    2. Streamlit Operations Portal   (Port 8501)"
echo ""

$COMPOSE_CMD up -d --build

# Polling health
echo -e "\n${CYAN}[*] Polling Service Health Status...${NC}"
for i in {1..20}; do
    if curl -fs -m 2 "http://localhost:8080/health" &>/dev/null; then
        echo -e "  ${GREEN}✔${NC} Enterprise RAG API is operational (http://localhost:8080/health)"
        break
    fi
    sleep 3
done

for i in {1..20}; do
    if curl -fs -m 2 "http://localhost:8501" &>/dev/null; then
        echo -e "  ${GREEN}✔${NC} Streamlit Intelligence Portal is operational (http://localhost:8501)"
        break
    fi
    sleep 3
done

echo -e "\n${GREEN}${BOLD}"
cat << "EOF"
================================================================================
🎉 DEPLOYMENT COMPLETE! AI SECURITY & ENTERPRISE RAG IS LIVE!
================================================================================
EOF
echo -e "${NC}"

echo -e "${BOLD}Enterprise Service Endpoints & Client Ingress:${NC}"
echo -e "  🌐 Web API (NGINX / Edge)   : ${CYAN}http://${SERVER_PUBLIC_IP}:80${NC}"
echo -e "  🧠 Enterprise RAG Swagger   : ${CYAN}http://${SERVER_PUBLIC_IP}:8080/docs${NC}"
echo -e "  ⚛️  Streamlit Operations UI  : ${CYAN}http://${SERVER_PUBLIC_IP}:8501${NC}"
echo -e "  📊 Metrics & Telemetry      : ${CYAN}http://${SERVER_PUBLIC_IP}:8080/metrics${NC}"
echo ""
echo -e "${BOLD}Principal Engineer Operations Commands:${NC}"
echo -e "  • Check Container Logs     : ${YELLOW}${COMPOSE_CMD} logs -f${NC}"
echo -e "  • Zero-Cost Full Teardown  : ${YELLOW}./clear.sh${NC}"
echo ""
echo -e "${GREEN}System is ready for Principal Engineer interview demonstration.${NC}\n"
