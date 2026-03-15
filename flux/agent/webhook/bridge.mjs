import http from 'node:http';

const GW = 'http://localhost:18789/v1/chat/completions';
const TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN;
const MODEL = process.env.WEBHOOK_MODEL || 'anthropic/claude-sonnet-4-6';
const JELLYFIN_KEY = process.env.JELLYFIN_API_KEY;
const JELLYFIN_URL = 'http://jellyfin:8096';

// Deduplication: track recent events (eventType+title → timestamp)
const recentEvents = new Map();
const DEDUP_WINDOW_MS = 5 * 60 * 1000; // 5 minutes

function isDuplicate(key) {
  const now = Date.now();
  for (const [k, ts] of recentEvents) {
    if (now - ts > DEDUP_WINDOW_MS) recentEvents.delete(k);
  }
  if (recentEvents.has(key)) return true;
  recentEvents.set(key, now);
  if (recentEvents.size > 50) {
    const oldest = recentEvents.keys().next().value;
    recentEvents.delete(oldest);
  }
  return false;
}

async function searchJellyfinOnce(title) {
  if (!JELLYFIN_KEY) return null;
  try {
    const r = await fetch(`${JELLYFIN_URL}/Items?searchTerm=${encodeURIComponent(title)}&IncludeItemTypes=Movie,Series&Recursive=true&Limit=1`, {
      headers: { 'X-Emby-Token': JELLYFIN_KEY }
    });
    if (!r.ok) return null;
    const data = await r.json();
    if (data.Items && data.Items.length > 0) {
      return { id: data.Items[0].Id, name: data.Items[0].Name };
    }
  } catch (e) {
    console.error('Jellyfin search error:', e.message);
  }
  return null;
}

async function waitForJellyfin(title, maxAttempts = 10) {
  for (let i = 1; i <= maxAttempts; i++) {
    console.log(`Jellyfin poll ${i}/${maxAttempts} for "${title}"...`);
    const result = await searchJellyfinOnce(title);
    if (result) {
      console.log(`Jellyfin found "${title}" after ${i} attempt(s)`);
      // Return internal URL — the agent will format for the user
      return `${JELLYFIN_URL}/web/index.html#!/details?id=${result.id}`;
    }
    if (i < maxAttempts) await new Promise(r => setTimeout(r, 30000));
  }
  console.log(`Jellyfin: "${title}" not found after ${maxAttempts} attempts`);
  return null;
}

function buildTmdbPoster(_tmdbId, posterPath) {
  if (posterPath) return `https://image.tmdb.org/t/p/w500${posterPath}`;
  return null;
}

function getSystemPrompt(eventType) {
  const base = 'You are ClaWArr, a media stack assistant. Send a notification to the Telegram chat.';
  const prompts = {
    Download: `${base} A download just completed! Send a festive notification with:
1. Movie/series title and year
2. Quality and audio format
3. Poster image (TMDB URL provided below if available)
4. Jellyfin "Watch now" link (provided below if available)
Format as good news. Use a joyful tone.`,

    Grab: `${base} A release was found and download is starting. Send a brief notification:
title, quality, size, indexer. Keep it short — user will get another notification when DL finishes.`,

    MovieAdded: `${base} A new movie was added to the library. Send poster + brief confirmation.`,

    SeriesAdd: `${base} A new series was added to the library. Send poster + brief confirmation.`,

    Upgrade: `${base} A better quality version was found. Mention old and new quality.`,

    ManualInteractionRequired: `${base} URGENT: A download needs manual intervention!
Include: movie/series name, what failed, and ask user what to do.
Format as an urgent alert.`,

    HealthIssue: `${base} ALERT: A system health issue was detected.
Include the issue type and message. If a wiki link is available, include it.`,

    HealthRestored: `${base} Health issue resolved. Send a brief confirmation.`,

    ImportComplete: `${base} An episode import completed. Send notification with:
1. Series title, season and episode
2. File quality
3. Jellyfin link if available
Format as good news.`,
  };
  return prompts[eventType] || `${base} A media event occurred. Summarize it clearly.`;
}

