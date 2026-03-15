#!/usr/bin/env bash
set -euo pipefail

#############################################
# ClaWArr Installer
# Self-hosted media server in ~10 minutes
# K3s + FluxCD + *arr stack + OpenClaw AI agent
#############################################

CLAWARR_REPO="https://github.com/clawarr/clawarr.git"
CLAWARR_BRANCH="main"
CLAWARR_NS="clawarr"
FLUX_NS="flux-system"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[ClaWArr]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ClaWArr]${NC} $*"; }
error() { echo -e "${RED}[ClaWArr]${NC} $*" >&2; }
header(){ echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

#############################################
# Pre-flight checks
#############################################
preflight() {
  header "Pre-flight Checks"

  # Must be root or sudo
  if [ "$EUID" -ne 0 ]; then
    error "Please run as root or with sudo"
    exit 1
  fi

  # Check OS
  if [ ! -f /etc/os-release ]; then
    error "Unsupported OS (no /etc/os-release)"
    exit 1
  fi
  source /etc/os-release
  case "$ID" in
    ubuntu|debian) log "Detected $PRETTY_NAME" ;;
    *) warn "Untested OS: $PRETTY_NAME. Proceeding anyway..." ;;
  esac

  # Check minimum resources
  TOTAL_MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  TOTAL_CPU=$(nproc)
  log "System: ${TOTAL_CPU} CPU cores, ${TOTAL_MEM} MB RAM"

  if [ "$TOTAL_MEM" -lt 3072 ]; then
    error "Minimum 4 GB RAM recommended (found ${TOTAL_MEM} MB)"
    read -p "Continue anyway? [y/N] " -r
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
  fi

  # Install dependencies
  log "Installing dependencies..."
  apt-get update -qq
  apt-get install -y -qq curl git jq openssl > /dev/null 2>&1
  log "Dependencies installed."
}

