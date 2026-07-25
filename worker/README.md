# Millbrae ⇄ SFO relay worker

Cloudflare Worker that proxies the 511.org and BART APIs for
[/292/](https://www.lyric.today/292/), keeping the 511 token out of the
browser and caching responses so the free 60 req/hour 511 quota is shared
across all devices/page loads.

## Deploy (one time, ~2 minutes)

```sh
cd worker
npx wrangler login          # opens browser to your Cloudflare account
npx wrangler deploy         # prints the worker URL
npx wrangler secret put TOKEN_511   # paste your 511.org token when prompted
```

Then open https://www.lyric.today/292/ → ⚙︎ settings → paste the printed
worker URL (e.g. `https://millbrae-sfo-relay.<your-subdomain>.workers.dev`)
into **Relay URL** → Save. The 511 token field can be left empty after that.

⚠️ The token is a Worker secret. Never put it in this repo — the repo is public.

## Endpoints

- `GET /511/transit/<StopMonitoring|stoptimetable|stops|lines|patterns|timetable>?...`
- `GET /bart/api/<etd|sched|stn|route>.aspx?...`

Client-supplied `api_key`/`key` params are stripped; the worker injects its
own. Real-time responses are cached ~10–20 s, directory/schedule responses
~6 h (in-isolate memory on workers.dev; edge Cache API on a custom domain).
Browser origins other than lyric.today / mingjun97.github.io / localhost are
rejected.
