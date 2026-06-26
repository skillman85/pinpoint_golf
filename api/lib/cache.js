const memoryCache = new Map();

function supabaseConfig() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return {
    url: url.replace(/\/$/, ""),
    key
  };
}

export function normalizeCacheKey(parts) {
  return parts
    .filter((part) => part !== undefined && part !== null && `${part}`.trim() !== "")
    .map((part) => `${part}`.trim().toLowerCase().replace(/\s+/g, " "))
    .join(":");
}

export async function getCached(cacheKey) {
  const now = Date.now();
  const memoryHit = memoryCache.get(cacheKey);
  if (memoryHit && memoryHit.expiresAt > now) {
    return memoryHit.payload;
  }

  const config = supabaseConfig();
  if (!config) return null;

  const response = await fetch(
    `${config.url}/rest/v1/course_api_cache?cache_key=eq.${encodeURIComponent(cacheKey)}&select=payload,expires_at`,
    {
      headers: {
        apikey: config.key,
        Authorization: `Bearer ${config.key}`
      }
    }
  );

  if (!response.ok) return null;
  const rows = await response.json();
  const row = rows[0];
  if (!row || new Date(row.expires_at).getTime() <= now) {
    return null;
  }

  memoryCache.set(cacheKey, {
    payload: row.payload,
    expiresAt: new Date(row.expires_at).getTime()
  });
  return row.payload;
}

export async function setCached(cacheKey, payload, ttlSeconds) {
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
  memoryCache.set(cacheKey, {
    payload,
    expiresAt: new Date(expiresAt).getTime()
  });

  const config = supabaseConfig();
  if (!config) return;

  await fetch(`${config.url}/rest/v1/course_api_cache`, {
    method: "POST",
    headers: {
      apikey: config.key,
      Authorization: `Bearer ${config.key}`,
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates"
    },
    body: JSON.stringify({
      cache_key: cacheKey,
      payload,
      expires_at: expiresAt,
      updated_at: new Date().toISOString()
    })
  });
}

export async function cached(cacheKey, ttlSeconds, loader) {
  const hit = await getCached(cacheKey);
  if (hit) {
    return { payload: hit, cache: "hit" };
  }

  const payload = await loader();
  await setCached(cacheKey, payload, ttlSeconds);
  return { payload, cache: "miss" };
}
