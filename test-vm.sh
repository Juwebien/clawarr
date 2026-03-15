#!/usr/bin/env bash
# Quick smoke test for ClaWArr install on a fresh VM
# Run this AFTER install.sh completes
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== ClaWArr Smoke Test ==="
echo ""

# 1. K3s running
echo "--- K3s ---"
if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
  pass "K3s node is Ready"
else
  fail "K3s node not Ready"
fi

# 2. FluxCD running
echo "--- FluxCD ---"
if kubectl get pods -n flux-system 2>/dev/null | grep -q "Running"; then
  pass "FluxCD pods running"
else
  fail "FluxCD pods not running"
fi

# 3. Namespace exists
echo "--- Namespace ---"
if kubectl get namespace clawarr 2>/dev/null | grep -q "Active"; then
  pass "clawarr namespace exists"
else
  fail "clawarr namespace missing"
fi

# 4. All deployments
echo "--- Deployments ---"
for deploy in sonarr radarr prowlarr qbittorrent jellyfin clawarr-agent; do
  STATUS=$(kubectl get deployment $deploy -n clawarr -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "$STATUS" = "1" ]; then
    pass "$deploy: 1/1 ready"
  else
    fail "$deploy: not ready (replicas: ${STATUS:-0})"
    kubectl get pods -n clawarr -l app=$deploy -o wide 2>/dev/null || true
  fi
done

# 5. Services exist
echo "--- Services ---"
for svc in sonarr radarr prowlarr qbittorrent jellyfin clawarr-agent; do
  if kubectl get svc $svc -n clawarr 2>/dev/null | grep -q "ClusterIP"; then
    pass "$svc service exists (ClusterIP)"
  else
    fail "$svc service missing"
  fi
done

# 6. PVCs bound
echo "--- PVCs ---"
for pvc in sonarr-config radarr-config prowlarr-config qbittorrent-config jellyfin-config openclaw-state media-data; do
  STATUS=$(kubectl get pvc $pvc -n clawarr -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
  if [ "$STATUS" = "Bound" ]; then
    pass "$pvc: Bound"
  else
    fail "$pvc: $STATUS"
  fi
done

# 7. Secrets exist
echo "--- Secrets ---"
for secret in clawarr-agent-secrets clawarr-arr-keys; do
  if kubectl get secret $secret -n clawarr 2>/dev/null | grep -q "Opaque"; then
    pass "$secret exists"
  else
    fail "$secret missing"
  fi
done

# 8. API connectivity
echo "--- API Connectivity ---"
RADARR_KEY=$(kubectl get secret clawarr-arr-keys -n clawarr -o jsonpath='{.data.RADARR_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -n "$RADARR_KEY" ]; then
  # Port-forward and test
  kubectl port-forward -n clawarr svc/radarr 7878:7878 &>/dev/null &
  PF_PID=$!
  sleep 2
  if curl -sf "http://localhost:7878/api/v3/system/status" -H "X-Api-Key: $RADARR_KEY" 2>/dev/null | grep -q "version"; then
    pass "Radarr API responding"
  else
    fail "Radarr API not responding"
  fi
  kill $PF_PID 2>/dev/null || true
else
  fail "Radarr API key not found in secret"
fi

# 9. Agent container running
echo "--- Agent ---"
AGENT_POD=$(kubectl get pod -n clawarr -l app=clawarr-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$AGENT_POD" ]; then
  for container in openclaw webhook-bridge mission-control; do
    STATUS=$(kubectl get pod -n clawarr $AGENT_POD -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].ready}" 2>/dev/null || echo "false")
    if [ "$STATUS" = "true" ]; then
      pass "Agent container $container: ready"
    else
      fail "Agent container $container: not ready"
    fi
  done
else
  fail "Agent pod not found"
fi

# 10. FluxCD reconciliation
echo "--- FluxCD Status ---"
FLUX_STATUS=$(flux get kustomization clawarr 2>/dev/null | tail -1 || echo "unknown")
echo "  $FLUX_STATUS"

# Summary
echo ""
echo "=== Results ==="
if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
else
  echo -e "${RED}$FAILURES test(s) failed.${NC}"
fi
exit $FAILURES
