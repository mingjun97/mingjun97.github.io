/**
 * Relay for the Millbrae ⇄ SFO tracker (https://www.lyric.today/292/).
 *
 * Proxies the 511.org and BART APIs so the browser never needs an API token:
 *   GET /511/transit/StopMonitoring?agency=SM&stopCode=336623&format=json
 *   GET /bart/api/etd.aspx?cmd=etd&orig=MLBR&json=y
 *
 * - Injects the 511 token from the TOKEN_511 secret (wrangler secret put TOKEN_511)
 * - Injects the BART key from BART_KEY, falling back to BART's public key
 * - Strips any api_key/key supplied by the client
 * - Only whitelisted upstream paths are reachable (not an open proxy)
 * - Caches responses (Cache API when available, else in-isolate memory) so
 *   many page loads share one upstream call and stay under 511's rate limit
 */

const ALLOWED_ORIGINS = [
  /^https:\/\/(www\.)?lyric\.today$/i,
  /^https:\/\/mingjun97\.github\.io$/i,
  /^http:\/\/localhost(:\d+)?$/i,
  /^http:\/\/127\.0\.0\.1(:\d+)?$/i,
];

const ROUTES = [
  {
    prefix: '/511/',
    base: 'https://api.511.org',
    allow: /^\/transit\/(StopMonitoring|stoptimetable|stops|lines|patterns|timetable|VehicleMonitoring)$/i,
    keyParam: 'api_key',
    keyValue: env => env.TOKEN_511,
    ttl: p => (/StopMonitoring|VehicleMonitoring/i.test(p) ? 20 : 6 * 3600),
  },
  {
    prefix: '/bart/',
    base: 'https://api.bart.gov',
    allow: /^\/api\/(etd|sched|stn|route)\.aspx$/i,
    keyParam: 'key',
    keyValue: env => env.BART_KEY || 'MW9S-E7SL-26DU-VV8V',
    ttl: p => (/etd/i.test(p) ? 10 : 6 * 3600),
  },
];

// In-isolate fallback cache (Cache API is unavailable on *.workers.dev zones)
const memCache = new Map();
const MEM_MAX = 200;

function corsHeaders(origin) {
  const ok = origin && ALLOWED_ORIGINS.some(rx => rx.test(origin));
  return {
    'access-control-allow-origin': ok ? origin : '*',
    'access-control-allow-methods': 'GET, OPTIONS',
    'access-control-allow-headers': 'content-type',
    'access-control-max-age': '86400',
    'vary': 'origin',
  };
}

function json(obj, status, cors) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json', ...cors },
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin');
    const cors = corsHeaders(origin);

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'GET') return json({ error: 'GET only' }, 405, cors);
    if (origin && !ALLOWED_ORIGINS.some(rx => rx.test(origin))) {
      return json({ error: 'origin not allowed' }, 403, cors);
    }

    const route = ROUTES.find(r => url.pathname.startsWith(r.prefix));
    if (!route) {
      const at_root = url.pathname === '/';
      return json(
        at_root ? { ok: true, hint: 'use /511/transit/... or /bart/api/...' } : { error: 'unknown route' },
        at_root ? 200 : 404, cors);
    }
    const upPath = url.pathname.slice(route.prefix.length - 1); // keeps leading '/'
    if (!route.allow.test(upPath)) return json({ error: 'path not allowed' }, 403, cors);

    const key = route.keyValue(env);
    if (!key) return json({ error: 'relay not configured: run `wrangler secret put TOKEN_511`' }, 500, cors);

    const upstream = new URL(route.base + upPath);
    const params = [...url.searchParams].filter(([k]) => !/^(api_key|key)$/i.test(k));
    params.sort(([a], [b]) => (a < b ? -1 : 1));
    for (const [k, v] of params) upstream.searchParams.append(k, v);

    const ttl = route.ttl(upPath);
    const cacheId = url.pathname + '?' + params.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');

    // 1) in-memory cache
    const mem = memCache.get(cacheId);
    if (mem && mem.expires > Date.now()) {
      return respond(mem.body, mem.status, mem.contentType, cors, 'memory');
    }
    // 2) Cache API (works when the worker runs on a custom domain)
    const edgeCache = globalThis.caches && caches.default;
    const cacheKey = edgeCache && new Request(url.origin + '/__c' + cacheId);
    if (edgeCache) {
      const hit = await edgeCache.match(cacheKey);
      if (hit) {
        const body = await hit.text();
        remember(cacheId, body, hit.status, hit.headers.get('content-type'), ttl);
        return respond(body, hit.status, hit.headers.get('content-type'), cors, 'edge');
      }
    }
    // 3) upstream
    upstream.searchParams.append(route.keyParam, key);
    let res;
    try {
      res = await fetch(upstream.toString(), { headers: { accept: 'application/json' } });
    } catch (e) {
      return json({ error: 'upstream unreachable: ' + (e && e.message) }, 502, cors);
    }
    const body = await res.text();
    const contentType = res.headers.get('content-type') || 'application/json';
    if (res.ok) {
      remember(cacheId, body, res.status, contentType, ttl);
      if (edgeCache) {
        ctx.waitUntil(edgeCache.put(cacheKey, new Response(body, {
          status: res.status,
          headers: { 'content-type': contentType, 'cache-control': `public, max-age=${ttl}` },
        })));
      }
    }
    return respond(body, res.status, contentType, cors, 'upstream');
  },
};

function remember(id, body, status, contentType, ttl) {
  if (memCache.size >= MEM_MAX) memCache.delete(memCache.keys().next().value);
  memCache.set(id, { body, status, contentType, expires: Date.now() + ttl * 1000 });
}

function respond(body, status, contentType, cors, source) {
  return new Response(body, {
    status,
    headers: {
      'content-type': contentType || 'application/json',
      'cache-control': 'no-store',
      'x-relay-cache': source,
      ...cors,
    },
  });
}
