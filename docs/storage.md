# Storage Guide

## Hardlinks — Why It Matters

The *arr apps use **hardlinks** to avoid duplicating files. When Radarr "imports" a downloaded movie, it creates a hardlink from the downloads folder to the library folder. The file appears in both places but uses disk space only once.

**For hardlinks to work, downloads and library MUST be on the same filesystem.**

## Directory Structure

```
/data/                     <- single mount point (same filesystem)
├── downloads/             <- qBittorrent saves here
│   ├── movies/            <- Radarr category
│   └── tv/                <- Sonarr category
├── movies/                <- Radarr library (Jellyfin reads this)
└── tv/                    <- Sonarr library (Jellyfin reads this)
```

## Storage Backends

### Local Disk (Default)

The installer creates the directory structure at the path you specify (default: `/srv/clawarr`).

Best for:
- Single disk or RAID array
- USB external drive (mounted permanently)
- VM with attached virtual disk

### NFS

For NAS devices (Synology, TrueNAS, Unraid, Freebox).

During install, provide:
- NFS server IP (e.g., `192.168.1.100`)
- Export path (e.g., `/volume1/media`)

Requirements:
- NFS export must allow read/write from the K3s node
- UID/GID 1000 must have write access

### SMB/CIFS

For Windows shares or Samba servers.

During install, provide:
- SMB path (e.g., `//192.168.1.100/media`)
- Username and password

Note: SMB hardlink support depends on the server configuration. Most modern Samba servers support it.

## Config PVCs

Each service stores its configuration in a separate PVC using K3s `local-path` storage:

| Service | PVC | Size |
|---------|-----|------|
| Sonarr | sonarr-config | 1 Gi |
| Radarr | radarr-config | 1 Gi |
| Prowlarr | prowlarr-config | 500 Mi |
| qBittorrent | qbittorrent-config | 500 Mi |
| Jellyfin | jellyfin-config | 5 Gi |
| OpenClaw Agent | openclaw-state | 5 Gi |

These are small and stored on the local disk regardless of the media storage backend.

## Troubleshooting

### Hardlinks not working

Check that both paths are on the same mount:
```bash
stat -f /data/downloads/movies/ /data/movies/
# Both should show the same filesystem ID
```

### Permission errors

All containers run as UID/GID 1000. Ensure the media path is owned by 1000:1000:
```bash
sudo chown -R 1000:1000 /srv/clawarr
```
