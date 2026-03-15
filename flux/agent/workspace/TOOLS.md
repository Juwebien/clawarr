# Environment Notes

## Media Stack (K8s Internal DNS)
| Service | URL | Auth Header |
|---------|-----|-------------|
| Radarr (movies) | http://radarr:7878 | X-Api-Key: $RADARR_API_KEY |
| Sonarr (series) | http://sonarr:8989 | X-Api-Key: $SONARR_API_KEY |
| Jellyfin (player) | http://jellyfin:8096 | X-Emby-Token: $JELLYFIN_API_KEY |
| qBittorrent | http://qbittorrent:8080 | Cookie auth |
| Prowlarr (indexers) | http://prowlarr:9696 | X-Api-Key: $PROWLARR_API_KEY |

## TMDB Posters
- URL format: https://image.tmdb.org/t/p/w500{posterPath}

## Webhook Bridge
- Radarr/Sonarr webhooks POST to: http://localhost:8095/webhook/{radarr,sonarr}
- Bridge forwards to OpenClaw gateway at localhost:18789