const server = http.createServer(async (req, res) => {
  if (req.method !== 'POST') { res.writeHead(200); res.end('ok'); return; }

  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);

  let body;
  try {
    body = JSON.parse(Buffer.concat(chunks).toString());
  } catch (e) {
    console.error('Invalid JSON payload:', e.message);
    res.writeHead(400);
    res.end('bad request');
    return;
  }

  const source = req.url.includes('sonarr') ? 'sonarr' : 'radarr';
  const eventType = body.eventType || 'Unknown';

  // Build dedup key
  const title = body.movie?.title || body.series?.title || 'unknown';
  const dedupKey = `${source}:${eventType}:${title}`;
  if (isDuplicate(dedupKey)) {
    console.log(`Dedup: skipping duplicate ${dedupKey}`);
    res.writeHead(200);
    res.end('dedup');
    return;
  }

  // Events the agent already handles — skip to avoid double messages
  const AGENT_HANDLED_EVENTS = ['Grab', 'MovieAdded', 'SeriesAdd'];
  if (AGENT_HANDLED_EVENTS.includes(eventType)) {
    console.log(`Skipping agent-handled event: ${dedupKey}`);
    res.writeHead(200);
    res.end('agent-handled');
    return;
  }

  // Build summary
  let summary = `[WEBHOOK:${source}] Event: ${eventType}\n`;
  let posterUrl = null;
  let jellyfinLink = null;

  if (source === 'radarr' && body.movie) {
    summary += `Movie: ${body.movie.title} (${body.movie.year})\n`;
    if (body.movie.tmdbId) summary += `TMDB ID: ${body.movie.tmdbId}\n`;
    posterUrl = buildTmdbPoster(body.movie.tmdbId, body.movie.images?.find(i => i.coverType === 'poster')?.remoteUrl?.replace('https://image.tmdb.org/t/p/original', ''));
    if (body.movieFile) {
      const q = body.movieFile.quality?.quality?.name || 'unknown';
      const audio = body.movieFile.mediaInfo?.audioCodec || '';
      const langs = body.movieFile.mediaInfo?.audioLanguages || '';
      summary += `Quality: ${q}\n`;
      if (audio) summary += `Audio: ${audio} (${langs})\n`;
    }
    if (body.release) {
      summary += `Release: ${body.release.title || ''}\n`;
      if (body.release.size) summary += `Size: ${(body.release.size / 1073741824).toFixed(1)} GB\n`;
      if (body.release.indexer) summary += `Indexer: ${body.release.indexer}\n`;
    }
  }

  if (source === 'sonarr' && body.series) {
    summary += `Series: ${body.series.title}\n`;
    if (body.series.tmdbId) summary += `TMDB ID: ${body.series.tmdbId}\n`;
    posterUrl = buildTmdbPoster(body.series.tmdbId, body.series.images?.find(i => i.coverType === 'poster')?.remoteUrl?.replace('https://image.tmdb.org/t/p/original', ''));
    if (body.episodes) {
      summary += `Episodes: ${body.episodes.map(e => `S${String(e.seasonNumber).padStart(2,'0')}E${String(e.episodeNumber).padStart(2,'0')} - ${e.title || ''}`).join(', ')}\n`;
    }
    if (body.episodeFile) {
      const q = body.episodeFile.quality?.quality?.name || 'unknown';
      summary += `Quality: ${q}\n`;
    }
    if (body.release) {
      summary += `Release: ${body.release.title || ''}\n`;
      if (body.release.size) summary += `Size: ${(body.release.size / 1073741824).toFixed(1)} GB\n`;
    }
  }

  // Health events
  if (body.health) {
    summary += `Health type: ${body.health.type || 'unknown'}\n`;
    summary += `Message: ${body.health.message || ''}\n`;
    if (body.health.wikiUrl) summary += `Wiki: ${body.health.wikiUrl}\n`;
  }

  if (posterUrl) {
    summary += `\nPoster URL: ${posterUrl}\n`;
  }

  // For download/import events, poll Jellyfin until the item appears
  if (['Download', 'ImportComplete'].includes(eventType)) {
    jellyfinLink = await waitForJellyfin(title);
    if (jellyfinLink) {
      summary += `Jellyfin watch link: ${jellyfinLink}\n`;
    }
  }

  console.log(`Processing: ${dedupKey}`);

  // Respond immediately — fire LLM call in background
  res.writeHead(200);
  res.end('ok');

  try {
    const r = await fetch(GW, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${TOKEN}` },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          { role: 'system', content: getSystemPrompt(eventType) },
          { role: 'user', content: summary }
        ],
        max_tokens: 1000
      })
    });
    if (!r.ok) {
      console.error('Gateway error:', r.status, await r.text().catch(() => ''));
    } else {
      console.log(`Notification sent for: ${dedupKey}`);
    }
  } catch (err) {
    console.error('Bridge error:', err.message);
  }
});

server.listen(8095, '0.0.0.0', () => console.log('Webhook bridge listening on :8095'));
