---
name: media-stack
description: >
  Manage the media stack: search/add movies (Radarr), TV shows (Sonarr),
  manage indexers (Prowlarr), monitor downloads (qBittorrent), browse library (Jellyfin),
  check calendar for upcoming releases, and send posters/covers via Telegram.
  Use when: user asks about movies, series, downloads, media library, indexers,
  upcoming releases, or wants to add content. Also triggered by webhook notifications.
---

# Media Stack Skill

## Authentication

All API calls use environment variables for auth:
- Radarr: header `X-Api-Key: $RADARR_API_KEY`
- Sonarr: header `X-Api-Key: $SONARR_API_KEY`
- Jellyfin: header `X-Emby-Token: $JELLYFIN_API_KEY`
- Prowlarr: header `X-Api-Key: $PROWLARR_API_KEY`
- qBittorrent: Cookie-based auth via `POST /api/v2/auth/login`

## Storage Architecture

All media apps share a **single mount** at `/data` in every container. This enables **hardlinks** between downloads and library folders (no file copy/move, saves disk space, keeps seeding active).

```
/data/                          (single filesystem — hardlinks work)
├── downloads/                  (qBittorrent downloads)
│   ├── movies/                 (Radarr category)
│   └── tv/                     (Sonarr category)
├── movies/                     (Radarr library — Jellyfin "Movies")
└── tv/                         (Sonarr library — Jellyfin "TV Shows")
```

**Key paths:**
- Radarr root folder: `/data/movies`
- Sonarr root folder: `/data/tv`
- qBittorrent save path: `/data/downloads`
- Jellyfin libraries: `/data/movies`, `/data/tv`

## Workflows

### 1. Search a Movie
- `GET http://radarr:7878/api/v3/movie/lookup?term=QUERY`
- Display: title, year, overview, poster URL, TMDB rating
- Poster URL: `https://image.tmdb.org/t/p/w500{posterPath}` — always send as Telegram image
- Show top 3-5 results, let user pick

### 2. Add & Download a Movie (FULL WORKFLOW)

**The goal is NEVER just to "add" a movie — it's to DOWNLOAD it.**

#### a) Add to Radarr
- `POST http://radarr:7878/api/v3/movie`
- Body: `{ title, tmdbId, qualityProfileId: 1, rootFolderPath: "/data/movies", monitored: true, addOptions: { searchForMovie: true } }`
- Quality profile ID depends on user config (set during first contact)
- **Confirm with user before adding**
- Save the `id` from the response

#### b) List available releases
- `GET http://radarr:7878/api/v3/release?movieId={id}`
- Wait a few seconds after adding to let Radarr search indexers
- If empty, force search: `POST /api/v3/command` with `{"name":"MoviesSearch","movieIds":[id]}`

#### c) Auto-select the best release (NO user interaction needed)

**DO NOT ask the user to pick a release. Choose autonomously using these STRICT rules, applied IN ORDER:**

1. **Language filter (MANDATORY — use `languages` array, NOT title):**
   - Only consider releases matching user's configured language preference
   - The release title containing language hints is NOT sufficient — always verify `languages` array
   - If `languages` array is unavailable, THEN fall back to title matching

2. **Size filter (HARD LIMITS — never override):**
   - Movie: 1-5 GB ideal
   - REJECT < 700 MB (likely cam/bad quality)
   - REJECT > 8 GB (Remux/oversized)
   - Prefer 1-3 GB for standard films, 3-5 GB for long films (> 2h30)

3. **Seeders filter (MINIMUM THRESHOLD):**
   - REJECT releases with < 3 seeders
   - Prefer releases with > 10 seeders

4. **Quality preference:** Bluray-1080p > WEB-DL 1080p > Bluray-720p > HDTV-1080p > WEB-DL 720p

5. **`rejected` field handling:**
   - If `downloadAllowed: true`, you MAY grab despite `rejected: true`
   - BUT rules 1-3 above ALWAYS apply
   - Common `rejected` reasons to IGNORE: "Quality cutoff met", "size limits" (if within OUR limits)
   - `rejected` reasons to RESPECT: language mismatch, "not an upgrade"

#### d) Grab and confirm
- `POST http://radarr:7878/api/v3/release`
- Body: the full release JSON object as returned by GET /release
- Send ONE message to user: "Download started: {title} ({quality}, {size}, {seeders} seeders)"
- Include poster in the message

#### e) Post-grab validation (MANDATORY)

1. **Wait 2 minutes** after grab
2. **Check torrent status** via qBit: `GET /api/v2/torrents/info?hashes={downloadId}`
   - If `state: stalledDL` AND `num_seeds: 0` → the torrent is dead
