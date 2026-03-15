# ClaWArr

Self-hosted media server with AI agent. K3s + FluxCD + Sonarr + Radarr + Prowlarr + qBittorrent + Jellyfin + OpenClaw — deployed in ~10 minutes via a single command.

## What is ClaWArr?

ClaWArr deploys a complete self-hosted media stack on a K3s Kubernetes cluster, connected via FluxCD GitOps for automatic updates. An OpenClaw AI agent manages everything through Telegram — search movies, add TV shows, manage indexers, monitor downloads, all in natural language.

**"Download Severance S3"** on Telegram → Sonarr searches → qBittorrent downloads → Jellyfin notifies when ready. Zero web UI, zero K8s knowledge needed.

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/clawarr/clawarr/main/installer/install.sh | sudo bash
```

Requirements: Ubuntu 22.04+ / Debian 12+, 4 CPU, 4 GB RAM, 50+ GB disk.

You'll need:
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- An Anthropic API key (from [console.anthropic.com](https://console.anthropic.com/))

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Telegram                                               │
│    ↕ (polling)                                          │
│  ┌───────────────────────────────────────┐              │
│  │  OpenClaw Agent Pod                   │              │
│  │  ├─ openclaw (gateway)    :18789      │              │
│  │  ├─ webhook-bridge        :8095       │              │
│  │  └─ mission-control       :3000       │              │
│  └──────────┬────────────────────────────┘              │
│             │ K8s DNS (internal)                         │
│  ┌──────────┼────────────────────────────┐              │
│  │  Media Stack                          │              │
│  │  ├─ Sonarr      :8989  (TV shows)    │              │
│  │  ├─ Radarr      :7878  (Movies)      │              │
│  │  ├─ Prowlarr    :9696  (Indexers)    │              │
│  │  ├─ qBittorrent :8080  (+Gluetun VPN)│              │
│  │  └─ Jellyfin    :8096  (Streaming)   │              │
│  └──────────┬────────────────────────────┘              │
│             │                                            │
│  ┌──────────┴────────────────────────────┐              │
│  │  /data (single mount — hardlinks)     │              │
│  │  ├─ downloads/{movies,tv}             │              │
│  │  ├─ movies/                           │              │
│  │  └─ tv/                               │              │
│  └───────────────────────────────────────┘              │
│                                                          │
│  FluxCD → GitHub (clawarr/clawarr) → auto-updates       │
└─────────────────────────────────────────────────────────┘
```

## Features

- **One-command install** — K3s + FluxCD + full media stack
- **AI agent on Telegram** — search, download, monitor in natural language
- **GitOps auto-updates** — FluxCD watches this repo, deploys changes automatically
- **VPN included** — Gluetun sidecar with WireGuard/OpenVPN (optional, recommended)
- **Hardlink-aware storage** — single mount for downloads + library, zero wasted space
- **Webhook notifications** — download complete → Telegram notification with poster + Jellyfin link
- **Auto-configuration** — arr-init job wires all services together on first boot
- **Quality management** — Recyclarr syncs TRaSH Guide profiles daily
- **No domain required** — works on LAN with NodePort, optional HTTPS with custom domain
- **Multiple storage backends** — local disk, NFS, SMB
- **CLI management** — `clawarr status`, `clawarr expose jellyfin`, `clawarr vpn status`

## Stack

| Component | Purpose |
|-----------|---------|
| [K3s](https://k3s.io/) | Lightweight Kubernetes |
| [FluxCD](https://fluxcd.io/) | GitOps continuous delivery |
| [Sonarr](https://sonarr.tv/) | TV show management |
| [Radarr](https://radarr.video/) | Movie management |
| [Prowlarr](https://prowlarr.com/) | Indexer management |
| [qBittorrent](https://www.qbittorrent.org/) | Torrent client |
| [Gluetun](https://github.com/qdm12/gluetun) | VPN sidecar |
| [Jellyfin](https://jellyfin.org/) | Media streaming |
| [OpenClaw](https://github.com/openclaw/openclaw) | AI agent framework |
| [Recyclarr](https://recyclarr.dev/) | Quality profile sync |

## CLI

```bash
clawarr status              # Pod status
clawarr logs [service]      # View logs
clawarr update              # Force GitOps sync
clawarr expose jellyfin     # Expose on NodePort 30096
clawarr unexpose jellyfin   # Back to ClusterIP
clawarr vpn status          # VPN connection info
clawarr config              # Show config
clawarr restart [service]   # Restart
clawarr uninstall           # Remove (keeps data)
```

## Documentation

- [Getting Started](docs/getting-started.md)
- [Storage Guide](docs/storage.md)
- [Troubleshooting](docs/troubleshooting.md)

## How It Works

1. **Install script** sets up K3s, FluxCD, and creates local secrets
2. **FluxCD** clones this repo and applies Kustomize manifests
3. **Variable substitution** via `postBuild.substituteFrom` reads local ConfigMap for timezone, storage, etc.
4. **arr-init Job** discovers API keys, wires services together, configures webhooks
5. **OpenClaw agent** connects to Telegram, manages the stack via *arr APIs
6. **Recyclarr CronJob** syncs quality profiles daily at 4 AM

## License

MIT