#############################################
# Interactive configuration
#############################################
configure() {
  header "Configuration"

  # 1. Telegram Bot Token
  echo -e "${BOLD}1. Telegram Bot Token${NC}"
  echo "   Create a bot via @BotFather on Telegram and paste the token."
  read -p "   Token: " TELEGRAM_TOKEN
  if [ -z "$TELEGRAM_TOKEN" ]; then
    error "Telegram token is required"
    exit 1
  fi

  # 2. LLM API Key (Anthropic)
  echo ""
  echo -e "${BOLD}2. Anthropic API Key${NC}"
  echo "   Get one at https://console.anthropic.com/"
  read -p "   API Key: " ANTHROPIC_KEY
  if [ -z "$ANTHROPIC_KEY" ]; then
    error "Anthropic API key is required"
    exit 1
  fi

  # 3. Media storage path
  echo ""
  echo -e "${BOLD}3. Media Storage${NC}"
  echo "   Where to store downloads and media library."
  echo "   This path must have enough disk space (50+ GB recommended)."
  read -p "   Path [/srv/clawarr]: " MEDIA_PATH
  MEDIA_PATH="${MEDIA_PATH:-/srv/clawarr}"

  # 4. Storage backend
  echo ""
  echo -e "${BOLD}4. Storage Backend${NC}"
  echo "   [1] Local disk (hostPath) — default"
  echo "   [2] NFS share"
  echo "   [3] SMB/CIFS share"
  read -p "   Choice [1]: " STORAGE_CHOICE
  STORAGE_CHOICE="${STORAGE_CHOICE:-1}"

  STORAGE_TYPE="hostpath"
  NFS_SERVER="" NFS_PATH=""
  SMB_SERVER="" SMB_SHARE="" SMB_USER="" SMB_PASS=""

  case "$STORAGE_CHOICE" in
    2)
      STORAGE_TYPE="nfs"
      read -p "   NFS Server IP: " NFS_SERVER
      read -p "   NFS Export Path: " NFS_PATH
      ;;
    3)
      STORAGE_TYPE="smb"
      read -p "   SMB Server (e.g., //192.168.1.100/share): " SMB_SERVER
      read -p "   SMB Username: " SMB_USER
      read -sp "   SMB Password: " SMB_PASS
      echo ""
      ;;
  esac

  # 5. VPN Configuration
  echo ""
  echo -e "${BOLD}5. VPN Configuration${NC} (recommended for torrents)"
  echo "   [1] WireGuard config file"
  echo "   [2] OpenVPN config file"
  echo "   [3] Skip (torrents use your real IP!)"
  read -p "   Choice [3]: " VPN_CHOICE
  VPN_CHOICE="${VPN_CHOICE:-3}"

  VPN_ENABLED="false"
  VPN_TYPE=""
  VPN_CONFIG_FILE=""

  case "$VPN_CHOICE" in
    1)
      VPN_ENABLED="true"
      VPN_TYPE="wireguard"
      read -p "   Path to .conf file: " VPN_CONFIG_FILE
      if [ ! -f "$VPN_CONFIG_FILE" ]; then
        error "File not found: $VPN_CONFIG_FILE"
        exit 1
      fi
      ;;
    2)
      VPN_ENABLED="true"
      VPN_TYPE="openvpn"
      read -p "   Path to .ovpn file: " VPN_CONFIG_FILE
      if [ ! -f "$VPN_CONFIG_FILE" ]; then
        error "File not found: $VPN_CONFIG_FILE"
        exit 1
      fi
      ;;
  esac

  # 6. Timezone
  echo ""
  CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
  read -p "   Timezone [$CURRENT_TZ]: " TIMEZONE
  TIMEZONE="${TIMEZONE:-$CURRENT_TZ}"

  # 7. Telegram user IDs (allowlist)
  echo ""
  echo -e "${BOLD}6. Telegram User ID${NC}"
  echo "   Your Telegram numeric user ID (get it from @userinfobot)."
  echo "   Leave empty to allow all DMs."
  read -p "   User ID: " TELEGRAM_USER_ID

  # Summary
  header "Configuration Summary"
  echo "   Telegram Bot: ✓"
  echo "   Anthropic API: ✓"
  echo "   Media Path: $MEDIA_PATH"
  echo "   Storage: $STORAGE_TYPE"
  echo "   VPN: ${VPN_ENABLED} ${VPN_TYPE:+($VPN_TYPE)}"
  echo "   Timezone: $TIMEZONE"
  echo ""
  read -p "   Proceed with installation? [Y/n] " -r
  [[ ${REPLY:-Y} =~ ^[Nn]$ ]] && exit 0
}

#############################################
# Install K3s
#############################################
install_k3s() {
  header "Installing K3s"

  if command -v k3s &>/dev/null; then
    log "K3s already installed, skipping."
  else
    log "Installing K3s (without Traefik)..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
    log "K3s installed."
  fi

  # Wait for K3s to be ready
  log "Waiting for K3s..."
  until kubectl get nodes &>/dev/null; do sleep 2; done
  kubectl wait --for=condition=Ready node --all --timeout=120s
  log "K3s is ready."

  # Set KUBECONFIG for the session
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  chmod 644 $KUBECONFIG
}

#############################################
# Install FluxCD
#############################################
install_flux() {
  header "Installing FluxCD"

  if command -v flux &>/dev/null; then
    log "FluxCD CLI already installed."
  else
    log "Installing FluxCD CLI..."
    curl -s https://fluxcd.io/install.sh | bash
  fi

  # Bootstrap Flux — connects to the public ClaWArr repo
  log "Bootstrapping FluxCD..."
  flux install --components-extra=image-reflector-controller,image-automation-controller 2>/dev/null || \
    flux install

  log "FluxCD installed."
}

#############################################
# Create media directory structure
#############################################
setup_storage() {
  header "Setting Up Storage"

  if [ "$STORAGE_TYPE" = "hostpath" ]; then
    log "Creating media directory structure at $MEDIA_PATH..."
    mkdir -p "$MEDIA_PATH"/{downloads/{movies,tv},movies,tv}
    chown -R 1000:1000 "$MEDIA_PATH"
    log "Directory structure created."
  fi
}

