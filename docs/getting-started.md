# Getting Started

## Requirements

- **OS**: Ubuntu 22.04+ or Debian 12+ (other Linux distros may work)
- **Hardware**: 4 CPU cores, 4-8 GB RAM, 50-100 GB disk (+ media storage)
- **Network**: Internet access for downloads and LLM API calls
- **Accounts**: Telegram bot token + Anthropic API key

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/clawarr/clawarr/main/installer/install.sh | sudo bash
```

The installer will:
1. Install K3s (lightweight Kubernetes)
2. Install FluxCD (GitOps)
3. Ask for configuration (Telegram token, API key, storage, VPN)
4. Deploy the full media stack
5. Auto-configure all inter-service connections
6. Install the `clawarr` CLI

## What Gets Installed

| Service | Purpose | Internal URL |
|---------|---------|-------------|
| Sonarr | TV show management | http://sonarr:8989 |
| Radarr | Movie management | http://radarr:7878 |
| Prowlarr | Indexer management | http://prowlarr:9696 |
| qBittorrent | Torrent client | http://qbittorrent:8080 |
| Jellyfin | Media streaming | http://jellyfin:8096 |
| OpenClaw Agent | AI assistant (Telegram) | http://clawarr-agent:18789 |

## First Steps After Install

1. **Talk to the bot**: Open Telegram and send a message to your bot
2. **Set preferences**: The agent will ask for your language and quality preferences
3. **Add indexers**: Tell the bot "Add 1337x indexer" (or any public torrent indexer)
4. **Start downloading**: "Download Interstellar" or "Search for Severance"

## CLI Reference

```bash
clawarr status          # Check all pods
clawarr logs [service]  # View logs
clawarr update          # Pull latest from Git
clawarr expose jellyfin # Expose Jellyfin on http://IP:30096
clawarr config          # Show configuration
clawarr vpn status      # Check VPN status
clawarr restart [svc]   # Restart services
clawarr uninstall       # Remove ClaWArr (keeps data)
```

## Exposing Services

By default, no services are accessible from outside the cluster. To expose Jellyfin:

```bash
clawarr expose jellyfin
# -> Jellyfin available at http://YOUR-IP:30096
```

Available ports:
- Jellyfin: 30096
- Sonarr: 30989
- Radarr: 30878
- Prowlarr: 30696
- qBittorrent: 30080