3. **If stalled with 0 seeders after 5 minutes:**
   - Delete torrent: `DELETE /api/v2/torrents/delete` with `hashes={hash}&deleteFiles=true`
   - Remove from Radarr queue: `DELETE /api/v3/queue/{id}?removeFromClient=false&blocklist=true`
   - Re-list releases and grab the NEXT best match
   - Inform user: "Release stalled (0 seeders), trying alternative..."
4. **If still stalled after 2nd attempt:** inform user, stop auto-retrying

#### f) Track the download
- Webhook will automatically notify when download completes with Jellyfin link

**CRITICAL: If NO release matching user's language preference is found, inform the user. Never download wrong language silently.**

### 3. Search a TV Show
- `GET http://sonarr:8989/api/v3/series/lookup?term=QUERY`
- Display: title, year, overview, poster, seasons count, network

### 4. Add & Download a TV Show (FULL WORKFLOW)

**Same logic as movies — the goal is to DOWNLOAD, not just add.**

#### a) Add to Sonarr
- `POST http://sonarr:8989/api/v3/series`
- Body: `{ title, tvdbId, qualityProfileId: 1, rootFolderPath: "/data/tv", monitored: true, addOptions: { searchForMissingEpisodes: true } }`
- Save the `id`

#### b) List releases
- `GET http://sonarr:8989/api/v3/release?seriesId={id}`
- If empty, force search: `POST /api/v3/command` with `{"name":"SeriesSearch","seriesId":id}`

#### c) Auto-select (same rules as movies)
- Size per episode: 500 MB - 2 GB ideal
- Size for full season pack: up to 15 GB

#### d) Grab and confirm
- `POST http://sonarr:8989/api/v3/release`

### 5. Manage Indexers (Prowlarr)

#### Add an indexer
- List available: `GET http://prowlarr:9696/api/v1/indexer/schema`
- Add: `POST http://prowlarr:9696/api/v1/indexer` with config from schema
- Common public indexers: 1337x, RARBG, YTS, EZTV, TorrentGalaxy, Nyaa

#### Sync to Sonarr/Radarr
- Prowlarr auto-syncs indexers to configured apps
- Setup sync: `POST http://prowlarr:9696/api/v1/applications` with Sonarr/Radarr details

### 6. Active Downloads
- Radarr queue: `GET http://radarr:7878/api/v3/queue`
- Sonarr queue: `GET http://sonarr:8989/api/v3/queue`
- qBittorrent active: `GET http://qbittorrent:8080/api/v2/torrents/info?filter=downloading`
- Combine and display: name, progress %, ETA, size

### 7. Calendar (Upcoming Releases)
- Movies (next 30 days): `GET http://radarr:7878/api/v3/calendar?start=TODAY&end=+30d`
- Episodes (next 7 days): `GET http://sonarr:8989/api/v3/calendar?start=TODAY&end=+7d`

### 8. Jellyfin Library Search
- `GET http://jellyfin:8096/Items?searchTerm=QUERY&IncludeItemTypes=Movie,Series&Recursive=true`

### 9. Jellyfin Active Sessions
- `GET http://jellyfin:8096/Sessions`

### 10. Send Poster/Cover
- Build TMDB URL: `https://image.tmdb.org/t/p/w500{posterPath}`
- Send as image in Telegram message with caption

### 11. Webhook Notification Processing

When you receive a message starting with `[WEBHOOK:radarr]` or `[WEBHOOK:sonarr]`:

#### Event: Download / onDownload
1. Extract: title, year, quality, audio format
2. Build Jellyfin link if not in summary: `GET http://jellyfin:8096/Items?searchTerm={title}&IncludeItemTypes=Movie,Series&Recursive=true`
3. Send notification with poster + Jellyfin "Watch now" link

#### Event: Grab / onGrab
- Brief: "{title} — release found ({quality}, {size}). Download started."

#### Event: MovieAdded / SeriesAdd
- Send poster + "{title} added. Searching for releases..."

#### Event: ManualInteractionRequired
- URGENT alert with details and suggested actions

#### Event: HealthIssue
- Diagnostic: issue type, message, suggested fix

### 12. Download Health Monitoring

#### Stuck in Queue
- `GET /api/v3/queue` — items with `status: "warning"`
- Report stuck items and suggest fixes

#### Stalled Torrents
- `GET http://qbittorrent:8080/api/v2/torrents/info?filter=stalled`
- If stalled > 5 min with 0 seeders → auto-cancel + try next release

#### Disk Space
- Check via Radarr: `GET /api/v3/rootfolder` — `freeSpace`
- Alert if < 10 GB free

## Default Behavior
- Always include poster/cover image when available
- Confirm with user before ADDING content
- **GOLDEN RULE: "Add" = add + search releases + auto-select best one + grab + confirm.**
- **Release selection is AUTONOMOUS** — never ask user to pick
- Only ask user if: zero matching releases found, OR all releases have < 3 seeders
- After grabbing, send ONE short confirmation
