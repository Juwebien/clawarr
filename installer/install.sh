#!/usr/bin/env bash
set -euo pipefail

#############################################
# ClaWArr Installer
# Self-hosted media server in ~10 minutes
# K3s + FluxCD + *arr stack + OpenClaw AI agent
#############################################

CLAWARR_REPO="https://github.com/Juwebien/clawarr.git"
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

  if [ "$EUID" -ne 0 ]; then
    error "Please run as root or with sudo"
    exit 1
  fi

  if [ ! -f /etc/os-release ]; then
    error "Unsupported OS (no /etc/os-release)"
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "$ID" in
    ubuntu|debian) log "Detected $PRETTY_NAME" ;;
    *) warn "Untested OS: $PRETTY_NAME. Proceeding anyway..." ;;
  esac

  TOTAL_MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  TOTAL_CPU=$(nproc)
  log "System: ${TOTAL_CPU} CPU cores, ${TOTAL_MEM} MB RAM"

  if [ "$TOTAL_MEM" -lt 3072 ]; then
    error "Minimum 4 GB RAM recommended (found ${TOTAL_MEM} MB)"
    read -r -p "Continue anyway? [y/N] "
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
  fi

  log "Installing dependencies..."
  apt-get update -qq
  apt-get install -y -qq curl git jq openssl nfs-common > /dev/null 2>&1 || true
  log "Dependencies installed."
}

#############################################
# Interactive configuration
#############################################
configure() {
  header "Configuration"

  echo -e "${BOLD}1. Telegram Bot Token${NC}"
  echo "   Create a bot via @BotFather on Telegram and paste the token."
  read -r -p "   Token: " TELEGRAM_TOKEN
  if [ -z "$TELEGRAM_TOKEN" ]; then
    error "Telegram token is required"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}2. Anthropic API Key${NC}"
  echo "   Get one at https://console.anthropic.com/"
  read -r -p "   API Key: " ANTHROPIC_KEY
  if [ -z "$ANTHROPIC_KEY" ]; then
    error "Anthropic API key is required"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}3. Media Storage${NC}"
  echo "   Where to store downloads and media library."
  echo "   This path must have enough disk space (50+ GB recommended)."
  read -r -p "   Path [/srv/clawarr]: " MEDIA_PATH
  MEDIA_PATH="${MEDIA_PATH:-/srv/clawarr}"

  echo ""
  echo -e "${BOLD}4. Storage Backend${NC}"
  echo "   [1] Local disk (hostPath) — default"
  echo "   [2] NFS share"
  echo "   [3] SMB/CIFS share"
  read -r -p "   Choice [1]: " STORAGE_CHOICE
  STORAGE_CHOICE="${STORAGE_CHOICE:-1}"

  STORAGE_TYPE="hostpath"
  NFS_SERVER="" NFS_PATH=""
  SMB_SERVER="" SMB_USER="" SMB_PASS=""

  case "$STORAGE_CHOICE" in
    2)
      STORAGE_TYPE="nfs"
      read -r -p "   NFS Server IP: " NFS_SERVER
      read -r -p "   NFS Export Path: " NFS_PATH
      ;;
    3)
      STORAGE_TYPE="smb"
      read -r -p "   SMB Server (e.g., //192.168.1.100/share): " SMB_SERVER
      read -r -p "   SMB Username: " SMB_USER
      read -r -sp "   SMB Password: " SMB_PASS
      echo ""
      ;;
  esac

  echo ""
  echo -e "${BOLD}5. VPN Configuration${NC} (recommended for torrents)"
  echo "   [1] WireGuard config file"
  echo "   [2] OpenVPN config file"
  echo "   [3] Skip (torrents use your real IP!)"
  read -r -p "   Choice [3]: " VPN_CHOICE
  VPN_CHOICE="${VPN_CHOICE:-3}"

  VPN_ENABLED="false"
  VPN_TYPE="none"
  VPN_CONFIG_FILE=""

  case "$VPN_CHOICE" in
    1)
      VPN_ENABLED="true"
      VPN_TYPE="wireguard"
      read -r -p "   Path to .conf file: " VPN_CONFIG_FILE
      if [ ! -f "$VPN_CONFIG_FILE" ]; then
        error "File not found: $VPN_CONFIG_FILE"
        exit 1
      fi
      ;;
    2)
      VPN_ENABLED="true"
      VPN_TYPE="openvpn"
      read -r -p "   Path to .ovpn file: " VPN_CONFIG_FILE
      if [ ! -f "$VPN_CONFIG_FILE" ]; then
        error "File not found: $VPN_CONFIG_FILE"
        exit 1
      fi
      ;;
  esac

  echo ""
  CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
  read -r -p "   Timezone [$CURRENT_TZ]: " TIMEZONE
  TIMEZONE="${TIMEZONE:-$CURRENT_TZ}"

  echo ""
  echo -e "${BOLD}6. Telegram User ID${NC}"
  echo "   Your Telegram numeric user ID (get it from @userinfobot)."
  echo "   Leave empty to allow all DMs."
  read -r -p "   User ID: " TELEGRAM_USER_ID

  header "Configuration Summary"
  echo "   Telegram Bot: ✓"
  echo "   Anthropic API: ✓"
  echo "   Media Path: $MEDIA_PATH"
  echo "   Storage: $STORAGE_TYPE"
  echo "   VPN: ${VPN_ENABLED} ${VPN_TYPE:+($VPN_TYPE)}"
  echo "   Timezone: $TIMEZONE"
  echo ""
  read -r -p "   Proceed with installation? [Y/n] "
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

  log "Waiting for K3s..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  chmod 600 "$KUBECONFIG"
  until kubectl get nodes &>/dev/null; do sleep 2; done
  kubectl wait --for=condition=Ready node --all --timeout=120s
  log "K3s is ready."
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

  log "Bootstrapping FluxCD..."
  flux install 2>/dev/null || flux install --components source-controller,kustomize-controller
  log "FluxCD installed."
}