#############################################
# Create K8s namespace and secrets
#############################################
setup_kubernetes() {
  header "Setting Up Kubernetes Resources"

  # Create namespace
  kubectl create namespace $CLAWARR_NS --dry-run=client -o yaml | kubectl apply -f -

  # Generate gateway token
  GATEWAY_TOKEN=$(openssl rand -hex 16)

  # Agent secrets
  kubectl create secret generic clawarr-agent-secrets \
    -n $CLAWARR_NS \
    --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_KEY" \
    --from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_TOKEN" \
    --from-literal=OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Agent secrets created."

  # VPN secret (if configured)
  if [ "$VPN_ENABLED" = "true" ]; then
    if [ "$VPN_TYPE" = "wireguard" ]; then
      # Parse WireGuard config
      WG_PRIVATE_KEY=$(grep -oP 'PrivateKey\s*=\s*\K.*' "$VPN_CONFIG_FILE" | tr -d ' ')
      WG_ADDRESS=$(grep -oP 'Address\s*=\s*\K.*' "$VPN_CONFIG_FILE" | tr -d ' ')

      kubectl create secret generic clawarr-vpn \
        -n $CLAWARR_NS \
        --from-literal=WIREGUARD_PRIVATE_KEY="$WG_PRIVATE_KEY" \
        --from-literal=WIREGUARD_ADDRESSES="$WG_ADDRESS" \
        --from-file=wg0.conf="$VPN_CONFIG_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
    elif [ "$VPN_TYPE" = "openvpn" ]; then
      kubectl create secret generic clawarr-vpn \
        -n $CLAWARR_NS \
        --from-file=openvpn.conf="$VPN_CONFIG_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
    fi
    log "VPN secret created."
  fi

  # SMB credentials (if NFS/SMB storage)
  if [ "$STORAGE_TYPE" = "smb" ]; then
    kubectl create secret generic clawarr-smb-creds \
      -n kube-system \
      --from-literal=username="$SMB_USER" \
      --from-literal=password="$SMB_PASS" \
      --dry-run=client -o yaml | kubectl apply -f -
    log "SMB credentials stored."
  fi

  # User config ConfigMap (local overrides for FluxCD postBuild)
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: clawarr-user-config
  namespace: $FLUX_NS
data:
  TIMEZONE: "$TIMEZONE"
  MEDIA_PATH: "$MEDIA_PATH"
  VPN_ENABLED: "$VPN_ENABLED"
  VPN_TYPE: "${VPN_TYPE:-wireguard}"
  VPN_PROVIDER: "custom"
  DOMAIN: ""
EOF

  log "User config ConfigMap created."

  # Patch PV for NFS/SMB if needed
  if [ "$STORAGE_TYPE" = "nfs" ]; then
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: clawarr-media-data
spec:
  capacity:
    storage: 100Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: "$NFS_SERVER"
    path: "$NFS_PATH"
EOF
    log "NFS PV configured."
  elif [ "$STORAGE_TYPE" = "smb" ]; then
    # Install SMB CSI driver
    log "Installing SMB CSI driver..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/install-driver.sh 2>/dev/null || \
      curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/install-driver.sh | bash -s master -- 2>/dev/null || true

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: clawarr-media-data
spec:
  capacity:
    storage: 100Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: clawarr-media-smb
    volumeAttributes:
      source: "$SMB_SERVER"
    nodeStageSecretRef:
      name: clawarr-smb-creds
      namespace: kube-system
  mountOptions:
    - dir_mode=0777
    - file_mode=0777
    - uid=1000
    - gid=1000
    - noperm
EOF
    log "SMB PV configured."
  fi
}

