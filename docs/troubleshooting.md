# Troubleshooting

## Common Issues

### Pods not starting

```bash
clawarr status
kubectl describe pod -n clawarr <pod-name>
```

Common causes:
- **ImagePullBackOff**: Network issue pulling container images
- **Pending**: Not enough resources (RAM/CPU) or PVC not bound
- **CrashLoopBackOff**: Check logs with `clawarr logs <service>`

### Agent not responding on Telegram

1. Check agent logs: `clawarr logs agent`
2. Verify Telegram token: `kubectl get secret clawarr-agent-secrets -n clawarr -o jsonpath='{.data.TELEGRAM_BOT_TOKEN}' | base64 -d`
3. Ensure the bot is started (send /start in Telegram)

### Downloads stuck / not starting

1. Check qBittorrent: `clawarr logs qbittorrent`
2. If using VPN: `clawarr vpn status`
3. Check if indexers are configured: ask the bot "What indexers are configured?"
4. Verify qBittorrent password was set: `kubectl get secret clawarr-qbit-credentials -n clawarr`

### arr-init job failed

```bash
clawarr logs arr-init
```

Common causes:
- Services not ready yet (increase wait time)
- API key discovery failed (service config.xml not generated yet)

To re-run:
```bash
kubectl delete job arr-init -n clawarr
kubectl apply -f flux/config/arr-init/job.yaml
```

### FluxCD not reconciling

```bash
flux get kustomization clawarr
flux get source git clawarr
```

Force reconciliation:
```bash
clawarr update
```

### VPN not connecting

```bash
clawarr vpn status
clawarr logs qbittorrent  # Look for gluetun container logs
kubectl logs -n clawarr deployment/qbittorrent -c gluetun
```

Common causes:
- Invalid WireGuard private key
- VPN provider blocking the endpoint
- Firewall blocking UDP (WireGuard uses UDP)

### Disk space issues

Check free space via Radarr API:
```bash
kubectl exec -n clawarr deployment/radarr -- curl -s http://localhost:7878/api/v3/rootfolder \
  -H "X-Api-Key: $(kubectl get secret clawarr-arr-keys -n clawarr -o jsonpath='{.data.RADARR_API_KEY}' | base64 -d)"
```

## Reset

### Full reset (keep K3s)

```bash
clawarr uninstall
# Then re-run installer
```

### Reset a single service

```bash
kubectl delete pvc <service>-config -n clawarr
clawarr restart <service>
```

### Nuclear option

```bash
clawarr uninstall
/usr/local/bin/k3s-uninstall.sh
# Re-run install script from scratch
```