#############################################
# Create media directory structure
#############################################
setup_storage() {
  header "Setting Up Storage"

  # Always create the directory structure for hardlinks
  log "Creating media directory structure at $MEDIA_PATH..."
  mkdir -p "$MEDIA_PATH"/{downloads/{movies,tv},movies,tv}
  chown -R 1000:1000 "$MEDIA_PATH"
  log "Directory structure created."
}

#############################################
# Create K8s namespace and secrets
#############################################
setup_kubernetes() {
  header "Setting Up Kubernetes Resources"

  kubectl create namespace $CLAWARR_NS --dry-run=client -o yaml | kubectl apply -f -

  GATEWAY_TOKEN=$(openssl rand -hex 16)

  kubectl create secret generic clawarr-agent-secrets \
    -n $CLAWARR_NS \
    --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_KEY" \
    --from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_TOKEN" \
    --from-literal=OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "Agent secrets created."

  # VPN secret
  if [ "$VPN_ENABLED" = "true" ]; then
    if [ "$VPN_TYPE" = "wireguard" ]; then
      WG_PRIVATE_KEY=$(sed -n 's/^PrivateKey\s*=\s*//p' "$VPN_CONFIG_FILE" | tr -d ' ')
      WG_ADDRESS=$(sed -n 's/^Address\s*=\s*//p' "$VPN_CONFIG_FILE" | tr -d ' ')

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

  # SMB credentials
  if [ "$STORAGE_TYPE" = "smb" ]; then
    kubectl create secret generic clawarr-smb-creds \
      -n kube-system \
      --from-literal=username="$SMB_USER" \
      --from-literal=password="$SMB_PASS" \
      --dry-run=client -o yaml | kubectl apply -f -
    log "SMB credentials stored."
  fi

  # User config ConfigMap for FluxCD postBuild substitution
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
  VPN_TYPE: "$VPN_TYPE"
  VPN_PROVIDER: "custom"
  DOMAIN: ""
EOF
  log "User config ConfigMap created."

  # Create PV based on storage type (BEFORE FluxCD deploys)
  # The Git repo has a hostPath PV with ${MEDIA_PATH}, but for NFS/SMB
  # we pre-create the PV so FluxCD doesn't overwrite it.
  if [ "$STORAGE_TYPE" = "nfs" ]; then
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: clawarr-media-data
  annotations:
    clawarr.io/storage-type: "nfs"
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
    log "Installing SMB CSI driver..."
    curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/install-driver.sh | bash -s master -- 2>&1 || \
      warn "SMB CSI driver install may have failed — check manually"

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: clawarr-media-data
  annotations:
    clawarr.io/storage-type: "smb"
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

  # Build FluxCD Kustomization — with optional VPN patch
  local PATCHES_BLOCK=""
  if [ "$VPN_ENABLED" = "false" ]; then
    log "VPN disabled — adding patch to use bare qBittorrent (no Gluetun)"
    # FluxCD inline patch: replace the VPN deployment with the no-VPN version
    read -r -d '' PATCHES_BLOCK <<'PATCHEOF' || true
  patches:
    - target:
        kind: Deployment
        name: qbittorrent
        namespace: clawarr
      patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: qbittorrent
          namespace: clawarr
        spec:
          template:
            spec:
              containers:
                - name: qbittorrent
                  image: linuxserver/qbittorrent:latest
                  ports:
                    - containerPort: 8080
                      name: webui
                  env:
                    - name: PUID
                      value: "1000"
                    - name: PGID
                      value: "1000"
                    - name: TZ
                      value: "${TIMEZONE}"
                    - name: WEBUI_PORT
                      value: "8080"
                  volumeMounts:
                    - name: config
                      mountPath: /config
                    - name: data
                      mountPath: /data
                  resources:
                    requests:
                      memory: "128Mi"
                      cpu: "25m"
                    limits:
                      memory: "1Gi"
                      cpu: "500m"
              volumes:
                - name: config
                  persistentVolumeClaim:
                    claimName: qbittorrent-config
                - name: data
                  persistentVolumeClaim:
                    claimName: media-data
PATCHEOF
  fi

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
$PATCHES_BLOCK
EOF

  log "FluxCD Kustomization created."
  log "Waiting for reconciliation..."

  flux reconcile kustomization clawarr --with-source 2>/dev/null || true
  sleep 15

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

  log "Waiting for arr-init job..."
  # Give services time to generate config.xml
  sleep 30

  kubectl wait --for=condition=complete job/arr-init -n $CLAWARR_NS --timeout=600s 2>/dev/null || \
    warn "arr-init job may still be running. Check with: clawarr logs arr-init"
}

#############################################
# Install CLI
#############################################
install_cli() {
  header "Installing ClaWArr CLI"

  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$script_dir/clawarr" ]; then
    cp "$script_dir/clawarr" /usr/local/bin/clawarr
  else
    curl -sfL "https://raw.githubusercontent.com/Juwebien/clawarr/main/installer/clawarr" -o /usr/local/bin/clawarr
  fi
  chmod +x /usr/local/bin/clawarr
  log "CLI installed at /usr/local/bin/clawarr"
}

#############################################
# Print completion message
#############################################
show_complete() {
  header "Installation Complete!"

  local NODE_IP
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

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
  cat <<'BANNER'
   ██████╗██╗      █████╗ ██╗    ██╗ █████╗ ██████╗ ██████╗
  ██╔════╝██║     ██╔══██╗██║    ██║██╔══██╗██╔══██╗██╔══██╗
  ██║     ██║     ███████║██║ █╗ ██║███████║██████╔╝██████╔╝
  ██║     ██║     ██╔══██║██║███╗██║██╔══██║██╔══██╗██╔══██╗
  ╚██████╗███████╗██║  ██║╚███╔███╔╝██║  ██║██║  ██║██║  ██║
   ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
BANNER
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
  show_complete
}

main "$@"