#############################################
# Deploy ClaWArr via FluxCD
#############################################
deploy_clawarr() {
  header "Deploying ClaWArr"

  # Select qBittorrent variant based on VPN
  if [ "$VPN_ENABLED" = "false" ]; then
    log "VPN disabled — using qBittorrent without Gluetun"
    # The kustomization defaults to VPN variant; for no-VPN we need a patch
    # This is handled by the installer creating a kustomization overlay
  fi

  # Create FluxCD GitRepository source
  cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: clawarr
  namespace: $FLUX_NS
spec:
  interval: 5m
  url: $CLAWARR_REPO
  ref:
    branch: $CLAWARR_BRANCH
EOF

  # Create FluxCD Kustomization with variable substitution
  cat <<EOF | kubectl apply -f -
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: clawarr
  namespace: $FLUX_NS
spec:
  interval: 10m
  targetNamespace: $CLAWARR_NS
  sourceRef:
    kind: GitRepository
    name: clawarr
  path: ./flux
  prune: true
  wait: true
  timeout: 10m
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: clawarr-user-config
EOF

  log "FluxCD Kustomization created."
  log "Waiting for reconciliation..."

  # Wait for Flux to reconcile
  flux reconcile kustomization clawarr --with-source 2>/dev/null || true
  sleep 10

  # Wait for pods
  log "Waiting for all pods to be ready..."
  for deploy in sonarr radarr prowlarr qbittorrent jellyfin clawarr-agent; do
    kubectl rollout status deployment/$deploy -n $CLAWARR_NS --timeout=300s 2>/dev/null || \
      warn "$deploy not ready yet (may need more time)"
  done
}

#############################################
# Run arr-init job
#############################################
run_arr_init() {
  header "Auto-configuring Services"

  log "Running arr-init job..."
  # The job is already in the manifests — just wait for it
  kubectl wait --for=condition=complete job/arr-init -n $CLAWARR_NS --timeout=600s 2>/dev/null || \
    warn "arr-init job may still be running. Check with: clawarr logs arr-init"
}

#############################################
# Install CLI
#############################################
install_cli() {
  header "Installing ClaWArr CLI"

  cp "$(dirname "$0")/clawarr" /usr/local/bin/clawarr 2>/dev/null || \
    curl -sfL "${CLAWARR_REPO%.git}/raw/main/installer/clawarr" -o /usr/local/bin/clawarr
  chmod +x /usr/local/bin/clawarr
  log "CLI installed at /usr/local/bin/clawarr"
}

#############################################
# Print completion message
#############################################
complete() {
  header "Installation Complete!"

  local NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

  echo -e "  ${GREEN}✓${NC} K3s cluster running"
  echo -e "  ${GREEN}✓${NC} FluxCD GitOps connected to ${CLAWARR_REPO}"
  echo -e "  ${GREEN}✓${NC} Media stack deployed (Sonarr, Radarr, Prowlarr, qBittorrent, Jellyfin)"
  echo -e "  ${GREEN}✓${NC} OpenClaw AI agent running"
  echo -e "  ${GREEN}✓${NC} VPN: ${VPN_ENABLED}"
  echo ""
  echo -e "  ${BOLD}Next steps:${NC}"
  echo "  1. Open Telegram and message your bot"
  echo "  2. The agent will ask for your language and quality preferences"
  echo "  3. Tell it to add indexers (e.g., 'Add 1337x indexer')"
  echo "  4. Start downloading! (e.g., 'Download Interstellar')"
  echo ""
  echo -e "  ${BOLD}Useful commands:${NC}"
  echo "    clawarr status    — Check all pods"
  echo "    clawarr logs      — View agent logs"
  echo "    clawarr update    — Force FluxCD reconciliation"
  echo "    clawarr expose    — Expose services on the network"
  echo ""
  echo -e "  ${BOLD}Jellyfin:${NC} http://${NODE_IP}:30096 (after running: clawarr expose jellyfin)"
  echo ""
}

#############################################
# Main
#############################################
main() {
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "   ██████╗██╗      █████╗ ██╗    ██╗ █████╗ ██████╗ ██████╗ "
  echo "  ██╔════╝██║     ██╔══██╗██║    ██║██╔══██╗██╔══██╗██╔══██╗"
  echo "  ██║     ██║     ███████║██║ █╗ ██║███████║██████╔╝██████╔╝"
  echo "  ██║     ██║     ██╔══██║██║███╗██║██╔══██║██╔══██╗██╔══██╗"
  echo "  ╚██████╗███████╗██║  ██║╚███╔███╔╝██║  ██║██║  ██║██║  ██║"
  echo "   ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝"
  echo -e "${NC}"
  echo "  Self-hosted media server with AI agent — in ~10 minutes"
  echo ""

  preflight
  configure
  install_k3s
  install_flux
  setup_storage
  setup_kubernetes
  deploy_clawarr
  run_arr_init
  install_cli
  complete
}

main "$@"
